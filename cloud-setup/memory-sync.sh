#!/bin/bash
# ============================================================
# Memory 后台同步守护脚本
# 在云端运行，每 N 秒通过本地 bridge 隧道双向同步 memory 文件
#
# 用法: memory-sync.sh <local-memory-path> <cloud-memory-path> [bridge-port] [interval]
# ============================================================

LOCAL_MEMORY_PATH="$1"
CLOUD_MEMORY_PATH="$2"
BRIDGE_PORT="${3:-3100}"
SYNC_INTERVAL="${4:-30}"

BRIDGE_URL="http://localhost:$BRIDGE_PORT"

if [ -z "$LOCAL_MEMORY_PATH" ] || [ -z "$CLOUD_MEMORY_PATH" ]; then
    echo "memory-sync: ERROR - missing paths, exiting"
    exit 1
fi

mkdir -p "$CLOUD_MEMORY_PATH"

echo "memory-sync: started (PID $$)"
echo "  local:    $LOCAL_MEMORY_PATH"
echo "  cloud:    $CLOUD_MEMORY_PATH"
echo "  interval: ${SYNC_INTERVAL}s"

sync_once() {
    # ---- Pull: 本地 → 云端 ----
    local_response=$(curl -s --max-time 10 "${BRIDGE_URL}/sync/memory?path=${LOCAL_MEMORY_PATH}" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$local_response" ]; then
        return 1
    fi

    # 检查是否返回了有效 JSON
    if ! echo "$local_response" | jq empty 2>/dev/null; then
        return 1
    fi

    # 遍历本地文件，比较时间戳后写入云端
    echo "$local_response" | jq -c '.files[]?' 2>/dev/null | while IFS= read -r file_json; do
        name=$(echo "$file_json" | jq -r '.name')
        content=$(echo "$file_json" | jq -r '.content')
        local_mtime=$(echo "$file_json" | jq -r '.mtime' | cut -d. -f1)

        cloud_file="$CLOUD_MEMORY_PATH/$name"

        if [ -f "$cloud_file" ]; then
            cloud_mtime_s=$(stat -c %Y "$cloud_file" 2>/dev/null || echo "0")
            cloud_mtime_ms=$((cloud_mtime_s * 1000))

            # 本地更新 → 覆盖云端
            if [ "$local_mtime" -gt "$cloud_mtime_ms" ] 2>/dev/null; then
                printf '%s' "$content" > "$cloud_file"
            fi
        else
            # 本地新文件 → 写入云端
            printf '%s' "$content" > "$cloud_file"
        fi
    done

    # ---- Push: 云端 → 本地 ----
    push_files="[]"
    for cloud_file in "$CLOUD_MEMORY_PATH"/*; do
        [ -f "$cloud_file" ] || continue
        name=$(basename "$cloud_file")
        content=$(cat "$cloud_file")
        mtime_s=$(stat -c %Y "$cloud_file" 2>/dev/null || echo "0")
        mtime_ms=$((mtime_s * 1000))

        # 检查本地是否有更新的版本
        local_mtime=$(echo "$local_response" | jq -r --arg n "$name" '.files[]? | select(.name == $n) | .mtime' 2>/dev/null | cut -d. -f1)

        if [ -z "$local_mtime" ] || [ "$mtime_ms" -gt "$local_mtime" ] 2>/dev/null; then
            push_files=$(echo "$push_files" | jq \
                --arg name "$name" \
                --arg content "$content" \
                --argjson mtime "$mtime_ms" \
                '. + [{"name": $name, "content": $content, "mtime": $mtime}]')
        fi
    done

    # 有文件需要推送才发请求
    file_count=$(echo "$push_files" | jq 'length')
    if [ "$file_count" -gt 0 ]; then
        curl -s --max-time 10 -X POST \
            -H "Content-Type: application/json" \
            -d "{\"files\": $push_files}" \
            "${BRIDGE_URL}/sync/memory?path=${LOCAL_MEMORY_PATH}" > /dev/null 2>&1
    fi
}

# 主循环
while true; do
    sync_once 2>/dev/null
    sleep "$SYNC_INTERVAL"
done

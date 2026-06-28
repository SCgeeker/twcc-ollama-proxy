#!/bin/bash
# 批次嵌入向量推論腳本（供 twcc_proxy.py /api/embeddings 使用）
# 用法：bash /work/tcpsr001/scripts/embedding.sh <batch_id> [model]
#   model 可選值：qwen3-embedding:0.6b（預設）｜qwen3-embedding:4b｜qwen3-embedding:8b
#   首次執行自動 ollama pull；OLLAMA_MODELS 在 HFS，後續執行直接使用快取
# 輸入：${PROXY_DIR}/input/${BATCH_ID}.txt  — JSON 字串陣列 ["text1", "text2", ...]
# 輸出：${PROXY_DIR}/output/${BATCH_ID}.txt — JSON 浮點陣列之陣列 [[0.1,...],[0.2,...],...]

set -e

BATCH_ID="${1:-default}"
MODEL="${2:-qwen3-embedding:0.6b}"
source /home/tcpsr001/env.sh

WORK_DIR="/work/tcpsr001"
PROXY_DIR="${WORK_DIR}/proxy"
INPUT_FILE="${PROXY_DIR}/input/${BATCH_ID}.txt"
OUTPUT_FILE="${PROXY_DIR}/output/${BATCH_ID}.txt"
LOG_FILE="${PROXY_DIR}/logs/${BATCH_ID}.log"

mkdir -p "${PROXY_DIR}/input" "${PROXY_DIR}/output" "${PROXY_DIR}/logs"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== 批次嵌入開始: $(date), batch=${BATCH_ID}, model=${MODEL} ==="

if [ ! -f "${INPUT_FILE}" ]; then
    echo "錯誤：找不到輸入檔案 ${INPUT_FILE}"
    exit 1
fi

TEXT_COUNT=$(python3 -c "import json; print(len(json.load(open('${INPUT_FILE}'))))")
echo "文字數量: ${TEXT_COUNT}"

# ── 安裝 Ollama（若未安裝）────────────────────────────────
if ! command -v ollama &> /dev/null; then
    echo "--- 安裝 Ollama ---"
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq pciutils lshw zstd 2>/dev/null || true
    curl -fsSL https://ollama.com/install.sh | sh
fi

# ── 啟動 Ollama server ─────────────────────────────────────
echo "--- 啟動 Ollama server ---"
pkill ollama 2>/dev/null || true
sleep 2
OLLAMA_HOST=0.0.0.0:11434 OLLAMA_MODELS=/home/tcpsr001/ollama_models \
    ollama serve > "${PROXY_DIR}/logs/${BATCH_ID}_server.log" 2>&1 &
OLLAMA_PID=$!

for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        echo "Ollama server 就緒（${i}秒）"
        break
    fi
    sleep 1
done

# ── Pull 嵌入模型（首次下載至 HFS OLLAMA_MODELS，後續使用快取）──
# 模型儲存於 OLLAMA_MODELS=/home/tcpsr001/ollama_models（HFS，跨容器持久）
MODEL_TAG="${MODEL%%:*}"   # 取冒號前的基礎名稱用於 grep
if ! ollama list 2>/dev/null | grep -q "${MODEL_TAG}"; then
    echo "--- 首次執行：ollama pull ${MODEL}（儲存至 HFS，後續免重下）---"
    ollama pull "${MODEL}"
else
    echo "--- ${MODEL} 已在 OLLAMA_MODELS 快取 ---"
fi

# ── 批次嵌入推論 ────────────────────────────────────────────
echo "--- 開始批次嵌入（模型: ${MODEL}, 數量: ${TEXT_COUNT}）---"
TEMP_OUTPUT="${OUTPUT_FILE}.tmp"
python3 - "${INPUT_FILE}" "${MODEL}" << 'PYEOF' > "${TEMP_OUTPUT}"
import json, sys, urllib.request

input_file, model = sys.argv[1], sys.argv[2]
texts = json.load(open(input_file))
results = []
for i, text in enumerate(texts):
    payload = json.dumps({"model": model, "prompt": text}).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/embeddings",
        data=payload,
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        d = json.load(resp)
        emb = d.get("embedding", [])
        results.append(emb)
    print(f"  [{i+1}/{len(texts)}] 維度={len(emb)}", file=sys.stderr)

print(json.dumps(results))
PYEOF

mv "${TEMP_OUTPUT}" "${OUTPUT_FILE}"
echo "--- 批次嵌入完成，結果: ${OUTPUT_FILE} ---"

echo "=== 任務結束: $(date) ==="
kill "${OLLAMA_PID}" 2>/dev/null || true

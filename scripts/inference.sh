#!/bin/bash
# 單一 prompt 推論腳本（供 twcc_proxy.py 使用）
# 用法：bash /work/tcpsr001/scripts/inference.sh <job_id> [model]
#   model 可選值：crystalmind（預設）、gemmapro、gemmapro-r

set -e

JOB_ID="${1:-default}"
MODEL="${2:-crystalmind}"
source /home/tcpsr001/env.sh

WORK_DIR="/work/tcpsr001"
PROXY_DIR="${WORK_DIR}/proxy"
INPUT_FILE="${PROXY_DIR}/input/${JOB_ID}.txt"
OUTPUT_FILE="${PROXY_DIR}/output/${JOB_ID}.txt"
LOG_FILE="${PROXY_DIR}/logs/${JOB_ID}.log"

mkdir -p "${PROXY_DIR}/input" "${PROXY_DIR}/output" "${PROXY_DIR}/logs"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== 推論開始: $(date), job=${JOB_ID}, model=${MODEL} ==="

# 確認輸入檔案存在
if [ ! -f "${INPUT_FILE}" ]; then
    echo "錯誤：找不到輸入檔案 ${INPUT_FILE}"
    exit 1
fi

PROMPT=$(cat "${INPUT_FILE}")
echo "prompt 長度: ${#PROMPT} 字元"

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
    ollama serve > "${PROXY_DIR}/logs/${JOB_ID}_server.log" 2>&1 &
OLLAMA_PID=$!

# 等待 server 就緒（最多 30 秒）
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        echo "Ollama server 就緒（${i}秒）"
        break
    fi
    sleep 1
done

# ── 依 model 參數建立對應模型 ──────────────────────────────
case "${MODEL}" in
    crystalmind)
        if ! ollama list 2>/dev/null | grep -q crystalmind; then
            echo "--- 建立 crystalmind 模型 ---"
            sed -i "s|FROM .*|FROM ${WORK_DIR}/models/CrystalMind.gguf|g" \
                "${WORK_DIR}/models/modelfile.txt"
            ollama create crystalmind -f "${WORK_DIR}/models/modelfile.txt"
        else
            echo "--- crystalmind 已存在 ---"
        fi
        ;;
    gemmapro)
        if ! ollama list 2>/dev/null | grep -q "^gemmapro "; then
            echo "--- 建立 gemmapro 模型 ---"
            sed -i "s|FROM .*|FROM ${WORK_DIR}/models/GemmaPro_q4.gguf|g" \
                "${WORK_DIR}/models/modelfilegemmapro.txt"
            ollama create gemmapro -f "${WORK_DIR}/models/modelfilegemmapro.txt"
        else
            echo "--- gemmapro 已存在 ---"
        fi
        ;;
    gemmapro-r)
        if ! ollama list 2>/dev/null | grep -q "^gemmapro-r "; then
            echo "--- 建立 gemmapro-r 模型 ---"
            sed -i "s|FROM .*|FROM ${WORK_DIR}/models/GemmaPro_q4.gguf|g" \
                "${WORK_DIR}/models/modelfilegemmapro-r.txt"
            ollama create gemmapro-r -f "${WORK_DIR}/models/modelfilegemmapro-r.txt"
        else
            echo "--- gemmapro-r 已存在 ---"
        fi
        ;;
    *)
        echo "警告：未知模型 '${MODEL}'，改用 crystalmind"
        MODEL="crystalmind"
        if ! ollama list 2>/dev/null | grep -q crystalmind; then
            sed -i "s|FROM .*|FROM ${WORK_DIR}/models/CrystalMind.gguf|g" \
                "${WORK_DIR}/models/modelfile.txt"
            ollama create crystalmind -f "${WORK_DIR}/models/modelfile.txt"
        fi
        ;;
esac

# ── 執行推論 ───────────────────────────────────────────────
echo "--- 開始推論（模型: ${MODEL}）---"
TERM=dumb ollama run "${MODEL}" "${PROMPT}" > "${OUTPUT_FILE}" 2>&1
echo "--- 推論完成，結果: ${OUTPUT_FILE} ---"

echo "=== 任務結束: $(date) ==="
kill "${OLLAMA_PID}" 2>/dev/null || true

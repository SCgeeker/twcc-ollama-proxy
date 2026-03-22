#!/bin/bash
# GemmaPro 模型下載腳本（一次性執行）
set -e

source /home/tcpsr001/env.sh
WORK_DIR="/work/tcpsr001"
LOG_FILE="${WORK_DIR}/logs/download_gemmapro_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "${WORK_DIR}/logs" "${WORK_DIR}/models"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== GemmaPro 下載開始: $(date) ==="

# ── 下載 GGUF ──────────────────────────────────────────
if [ ! -f "${WORK_DIR}/models/GemmaPro_q4.gguf" ]; then
    echo "--- 下載 GemmaPro_q4.gguf ---"
    curl -L -H "Authorization: Bearer ${HF_TOKEN}" \
        https://huggingface.co/SciMaker/Web_AI_assistant/resolve/main/GemmaPro_q4.gguf \
        -o "${WORK_DIR}/models/GemmaPro_q4.gguf"
else
    echo "--- GemmaPro_q4.gguf 已存在，跳過 ---"
fi

# ── 下載 modelfile ──────────────────────────────────────
if [ ! -f "${WORK_DIR}/models/modelfilegemmapro.txt" ]; then
    echo "--- 下載 modelfilegemmapro.txt ---"
    curl -L -H "Authorization: Bearer ${HF_TOKEN}" \
        https://huggingface.co/SciMaker/Journal_Club/resolve/main/modelfilegemmapro.txt \
        -o "${WORK_DIR}/models/modelfilegemmapro.txt"
fi

if [ ! -f "${WORK_DIR}/models/modelfilegemmapro-r.txt" ]; then
    echo "--- 下載 modelfilegemmapro-r.txt ---"
    curl -L -H "Authorization: Bearer ${HF_TOKEN}" \
        https://huggingface.co/SciMaker/Journal_Club/resolve/main/modelfilegemmapro-r.txt \
        -o "${WORK_DIR}/models/modelfilegemmapro-r.txt"
fi

# ── 確認結果 ────────────────────────────────────────────
echo "--- 模型目錄內容 ---"
ls -lh "${WORK_DIR}/models/"

echo "=== 下載完成: $(date) ==="

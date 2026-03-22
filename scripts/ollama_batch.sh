#!/bin/bash
# TWCC 任務型容器 — Ollama 批次推論腳本 v2
set -e

# ── 環境設定 ──────────────────────────────────────────
source /home/tcpsr001/env.sh
WORK_DIR="/work/tcpsr001"

# ── Log 設定 ──────────────────────────────────────────
mkdir -p "${WORK_DIR}/logs"
LOG_FILE="${WORK_DIR}/logs/batch_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== 任務開始: $(date) ==="

# ── 安裝 GPU 偵測工具 + Ollama ──────────────────────────
apt-get update -qq 2>/dev/null || true
apt-get install -y -qq pciutils lshw zstd 2>/dev/null || true

if ! command -v ollama &> /dev/null; then
    echo "--- 安裝 Ollama ---"
    curl -fsSL https://ollama.com/install.sh | sh
fi

echo "--- GPU 狀態 ---"
nvidia-smi 2>/dev/null || echo "nvidia-smi 不可用"
python3 -c "import torch; print('CUDA 可用:', torch.cuda.is_available())" 2>/dev/null || true

# ── 啟動 Ollama server ─────────────────────────────────
echo "--- 啟動 Ollama server ---"
pkill ollama 2>/dev/null || true
sleep 2
OLLAMA_HOST=0.0.0.0:11434 OLLAMA_MODELS=/home/tcpsr001/ollama_models \
    ollama serve > "${WORK_DIR}/logs/ollama_server.log" 2>&1 &
OLLAMA_PID=$!

# 等待 server 就緒（最多 30 秒）
echo "--- 等待 Ollama server 就緒 ---"
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        echo "Ollama server 就緒（等待 ${i} 秒）"
        break
    fi
    sleep 1
done

# ── 建立模型（若尚未存在）────────────────────────────────
if ! ollama list 2>/dev/null | grep -q crystalmind; then
    echo "--- 建立 crystalmind 模型 ---"
    sed -i "s|FROM .*|FROM ${WORK_DIR}/models/CrystalMind.gguf|g" "${WORK_DIR}/models/modelfile.txt"
    ollama create crystalmind -f "${WORK_DIR}/models/modelfile.txt"
    echo "--- crystalmind 建立完成 ---"
else
    echo "--- crystalmind 模型已存在，跳過建立 ---"
fi

# ── 批次推論 ──────────────────────────────────────────────
mkdir -p "${WORK_DIR}/output"
if [ -f "${WORK_DIR}/input/prompts.txt" ]; then
    echo "--- 開始批次推論 ---"
    RESULT_FILE="${WORK_DIR}/output/results_$(date +%Y%m%d_%H%M%S).txt"
    while IFS= read -r prompt; do
        [ -z "$prompt" ] && continue
        echo ">> ${prompt}"
        TERM=dumb ollama run crystalmind "${prompt}" | tee -a "${RESULT_FILE}"
        echo "---" >> "${RESULT_FILE}"
    done < "${WORK_DIR}/input/prompts.txt"
    echo "--- 推論完成: ${RESULT_FILE} ---"
else
    echo "警告：找不到 prompts.txt，跳過推論"
fi

echo "=== 任務完成: $(date) ==="
kill "${OLLAMA_PID}" 2>/dev/null || true

#!/bin/bash
# 持久化 Ollama Embedding Server + HFS 檔案佇列（Mega-batch 版）
# 每次輪詢：抓取所有待處理請求 → 一次 /api/embed 呼叫 → 批次寫回回應
# 無需 SSH tunnel；OLLAMA_MODELS 在 HFS 跨容器持久化

set -e
source /home/tcpsr001/env.sh

WORK_DIR="/work/tcpsr001"
PROXY_DIR="${WORK_DIR}/proxy"
EMBED_MODEL="${1:-qwen3-embedding:0.6b}"
LOG_FILE="${PROXY_DIR}/logs/embed_server_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "${PROXY_DIR}/logs"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== Embedding Server 啟動: $(date), model=${EMBED_MODEL} ==="

# ── 安裝 Ollama（若未安裝）────────────────────────────────
if ! command -v ollama &> /dev/null; then
    echo "--- 安裝 Ollama ---"
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq pciutils lshw zstd 2>/dev/null || true
    curl -fsSL https://ollama.com/install.sh | sh
fi

# ── 啟動 Ollama server ─────────────────────────────────────
echo "--- 啟動 Ollama server（監聽 0.0.0.0:11434）---"
pkill ollama 2>/dev/null || true
sleep 2
OLLAMA_HOST=0.0.0.0:11434 \
OLLAMA_MODELS=/home/tcpsr001/ollama_models \
    ollama serve &
OLLAMA_PID=$!

# 等待 server 就緒
for i in $(seq 1 60); do
    if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        echo "Ollama server 就緒（${i}秒）"
        break
    fi
    sleep 2
done

# ── Pull 模型（首次；已快取則跳過）──────────────────────────
MODEL_BASE="${EMBED_MODEL%%:*}"
if ! ollama list 2>/dev/null | grep -q "${MODEL_BASE}"; then
    echo "--- 首次 pull ${EMBED_MODEL}（存至 HFS OLLAMA_MODELS，後續免重下）---"
    ollama pull "${EMBED_MODEL}"
else
    echo "--- ${EMBED_MODEL} 已在快取 ---"
fi

echo "=== Embedding server 就緒，啟動 HFS mega-batch 輪詢 ==="

# ── 初始化目錄 ─────────────────────────────────────────────
REQ_DIR="${PROXY_DIR}/embed_requests"
RESP_DIR="${PROXY_DIR}/embed_responses"
mkdir -p "${REQ_DIR}" "${RESP_DIR}"

# ── 寫入 Mega-batch Python worker ──────────────────────────
EMBED_WORKER="${PROXY_DIR}/embed_mega_worker.py"
cat > "${EMBED_WORKER}" << 'PYEOF'
"""
Mega-batch embed worker：
  讀取 REQ_DIR 所有待處理請求 → 一次 POST /api/embed → 批次寫回 RESP_DIR
  大幅降低 Ollama HTTP 呼叫次數，GPU 一次批次處理所有向量。
"""
import json, sys, os, glob, urllib.request

req_dir, resp_dir, model = sys.argv[1], sys.argv[2], sys.argv[3]

# ── 收集所有待處理請求 ──────────────────────────────────────
pending = []
for req_file in sorted(glob.glob(os.path.join(req_dir, "*.json"))):
    job_id = os.path.splitext(os.path.basename(req_file))[0]
    resp_file = os.path.join(resp_dir, f"{job_id}.json")
    if os.path.exists(resp_file):
        continue  # 已完成
    try:
        req = json.load(open(req_file))
        pending.append((job_id, req_file, resp_file, req.get("texts", [])))
    except Exception as e:
        print(f"  [skip] {job_id}: {e}", file=sys.stderr)

if not pending:
    sys.exit(0)

total_texts = sum(len(t) for _, _, _, t in pending)
print(f"  Mega-batch: {len(pending)} jobs, {total_texts} texts", file=sys.stderr)

# ── 合併所有文字，一次呼叫 /api/embed ──────────────────────
all_texts = []
for _, _, _, texts in pending:
    all_texts.extend(texts)

payload = json.dumps({"model": model, "input": all_texts}).encode()
resp = urllib.request.urlopen(
    urllib.request.Request(
        "http://127.0.0.1:11434/api/embed",
        data=payload,
        headers={"Content-Type": "application/json"}
    ), timeout=600)
result = json.load(resp)
all_embeddings = result.get("embeddings", [])
print(f"  Got {len(all_embeddings)} embeddings, dim={len(all_embeddings[0]) if all_embeddings else 0}",
      file=sys.stderr)

# ── 拆回各 job 並寫入回應檔 ─────────────────────────────────
offset = 0
for job_id, req_file, resp_file, texts in pending:
    n = len(texts)
    job_embs = all_embeddings[offset:offset + n]
    offset += n
    tmp = resp_file + ".tmp"
    json.dump({"embeddings": job_embs}, open(tmp, "w"))
    os.rename(tmp, resp_file)
    os.remove(req_file)
    print(f"  Done: {job_id} ({n} texts)", file=sys.stderr)
PYEOF

echo "=== 開始輪詢 HFS embed 請求佇列（mega-batch，間隔 1s）==="

# ── Mega-batch 輪詢主迴圈 ─────────────────────────────────
while kill -0 ${OLLAMA_PID} 2>/dev/null; do
    if ls "${REQ_DIR}"/*.json 2>/dev/null | head -1 | grep -q .; then
        python3 "${EMBED_WORKER}" "${REQ_DIR}" "${RESP_DIR}" "${EMBED_MODEL}" \
            2>>"${PROXY_DIR}/logs/embed_worker.log" || true
    fi
    sleep 1
done

wait ${OLLAMA_PID}

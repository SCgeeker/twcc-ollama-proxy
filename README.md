# TWCC Ollama Proxy

將本地 Ollama API 請求透過 TWCC 開發型容器（CCS）執行 LLM 推論。
支援 [CrystalMind](https://huggingface.co/SciMaker/CrystalMind) 與 [GemmaPro](https://huggingface.co/SciMaker/GemmaPro) 模型。

```
本地應用程式  →  twcc_proxy.py (localhost:11434)  →  TWCC CCS 容器  →  Ollama + GGUF 模型
```

## 系統需求

- Windows 10/11（PowerShell）
- Python 3.10+（建議透過 `uv` 管理虛擬環境）
- TWCC 帳號（含 CCS 使用權限）
- SSH 金鑰已上傳至 TWCC

## 安裝步驟

### 1. 建立本地虛擬環境

```powershell
cd E:\APP\twcc_scripts   # 或你放置腳本的目錄
uv venv
uv pip install twccli paramiko flask
```

### 2. 設定環境變數

複製範例並填入實際值：

```powershell
# 編輯 twcc_env.ps1，將 your_username 替換為你的 TWCC 帳號
notepad twcc_env.ps1
```

### 3. 準備 HFS（僅需執行一次）

#### 3a. 設定 HuggingFace Token

```bash
cp env.sh.example env.sh
# 編輯 env.sh，填入 HF_TOKEN（從 https://huggingface.co/settings/tokens 取得）
```

#### 3b. 上傳初始化腳本至 HFS

```powershell
# 複製並編輯 SFTP 腳本（替換 <username>）
cp upload.sftp.example upload.sftp
# 執行上傳
sftp -i ~/.ssh/id_ed25519 your_username@xdata1.twcc.ai -b upload.sftp
```

#### 3c. 準備 GGUF 模型檔至 HFS

Proxy 需要 GGUF 格式的模型檔放置於 HFS 的 `models/` 目錄。
你可以從以下任一來源取得，再透過 SFTP 上傳：

**推薦模型來源：**

| 模型 | HuggingFace 頁面 | 大小 | HFS 路徑 |
|------|-----------------|------|---------|
| CrystalMind | [SciMaker/CrystalMind](https://huggingface.co/SciMaker/CrystalMind) | 5.6GB | `/work/<username>/models/CrystalMind.gguf` |
| GemmaPro | [SciMaker/GemmaPro](https://huggingface.co/SciMaker/GemmaPro) | 2.4GB | `/work/<username>/models/GemmaPro_q4.gguf` |

**上傳模型至 HFS：**

```bash
# 本地下載後，用 SFTP 上傳
sftp -i ~/.ssh/id_ed25519 your_username@xdata1.twcc.ai
put CrystalMind.gguf /work/your_username/models/CrystalMind.gguf
put GemmaPro_q4.gguf /work/your_username/models/GemmaPro_q4.gguf
```

**亦可使用 HuggingFace Hub CLI 在 TWCC 容器內直接下載：**

```bash
# 在 TWCC CCS 容器內執行（需先設定 env.sh 中的 HF_TOKEN）
pip install huggingface_hub
huggingface-cli download SciMaker/CrystalMind --local-dir /work/your_username/models/
```

> **注意**：模型檔儲存在 HFS，跨容器共用，只需準備一次。

## HFS 目錄結構

```
/home/<username>/
└── env.sh              # Ollama 環境變數（含 HF_TOKEN）

/work/<username>/
├── models/
│   ├── CrystalMind.gguf        # 5.6GB
│   ├── GemmaPro_q4.gguf        # 2.4GB
│   ├── modelfile.txt            # crystalmind Ollama modelfile
│   ├── modelfilegemmapro.txt   # gemmapro Ollama modelfile
│   └── modelfilegemmapro-r.txt # gemmapro-r Ollama modelfile
├── scripts/
│   └── inference.sh    # 推論主腳本
└── proxy/
    ├── input/           # 推論請求（自動清理）
    ├── output/          # 推論結果（自動清理）
    └── logs/            # 容器日誌
```

## 使用方式

### 啟動 Proxy

```powershell
cd E:\APP\twcc_scripts
. .\twcc_env.ps1
.venv\Scripts\python.exe twcc_proxy.py
```

啟動時會自動檢測 twccli、SSH 金鑰、帳號設定，若有問題會顯示修正提示。

### 呼叫 API（Ollama 相容格式）

```python
import requests

response = requests.post("http://localhost:11434/api/generate", json={
    "model": "crystalmind",   # 或 gemmapro / gemmapro-r
    "prompt": "你好，請介紹自己。"
})
print(response.json()["response"])
```

### 搭配 claude_lit_workflow

```powershell
cd D:\core\Research\claude_lit_workflow
uv run make_slides.py --pdf "paper.pdf" --llm-provider ollama --model crystalmind --language chinese
```

## 支援模型

| 模型 | 大小 | 特性 |
|------|------|------|
| `crystalmind` | 5.6GB | 通用，格式穩定，推薦預設 |
| `gemmapro` | 2.4GB | 快速，適合草稿（`--detail standard` 建議） |
| `gemmapro-r` | 2.4GB | 推理強化版，適合複雜概念抽取 |

## 費用說明

每次 API 請求會建立一個 TWCC CCS 容器（1 GPU），推論完成後自動刪除。
計費以容器存在時間計算（通常 1-2 分鐘/次）。

## 疑難排解

| 問題 | 可能原因 | 解決方式 |
|------|---------|---------|
| `twccli 找不到` | 未安裝或未在 venv | `uv pip install twccli` |
| `SSH 金鑰找不到` | 金鑰路徑不符 | 設定 `TWCC_SSH_KEY` 環境變數 |
| `TWCC 帳號未設定` | `twcc_env.ps1` 未修改 | 將 `your_username` 改為實際帳號 |
| `推論逾時（600s）` | 容器啟動慢或模型首次建立 | 首次執行較慢屬正常，等待即可 |
| `無法解析投影片格式` | LLM 未遵循輸出格式 | `parse_slides()` 已支援多種 fallback |

## 授權

MIT License

# TWCC Proxy 環境變數設定（Windows PowerShell）
# 使用方式：. .\twcc_env.ps1

# ── 必填：TWCC 帳號 ──────────────────────────────────────
$env:TWCC_SSH_USER      = "your_username"         # 替換為你的 TWCC 帳號

# ── TWCC CLI 資料目錄 ────────────────────────────────────
$env:TWCC_DATA_PATH     = "$env:USERPROFILE\.twcc_data"

# ── 選填：覆蓋預設值 ────────────────────────────────────
# $env:TWCC_SSH_HOST    = "xdata1.twcc.ai"
# $env:TWCC_SSH_KEY     = "$env:USERPROFILE\.ssh\id_ed25519"
# $env:TWCC_DEFAULT_MODEL = "crystalmind"   # crystalmind / gemmapro / gemmapro-r

# ── 編碼設定 ────────────────────────────────────────────
$env:LANG               = "C.UTF-8"
$env:PYTHONIOENCODING   = "UTF-8"

Write-Host "TWCC env ready (user: $env:TWCC_SSH_USER)" -ForegroundColor Green

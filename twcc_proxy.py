#!/usr/bin/env python3
"""
TWCC Proxy — 本地 Ollama 相容代理伺服器
將 Ollama API 請求轉發至 TWCC 開發型容器執行推論

啟動：python twcc_proxy.py
埠號：11434（與 Ollama API 相同）
"""

import os
import io
import re
import json
import time
import uuid
import subprocess
import threading
from pathlib import Path
from datetime import datetime

import paramiko
from flask import Flask, request, jsonify

app = Flask(__name__)

# ── 設定（可透過環境變數覆蓋，詳見 .env.example）──────────
_twcc_user    = os.getenv("TWCC_SSH_USER", "YOUR_USERNAME")
_hfs_work     = os.getenv("TWCC_HFS_WORK_DIR", f"/work/{_twcc_user}")

SSH_HOST      = os.getenv("TWCC_SSH_HOST", "xdata1.twcc.ai")
SSH_PORT      = int(os.getenv("TWCC_SSH_PORT", "22"))
SSH_USER      = _twcc_user
SSH_KEY       = os.getenv("TWCC_SSH_KEY", str(Path.home() / ".ssh" / "id_ed25519"))
HFS_PROXY_DIR = os.getenv("TWCC_HFS_PROXY_DIR", f"{_hfs_work}/proxy")
HFS_WORK_DIR  = _hfs_work

# TWCC_DEFAULT_MODEL: 預設推論模型名稱（需與 HFS 上的 modelfile 一致）
DEFAULT_MODEL    = os.getenv("TWCC_DEFAULT_MODEL", "your-model")
# TWCC_SUPPORTED_MODELS: 逗號分隔的支援模型清單，例如 "model-a,model-b,model-c"
_supported_env   = os.getenv("TWCC_SUPPORTED_MODELS", "")
SUPPORTED_MODELS = set(_supported_env.split(",")) if _supported_env else {DEFAULT_MODEL}
TWCCLI           = str(Path(__file__).parent / ".venv" / "Scripts" / "twccli.exe")
TWCC_DATA_PATH   = os.getenv("TWCC_DATA_PATH", str(Path.home() / ".twcc_data"))
CCS_IMAGE_TYPE   = os.getenv("TWCC_CCS_IMAGE_TYPE", "PyTorch")
CCS_IMAGE        = os.getenv("TWCC_CCS_IMAGE", "pytorch-24.08-py3:latest")
INFERENCE_SCRIPT = os.getenv("TWCC_INFERENCE_SCRIPT",
                             f"{_hfs_work}/scripts/inference.sh")

POLL_INTERVAL = 5    # 輪詢間隔（秒）
TIMEOUT       = 600  # 最長等待時間（秒）


# ── SFTP 工具 ──────────────────────────────────────────────

def get_sftp():
    """建立 SFTP 連線（使用 SSH 金鑰）"""
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(SSH_HOST, port=SSH_PORT, username=SSH_USER,
                   key_filename=SSH_KEY, timeout=15)
    return client, client.open_sftp()


def sftp_mkdir_p(sftp, path):
    """遞迴建立 HFS 目錄"""
    parts = path.split("/")
    current = ""
    for part in parts:
        if not part:
            continue
        current += "/" + part
        try:
            sftp.mkdir(current)
        except Exception:
            pass


def upload_prompt(job_id: str, prompt: str):
    """上傳 prompt 到 HFS"""
    client, sftp = get_sftp()
    try:
        sftp_mkdir_p(sftp, f"{HFS_PROXY_DIR}/input")
        sftp_mkdir_p(sftp, f"{HFS_PROXY_DIR}/output")
        sftp_mkdir_p(sftp, f"{HFS_PROXY_DIR}/logs")
        sftp.putfo(io.BytesIO(prompt.encode("utf-8")),
                   f"{HFS_PROXY_DIR}/input/{job_id}.txt")
        print(f"[proxy] 上傳 prompt ({len(prompt)} 字元) → job={job_id}")
    finally:
        sftp.close()
        client.close()


def poll_result(job_id: str) -> str:
    """輪詢 HFS 等待推論結果"""
    result_path = f"{HFS_PROXY_DIR}/output/{job_id}.txt"
    start = time.time()
    while time.time() - start < TIMEOUT:
        client, sftp = get_sftp()
        try:
            buf = io.BytesIO()
            sftp.getfo(result_path, buf)
            raw = buf.getvalue().decode("utf-8", errors="replace")
            # 清除 ANSI 控制碼
            clean = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', raw)
            clean = re.sub(r'\x1b\[[0-9;?]*[lh]', '', clean)
            print(f"[proxy] 取得結果 ({len(clean)} 字元)")
            return clean.strip()
        except FileNotFoundError:
            elapsed = int(time.time() - start)
            print(f"[proxy] 等待結果中... ({elapsed}s / {TIMEOUT}s)")
        except Exception as e:
            print(f"[proxy] 輪詢錯誤: {e}")
        finally:
            sftp.close()
            client.close()
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"推論逾時（{TIMEOUT}s），請檢查 HFS: {result_path}")


# ── twccli 工具 ────────────────────────────────────────────

def run_twccli(args: list) -> subprocess.CompletedProcess:
    """執行 twccli 指令"""
    env = os.environ.copy()
    env["TWCC_DATA_PATH"] = TWCC_DATA_PATH
    return subprocess.run(
        [TWCCLI] + args,
        capture_output=True, text=True, env=env
    )


def create_container(job_id: str, model: str = DEFAULT_MODEL) -> str:
    """建立 TWCC 開發型容器，等待就緒後回傳容器 ID"""
    # 容器名稱：6~16 字元，小寫字母+數字，字母開頭
    name = f"prx{job_id[:9]}"
    # 傳遞 model 參數給 inference.sh
    safe_model = model if model in SUPPORTED_MODELS else DEFAULT_MODEL
    cmd  = f"bash {INFERENCE_SCRIPT} {job_id} {safe_model}"
    print(f"[proxy] 建立容器: {name}（指令: {cmd}）")

    result = run_twccli([
        "mk", "ccs",
        "-n", name,
        "-itype", CCS_IMAGE_TYPE,
        "-img", CCS_IMAGE,
        "-gpu", "1",
        "-cmd", cmd,
        "-wait",
        "-json"
    ])

    if result.returncode != 0:
        raise RuntimeError(f"建立容器失敗:\n{result.stderr}")

    try:
        data = json.loads(result.stdout)
        # twccli 可能回傳 dict 或 list
        if isinstance(data, list):
            ccs_id = str(data[0]["id"])
        else:
            ccs_id = str(data["id"])
        print(f"[proxy] 容器就緒，ID={ccs_id}")
        return ccs_id
    except Exception:
        raise RuntimeError(f"解析容器 ID 失敗:\n{result.stdout}")


def delete_container(ccs_id: str):
    """刪除容器（背景執行）"""
    print(f"[proxy] 刪除容器 ID={ccs_id}")
    result = run_twccli(["rm", "ccs", "-s", ccs_id, "-f"])
    if result.returncode == 0:
        print(f"[proxy] 容器 {ccs_id} 已刪除")
    else:
        print(f"[proxy] 刪除容器失敗: {result.stderr}")


# ── Flask API ──────────────────────────────────────────────

@app.route("/api/tags", methods=["GET"])
def api_tags():
    """模擬 Ollama GET /api/tags"""
    return jsonify({
        "models": [{
            "name": DEFAULT_MODEL,
            "modified_at": datetime.now().isoformat(),
            "size": 5730000000
        }]
    })


@app.route("/api/generate", methods=["POST"])
def api_generate():
    """模擬 Ollama POST /api/generate"""
    data   = request.json or {}
    prompt = data.get("prompt", "")
    model  = data.get("model", DEFAULT_MODEL)
    job_id = uuid.uuid4().hex[:12]
    ccs_id = None

    print(f"\n{'='*50}")
    print(f"[proxy] 新請求 job={job_id} model={model}")
    print(f"[proxy] prompt: {prompt[:80]}...")

    try:
        upload_prompt(job_id, prompt)
        ccs_id = create_container(job_id, model)
        result = poll_result(job_id)

        return jsonify({
            "model": model,
            "created_at": datetime.now().isoformat(),
            "response": result,
            "done": True
        })

    except Exception as e:
        print(f"[proxy] 錯誤: {e}")
        return jsonify({"error": str(e), "done": True}), 500

    finally:
        if ccs_id:
            threading.Thread(
                target=delete_container, args=(ccs_id,), daemon=True
            ).start()


# ── 啟動檢測 ──────────────────────────────────────────────

import shutil
import sys

def startup_check() -> bool:
    """
    啟動前環境檢測。回傳 False 表示有致命錯誤，應中止啟動。
    """
    ok = True
    print("=" * 60)
    print("TWCC Proxy 環境檢測")
    print("=" * 60)

    global TWCCLI
    # ── 1. 虛擬環境 ──────────────────────────────────────
    in_venv = sys.prefix != sys.base_prefix
    venv_twccli = Path(TWCCLI)
    if in_venv:
        print(f"[✓] 虛擬環境  ：{sys.prefix}")
    else:
        print("[!] 虛擬環境  ：未偵測到 venv（建議使用）")
        print("    建立方式   ：")
        print(f"      cd {Path(__file__).parent}")
        print("      uv venv")
        print("      uv pip install twccli paramiko flask")

    # ── 2. twccli ────────────────────────────────────────
    if venv_twccli.exists():
        print(f"[✓] twccli     ：{TWCCLI}  (venv)")
    else:
        sys_twccli = shutil.which("twccli")
        if sys_twccli:
            TWCCLI = sys_twccli
            print(f"[✓] twccli     ：{TWCCLI}  (系統 PATH)")
        else:
            print("[✗] twccli     ：找不到！")
            print("    安裝方式   ：")
            print("      # 在 venv 內安裝（推薦）")
            print(f"      cd {Path(__file__).parent}")
            print("      uv venv && uv pip install twccli")
            print("      # 或全域安裝")
            print("      pip install twccli")
            ok = False

    # ── 3. SSH 金鑰 ──────────────────────────────────────
    ssh_key_path = Path(SSH_KEY)
    if ssh_key_path.exists():
        print(f"[✓] SSH 金鑰   ：{SSH_KEY}")
    else:
        print(f"[✗] SSH 金鑰   ：找不到 {SSH_KEY}")
        print("    產生方式   ：ssh-keygen -t ed25519")
        print(f"    上傳至 TWCC：ssh-copy-id {SSH_USER}@{SSH_HOST}")
        ok = False

    # ── 4. TWCC 帳號 ─────────────────────────────────────
    if SSH_USER == "YOUR_USERNAME":
        print("[✗] TWCC 帳號  ：尚未設定！")
        print("    請設定環境變數 TWCC_SSH_USER=<你的帳號>")
        print("    或在 twcc_env.ps1 中加入：")
        print("      $env:TWCC_SSH_USER = \"your_username\"")
        ok = False
    else:
        print(f"[✓] TWCC 帳號  ：{SSH_USER}@{SSH_HOST}")

    # ── 5. HFS 路徑提示（遠端，無法自動驗證）────────────
    print()
    print("  HFS 遠端路徑（需手動確認）：")
    print(f"    推論腳本  ：{INFERENCE_SCRIPT}")
    print(f"    模型目錄  ：{HFS_WORK_DIR}/models/")
    print(f"    env.sh    ：/home/{SSH_USER}/env.sh")
    print(f"    輸出暫存  ：{HFS_PROXY_DIR}/")
    print()
    print("  本地路徑：")
    print(f"    腳本目錄  ：{Path(__file__).parent}")
    print(f"    TWCC 資料  ：{TWCC_DATA_PATH}")

    print("=" * 60)
    if not ok:
        print("[!] 請修正上述問題後重新啟動")
        print("=" * 60)
    return ok


# ── 主程式 ────────────────────────────────────────────────

if __name__ == "__main__":
    if not startup_check():
        sys.exit(1)

    print("TWCC Proxy 啟動")
    print(f"  監聽埠：http://localhost:11434")
    print(f"  模型  ：{DEFAULT_MODEL}")
    print("=" * 60)
    app.run(host="0.0.0.0", port=11434, debug=False)

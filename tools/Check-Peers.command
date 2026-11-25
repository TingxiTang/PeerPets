#!/bin/zsh
set -eu
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
cd -- "${0:A:h}"
exec python3 -u - <<'PY'
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
import subprocess
import sys
import tempfile
import time

bridge = Path.cwd() / "peer-check"
if not bridge.is_file():
    sys.exit("请从工作区的 tools 目录打开原始 Check-Peers.command。")
report_dir = bridge.parent.parent / "outputs"
report_dir.mkdir(exist_ok=True)
rows = [f"本机 CLI 回包自检 {datetime.now().astimezone().isoformat(timespec='seconds')}"]
def check(target):
    started = time.monotonic()
    process = subprocess.run(
        [sys.executable, str(bridge), target],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if process.returncode == 0:
        result = "通过，收到 " + process.stdout.strip()
    elif process.returncode == 124:
        lines = process.stderr.strip().splitlines()
        result = lines[-1] if lines else "超时"
    else:
        result = f"失败，退出码 {process.returncode}"
        if process.stderr.strip():
            print(process.stderr[-1500:].strip())
    return process.returncode, f"{target}：{result}（{time.monotonic()-started:.1f} 秒）"


print("同时检查两个接收端，各自沿用桥接的自检时限。")
started = time.monotonic()
with ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(check, ("codex", "antigravity")))
rows.extend(message for code, message in results)
rows.append(f"总用时 {time.monotonic()-started:.1f} 秒")
print("\n".join(rows[1:]))
with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=report_dir,
                                 prefix="peer-check-", suffix=".txt", delete=False) as report:
    report.write("\n".join(rows) + "\n")
print(f"自检结束。结果已保存到 {report.name}")
sys.exit(int(any(code != 0 for code, _ in results)))
PY

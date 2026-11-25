"""同机调用另一个代理。消息从 stdin 读取，答复写到 stdout。"""

import argparse
from contextlib import ExitStack
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid


AGY_TIMEOUT = 120
AGY_CONSULTATION_CAP = 300
CODEX_TIMEOUT = 300
CODEX_CHECK_TIMEOUT = 90
EXECUTION_TIMEOUT = 1800


def prune_old_events(directory, cutoff):
    for old in directory.glob("*.json"):
        try:
            with old.open() as stream:
                if os.fstat(stream.fileno()).st_mtime >= cutoff:
                    continue
                # Active CC records hold this inode locked until a terminal replacement or exit.
                fcntl.flock(stream, fcntl.LOCK_SH | fcntl.LOCK_NB)
                event = json.load(stream)
                if not isinstance(event, dict):
                    continue
                if event.get("phase") in ("starting", "busy", "retrying") and not event.get("ownerLocked"):
                    pid = event.get("pid")
                    if isinstance(pid, int) and 0 < pid <= 2147483647:
                        try:
                            os.kill(pid, 0)
                            continue
                        except ProcessLookupError:
                            pass
                if os.path.samestat(os.fstat(stream.fileno()), old.stat()):
                    old.unlink()
        except (OSError, ValueError):
            continue


def pet_status(event_id, peer, phase, reason=None, elapsed=None, attempts=0, diagnostic=None, *, sender=None, provider=None, lifetime=None):
    """桌宠可随时关闭。仅分享本机的调用状态，所有记录均可丢弃。"""
    directory = Path("/tmp") / f"codex-agy-pet-{os.getuid()}"
    path = directory / event_id
    temporary = path.with_suffix(".tmp")
    try:
        directory.mkdir(mode=0o700, exist_ok=True)
        stat = directory.lstat()
        if directory.is_symlink() or stat.st_uid != os.getuid() or stat.st_mode & 0o077:
            return
        if phase == "starting" or lifetime is not None:
            prune_old_events(directory, time.time() - 86400)
        record = dict(peer=peer, phase=phase, time=time.time(), pid=os.getpid())
        if sender is not None:
            record.update(sender=sender, provider=provider)
        if elapsed is not None:
            record.update(elapsed_seconds=round(elapsed, 3), attempts=attempts)
        if reason:
            record["reason"] = reason
        if diagnostic:
            record["diagnostic"] = diagnostic
        if lifetime is None:
            temporary.write_text(json.dumps(record), encoding="utf-8")
        else:
            stream = lifetime.enter_context(temporary.open("w", encoding="utf-8"))
            fcntl.flock(stream, fcntl.LOCK_EX)
            record["ownerLocked"] = True
            json.dump(record, stream)
            stream.flush()
        temporary.replace(path)
    except OSError:
        pass


def use_macos_agy_proxy(env):
    """Use the Mac's active local proxy for agy's HTTPS calls in an unmanaged, proxy-less shell."""
    if sys.platform != "darwin" or any(key in env for key in (
            "CODEX_NETWORK_PROXY_ACTIVE", "CODEX_SANDBOX_NETWORK_DISABLED")):
        return
    if any(value.strip() for key, value in env.items()
           if key.lower() in {"https_proxy", "http_proxy", "all_proxy"}):
        return
    try:
        settings = subprocess.run(["/usr/sbin/scutil", "--proxy"], capture_output=True,
                                  text=True, timeout=2, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return
    values = dict(re.findall(r"^\s*([A-Za-z0-9]+)\s+:\s+([^\n]+?)\s*$", settings, re.M))
    if any(values.get(key) == "1" for key in ("ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable",
                                              "ExcludeSimpleHostnames")):
        return
    # For an HTTPS destination macOS can select a Secure Web Proxy or a SOCKS proxy.
    for kind, scheme in (("HTTPS", "http"), ("SOCKS", "socks5")):
        if values.get(kind + "Enable") != "1":
            continue
        host = values.get(kind + "Proxy", "")
        port = values.get(kind + "Port", "")
        if host not in {"127.0.0.1", "localhost", "::1"} or not port.isdecimal() or not 0 < int(port) < 65536:
            return
        endpoint = f"{scheme}://{'[::1]' if host == '::1' else host}:{port}"
        exceptions = re.search(r"ExceptionsList\s+:\s+<array>\s*\{([^}]*)\}", settings)
        bypass = re.findall(r"^\s*\d+\s+:\s+(\S+)\s*$", exceptions[1], re.M) if exceptions else []
        bypass.extend([env.get("no_proxy", ""), env.get("NO_PROXY", ""), "localhost", "127.0.0.1", "::1"])
        env["no_proxy"] = env["NO_PROXY"] = ",".join(dict.fromkeys(filter(None, bypass)))
        env["https_proxy"] = env["HTTPS_PROXY"] = endpoint
        print(f"agy CLI：沿用 macOS 已启用的本机 {kind} 代理访问 HTTPS。", file=sys.stderr)
        return


def acp_startup_evidence(directory, env):
    # Expose only fixed labels. The temporary vendor log can contain private URLs or headers.
    proxies = [key for key in ("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY")
               if env.get(key) or env.get(key.lower())]
    labels = ["进程代理变量：" + (", ".join(proxies) or "均未设置")]
    operations = {"fetchavailablemodels": "模型列表", "loadcodeassist": "账户服务",
                  "oauth2.googleapis.com": "Google OAuth", "keyring.go:": "本机凭据存储"}
    errors = {"no such host": "DNS 解析失败", "i/o timeout": "I/O 超时",
              "context deadline exceeded": "请求超时", "connection refused": "连接被拒",
              "proxyconnect": "代理连接异常", "permission denied": "权限不足",
              "operation not permitted": "权限不足", "invalid_grant": "登录凭据无效",
              "x509:": "证书校验错误"}
    seen = []
    findings = []
    try:
        with (directory / "acp.log").open(encoding="utf-8", errors="replace") as log:
            for line in log:
                line = line.lower()
                for marker, name in operations.items():
                    if marker not in line:
                        continue
                    if name not in seen:
                        seen.append(name)
                    for phrase, label in errors.items():
                        if phrase in line and (name, label) not in findings:
                            findings.append((name, label))
    except OSError:
        pass
    if seen:
        labels.append("日志涉及：" + "、".join(seen))
    labels.append("同一行的错误：" + ("、".join(a + "/" + b for a, b in findings) or "未发现匹配项"))
    return "；".join(labels)


def diagnostic_reason(tail):
    # Verbose AGY background services report auth/network errors even on success.
    # Only attribute a failure to a recognizable terminal CLI diagnostic.
    lines = tail.strip().lower().splitlines()
    last = lines[-1].strip() if lines else ""
    if last.startswith("error loading config.toml:") and any(
        msg in last for msg in ("operation not permitted", "permission denied")
    ):
        return "config_permission"
    # Match an actual listen/bind failure, not a failed connection to a local proxy.
    bind_denied = r"\blisten tcp[46]? (?:127\.0\.0\.1|\[::1\]):\d+: bind: (?:operation not permitted|permission denied)\b"
    for line in reversed(lines):
        if re.search(bind_denied, line) and (line == last or any(
            marker in line for marker in ("fatal", "panic:", "failed to start", "failed to listen")
        )):
            return "loopback_permission"
    if any("print mode: invalid model selection" in line for line in lines):
        for line in lines:
            catalog_request = "fetchavailablemodels" in line or "cache(availablemodels)" in line
            if catalog_request and any(msg in line for msg in ("i/o timeout", "context deadline exceeded", "timed out")):
                return "model_catalog_timeout"
        return "model_selection"
    categories = {
        "auth": ("authentication required", "not logged in", "you are not logged into antigravity"),
        "permission": ("permission denied", "operation not permitted"),
        "quota": ("quota exceeded", "rate limit exceeded"),
        "refused": ("connection refused",),
        "connection": ("timed out", "context deadline exceeded"),
    }
    for category, messages in categories.items():
        if any(last.rstrip(".") == m or
               (last.startswith(("error:", "fatal:", "fatal error:")) and m in last)
               for m in messages):
            return category
    return "cli"


class NoACPProgress(subprocess.TimeoutExpired):
    """The turn has produced no qualifying update within the idle window."""


def run_attempt(command, directory, env, message, timeout, activity_file=None, on_start=None):
    hard_deadline = time.monotonic() + timeout
    process = subprocess.Popen(command, cwd=directory, env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    tail = bytearray()

    def forward_errors(stream):
        with stream:
            for chunk in iter(lambda: stream.read1(8192), b""):
                tail.extend(chunk)
                del tail[:-32768]
                sys.stderr.buffer.write(chunk)
                sys.stderr.buffer.flush()

    error_stream = process.stderr
    process.stderr = None
    reader = threading.Thread(target=forward_errors, args=(error_stream,), daemon=True)
    reader.start()
    try:
        if on_start is not None:
            on_start()
        pending_input = message.encode("utf-8")
        wait = min(timeout, AGY_TIMEOUT) if activity_file else timeout
        announced = False
        while True:
            try:
                output, _ = process.communicate(input=pending_input, timeout=wait)
                break
            except subprocess.TimeoutExpired:
                now = time.monotonic()
                if activity_file is None or now >= hard_deadline:
                    raise
                try:
                    last_update = float(activity_file.read_text(encoding="ascii"))
                except (OSError, ValueError):
                    raise NoACPProgress(command, AGY_TIMEOUT) from None
                wait = min(hard_deadline, last_update + AGY_TIMEOUT) - now
                if wait <= 0:
                    raise NoACPProgress(command, AGY_TIMEOUT) from None
                if not announced:
                    print(f"agy CLI：收到本轮有效进展，继续等待原请求，总上限 {AGY_CONSULTATION_CAP} 秒。",
                          file=sys.stderr, flush=True)
                    announced = True
                pending_input = None
    except (KeyboardInterrupt, subprocess.TimeoutExpired):
        # A tool spawned by the CLI can retain its stdout after the CLI exits.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    finally:
        process.stdin.close()
        process.stdout.close()
        reader.join(timeout=1)
    return process.returncode, output.decode("utf-8", errors="replace").strip(), tail.decode("utf-8", errors="replace")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("peer", choices=["codex", "antigravity"])
    parser.add_argument("--cwd", type=Path, help="本次任务的工作目录")
    parser.add_argument("--execute", action="store_true", help="允许在已有授权范围内执行任务")
    parser.add_argument("--context", help="发起方给新对话的一两句交接摘要")
    parser.add_argument("--timeout", type=int, metavar="SECONDS",
                        help=f"指定固定总时限。agy 文字咨询默认静默 {AGY_TIMEOUT} 秒、总计 {AGY_CONSULTATION_CAP} 秒，"
                             f"agy 自检 {AGY_TIMEOUT} 秒，Codex 咨询 {CODEX_TIMEOUT} 秒、"
                             f"自检 {CODEX_CHECK_TIMEOUT} 秒，执行 {EXECUTION_TIMEOUT} 秒")
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--ask", metavar="QUESTION", help="直接咨询；默认在空临时目录中运行")
    inputs.add_argument("--check", action="store_true", help="在空目录核对一次随机回执")
    args = parser.parse_args(argv)
    if args.timeout is not None and args.timeout <= 0:
        parser.error("--timeout 必须是正整数")
    if args.check and (args.cwd is not None or args.execute or args.context):
        parser.error("--check 只接受目标和可选超时")
    if args.ask is not None and args.execute:
        parser.error("--ask 仅用于咨询")
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    with ExitStack() as stack:
        if args.cwd is None and (args.ask is not None or args.check):
            args.cwd = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="peer-")))
        args.cwd = args.cwd or Path.cwd()
        profile = None
        if args.peer == "antigravity" and (args.ask is not None or args.check):
            temporary = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="agy-profile-")))
            profile = temporary / "config"
            profile.mkdir()
        run_request(args, profile)


def run_request(args, profile):
    adaptive = profile is not None and args.ask is not None and args.timeout is None
    timeout = args.timeout
    if timeout is None:
        if args.execute:
            timeout = EXECUTION_TIMEOUT
        elif args.peer == "antigravity":
            timeout = AGY_CONSULTATION_CAP if adaptive else AGY_TIMEOUT
        else:
            timeout = CODEX_CHECK_TIMEOUT if args.check else CODEX_TIMEOUT
    event_id = uuid.uuid4().hex + ".json"

    started = time.monotonic()
    attempts = 0

    def fail(reason, code, message, diagnostic=None):
        pet_status(event_id, args.peer, "failed", reason, time.monotonic()-started, attempts, diagnostic)
        print(message, file=sys.stderr)
        raise SystemExit(code)

    if os.environ.get("WORKSPACE_PEER_ACTIVE"):
        fail("nested", 2, "请将答复或问题返回发起方，由发起方继续对话。")
    if not args.cwd.is_dir():
        fail("directory", 2, "工作目录不存在")
    expected = None
    if args.check:
        expected = args.peer.upper() + "-" + uuid.uuid4().hex[:12]
        message = f"Reply with exactly {expected}. Do not use tools or read files."
    else:
        message = (args.ask if args.ask is not None else sys.stdin.read()).strip()
    if not message:
        fail("empty", 2, "需要提供非空任务。")
    if args.context:
        message = f"交接摘要：{args.context}\n\n本次任务：{message}"

    env = dict(os.environ, WORKSPACE_PEER_ACTIVE="1")
    if args.peer == "codex":
        bundled = Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        binary = os.environ.get("PEER_CODEX_BIN") or (
            str(bundled) if os.access(bundled, os.X_OK) else shutil.which("codex")
        )
        sandbox = "workspace-write" if args.execute else "read-only"
        command = [binary, "exec", "--model", "gpt-6.2-astra", "-c",
                   'model_reasoning_effort="medium"', "--skip-git-repo-check",
                   "--ephemeral", "-s", sandbox, "-"]
        input_text = message
    else:
        binary = os.environ.get("PEER_AGY_BIN") or shutil.which("agy")
        model = "gemini-4-neon-medium"
        if profile:
            use_macos_agy_proxy(env)
            worker = Path(__file__).resolve().with_name("agy_text.py")
            command = [sys.executable, str(worker), binary, profile, model]
            input_text = message
        else:
            command = [binary, "--model", model]
            if not args.execute:
                command += ["--mode", "plan"]
            command += ["-p", message]
            input_text = ""

    if not binary:
        fail("missing", 1, f"找不到 {args.peer} CLI。")
    pet_status(event_id, args.peer, "starting")
    deadline = time.monotonic() + timeout
    try:
        for attempt in range(2):
            attempts = attempt + 1
            pet_status(event_id, args.peer, "busy" if attempt == 0 else "retrying")
            activity_file = profile.parent / "activity" if adaptive else None
            code, reply, errors = run_attempt(command, args.cwd, env, input_text,
                                              max(0, deadline - time.monotonic()), activity_file)
            if code == 130 or code in (-signal.SIGINT, -signal.SIGTERM):
                fail("cancelled", 130, f"{args.peer} 调用已取消。")
            if code == 0:
                if not reply:
                    fail("no_reply", 1, f"{args.peer} 没有返回答复。")
                if expected is not None and reply != expected:
                    fail("mismatch", 1, f"{args.peer} 已回复，但本次自检口令未匹配。")
                break
            reason = diagnostic_reason(errors)
            if reason == "refused" and not profile and not args.execute and attempt == 0 and not reply and deadline - time.monotonic() > 2:
                print("咨询连接被拒绝，将重试一次。", file=sys.stderr)
                time.sleep(1)
                continue
            detail = ""
            if reason == "loopback_permission":
                reason = "permission"
                detail = " CLI 在当前环境监听本地回环端口时被拒绝。"
                if args.check:
                    try:
                        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                            probe.bind(("127.0.0.1", 0))
                            probe.listen(1)
                    except OSError as error:
                        detail += f" 桥接进程的 IPv4 随机端口对照也失败（errno={error.errno}）。"
                    else:
                        detail += " 桥接进程能监听 IPv4 随机端口，请核对 CLI 的具体地址、端口和进程权限。"
                detail += " 本次 CLI 调用已结束，延长等待时间无效。"
            elif reason == "model_catalog_timeout":
                reason = "connection"
                detail = " 获取可用模型列表超时，本次未能选定模型。可用 agy models 核对配置的模型 ID。"
            elif reason == "model_selection":
                reason = "cli"
                detail = " 本次 CLI 未能选定模型。请用 agy models 核对当前可用的模型 ID。"
            elif reason == "config_permission":
                reason = "permission"
                if args.peer == "codex" and not args.execute and not reply:
                    detail = (" Codex 读取配置时受限，本次咨询尚未启动。"
                              "若当前咨询已获授权且未被拒绝，发起方可对同一条命令提交一次客户端正常权限审查。"
                              "若已申请过、界面要求人工批准或策略拒绝，请停在该结果。")
            fail(reason, 1, f"{args.peer} 未完成，退出码 {code}（{reason}）。{detail}")
    except subprocess.TimeoutExpired as error:
        stage = ""
        if profile:
            try:
                stage = " 最后进度：" + (profile.parent / "progress").read_text(encoding="utf-8").strip()
            except OSError:
                stage = " 尚未收到 ACP 启动进度。"
            if "session/new" in stage:
                stage += "。" + acp_startup_evidence(profile.parent, env)
        cause = (f"连续 {AGY_TIMEOUT} 秒未观察到本轮推理或正文片段"
                 if isinstance(error, NoACPProgress) else f"达到总时限 {timeout} 秒")
        fail("timeout", 124, f"{args.peer} {cause}，已停止本地调用。{stage}", cause + stage)
    except KeyboardInterrupt:
        fail("cancelled", 130, f"{args.peer} 调用已取消。")
    except OSError as error:
        reason = "permission" if isinstance(error, PermissionError) else "launch"
        fail(reason, 1, f"{args.peer} 调用失败：{error}")
    pet_status(event_id, args.peer, "done", elapsed=time.monotonic()-started, attempts=attempts)
    print(reply)


if __name__ == "__main__":
    main()

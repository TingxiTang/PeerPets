"""Run one text-only Antigravity ACP turn. The parent owns the process group and deadline."""
import json
from pathlib import Path
import subprocess
import sys
import time


def ask(binary, profile, model, question):
    started = time.monotonic()
    progress_file = Path(profile).parent / "progress"
    activity_file = progress_file.with_name("activity")
    activity_tmp = activity_file.with_suffix(".tmp")
    saw_thought = False

    def progress(label):
        status = f"{label}（开始后 {time.monotonic() - started:.1f} 秒）"
        print("agy CLI：" + status, file=sys.stderr, flush=True)
        progress_file.write_text(status, encoding="utf-8")

    progress("正在启动 CLI")
    command = [binary, "acp", "--stdio", "--gemini-dir", profile,
               "--log-file", str(progress_file.with_name("acp.log")),
               "--include-default-customizations=false", "--sandbox", "--disable-telemetry"]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               text=True, encoding="utf-8")
    replies = []
    session = None

    def send(packet):
        process.stdin.write(json.dumps({"jsonrpc": "2.0", **packet}) + "\n")
        process.stdin.flush()

    def request(sequence, method, params):
        nonlocal saw_thought
        progress("正在请求 " + method)
        send({"id": sequence, "method": method, "params": params})
        for line in process.stdout:
            packet = json.loads(line)
            if "method" in packet:
                if "id" in packet:
                    if packet["method"] == "session/request_permission":
                        send({"id": packet["id"], "result": {"outcome": {"outcome": "cancelled"}}})
                    else:
                        send({"id": packet["id"], "error": {"code": -32601, "message": "Client capability unavailable"}})
                elif packet["method"] == "session/update" and method == "session/prompt":
                    event = packet.get("params", {})
                    update = event.get("update", {})
                    content = update.get("content", {})
                    kind = update.get("sessionUpdate")
                    if not isinstance(content, dict):
                        continue
                    text = content.get("text")
                    if (event.get("sessionId") != session or content.get("type") != "text"
                            or not isinstance(text, str) or not text
                            or kind not in ("agent_message_chunk", "agent_thought_chunk")):
                        continue
                    # A private monotonic timestamp lets the parent wait without reading any thoughts.
                    if text.strip():
                        activity_tmp.write_text(str(time.monotonic()), encoding="ascii")
                        activity_tmp.replace(activity_file)
                    if kind == "agent_message_chunk":
                        if not replies:
                            progress("session/prompt 已收到首段答复，等待完成")
                        replies.append(text)
                    elif text.strip() and not saw_thought:
                        saw_thought = True
                        if not replies:
                            progress("session/prompt 已收到推理活动，等待答复")
            elif packet.get("id") == sequence:
                if "error" in packet:
                    raise ValueError(f"{method}: {packet['error'].get('message', 'RPC error')}")
                return packet["result"]
        raise ValueError(f"{method}: agy CLI closed stdout")

    try:
        request(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}})
        session = request(2, "session/new", {"cwd": str(Path.cwd()), "mcpServers": []})["sessionId"]
        request(3, "session/set_model", {"sessionId": session, "modelId": model})
        result = request(4, "session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": question}]})
        if result.get("stopReason") == "cancelled":
            sys.exit(130)
        if result.get("stopReason") != "end_turn":
            raise ValueError(f"session/prompt: {result.get('stopReason', 'missing stopReason')}")
        progress("session/prompt 已完成")
        return "".join(replies)
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdin.close()
        process.stdout.close()


if __name__ == "__main__":
    try:
        print(ask(*sys.argv[1:], sys.stdin.read()))
    except (OSError, ValueError, KeyError) as error:
        sys.exit(f"ACP: {error}")

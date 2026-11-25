"""Regression tests for unreliable CLI replies. No network or real pet events."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


TOOLS = Path(__file__).resolve().parents[1]
RUNNER = """
import json, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv.pop(1))
import peer
if "TEST_AGY_IDLE" in os.environ:
    peer.AGY_TIMEOUT = float(os.environ["TEST_AGY_IDLE"])
    peer.AGY_CONSULTATION_CAP = float(os.environ["TEST_AGY_CAP"])
def record(event_id, target, phase, reason=None, elapsed=None, attempts=0, diagnostic=None):
    if phase in ("done", "failed"):
        assert elapsed is not None and elapsed >= 0 and attempts >= 0
    with Path("events").open("a") as log:
        print(json.dumps([phase, reason]), file=log)
    if diagnostic:
        Path("diagnostic").write_text(diagnostic)
peer.pet_status = record
peer.main()
"""
FAKE = """#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
counter = pathlib.Path(os.environ['STUB_DIR']) / 'calls'
count = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(count))
mode = os.environ['STUB_MODE']
if sys.argv[1] == 'acp' and (mode.startswith('activity_') or mode in ('echo_check', 'ask', 'ok', 'bad_stop', 'wrong_model', 'slow_new', 'slow_end')):
    import json, re
    profile = pathlib.Path(sys.argv[sys.argv.index('--gemini-dir') + 1])
    assert profile.is_dir() and not list(profile.iterdir()) and profile != pathlib.Path.cwd()
    assert '--include-default-customizations=false' in sys.argv and '--sandbox' in sys.argv
    for line in sys.stdin:
        req = json.loads(line)
        method, params = req['method'], req['params']
        if method == 'initialize':
            assert params['clientCapabilities'] == {}
            result = {'protocolVersion': 1}
        elif method == 'session/new':
            if mode == 'slow_new':
                logfile = pathlib.Path(sys.argv[sys.argv.index('--log-file') + 1])
                logfile.write_text('fetchAvailableModels: i/o timeout private-value-123')
                time.sleep(8)
            assert params['mcpServers'] == [] and params['cwd'] == str(pathlib.Path.cwd())
            result = {'sessionId': 'test'}
        elif method == 'session/set_model':
            assert params['modelId'] == 'gemini-4-neon-medium'
            if mode == 'wrong_model':
                print(json.dumps({'id': req['id'], 'error': {'message': 'model unavailable'}}), flush=True)
                continue
            result = {}
        elif method == 'session/prompt':
            prompt = params['prompt'][0]['text']
            if mode.startswith('activity_'):
                if mode == 'activity_cancel':
                    subprocess.Popen([sys.executable, '-c',
                                      "import pathlib,time; time.sleep(2.5); pathlib.Path(" + repr(str(counter.parent / 'orphan')) + ").touch()"])
                if mode == 'activity_silent':
                    time.sleep(1.3)
                for _ in range(20 if mode in ('activity_cap', 'activity_noise', 'activity_cancel') else 5):
                    time.sleep(.25)
                    session = 'other' if mode == 'activity_noise' else 'test'
                    update = {'sessionUpdate':'agent_thought_chunk', 'content':{'type':'text','text':'private-thought'}}
                    print(json.dumps({'method':'session/update','params':{'sessionId':session,'update':update}}), flush=True)
                    if mode == 'activity_noise':
                        for kind, text in [('agent_message_chunk', ' '), ('unknown_update', 'noise')]:
                            update = {'sessionUpdate':kind, 'content':{'type':'text','text':text}}
                            print(json.dumps({'method':'session/update','params':{'sessionId':'test','update':update}}), flush=True)
                if mode == 'activity_stall':
                    time.sleep(5)
            if mode == 'echo_check':
                reply = re.search(r'ANTIGRAVITY-[0-9a-f]{12}', prompt).group()
            elif mode == 'ask':
                assert prompt == 'A & B'
                reply = 'ok'
            else:
                reply = 'PONG'
            tool_status = {'sessionUpdate':'tool_call_update', 'content':[]}
            print(json.dumps({'method':'session/update','params':{'sessionId':'test','update':tool_status}}))
            for session, kind, part in [('other', 'agent_message_chunk', 'other reply'),
                                        ('test', 'agent_thought_chunk', 'thinking'),
                                        ('test', 'agent_message_chunk', reply[:1]),
                                        ('test', 'agent_message_chunk', reply[1:])]:
                update = {'sessionUpdate': kind, 'content': {'type': 'text', 'text': part}}
                print(json.dumps({'method': 'session/update', 'params': {'sessionId': session, 'update': update}}))
            if mode == 'slow_end':
                sys.stdout.flush()
                time.sleep(8)
            result = {'stopReason': 'cancelled' if mode == 'bad_stop' else 'end_turn'}
        else:
            sys.exit(1)
        print(json.dumps({'id': req['id'], 'result': result}), flush=True)
    sys.exit(0)
if mode == 'echo_check':
    import re
    prompt = sys.argv[-1] if '-p' in sys.argv else sys.stdin.read()
    assert pathlib.Path.cwd() != counter.parent and not list(pathlib.Path.cwd().iterdir())
    print(re.search(r'(CODEX|ANTIGRAVITY)-[0-9a-f]{12}', prompt).group())
    sys.exit(0)
if mode == 'ask':
    assert sys.argv[-1] == 'A & B' and pathlib.Path.cwd() != counter.parent
    print('ok')
    sys.exit(0)
if mode == 'timeout':
    child = "import pathlib,time; time.sleep(2); pathlib.Path('orphan').touch()"
    subprocess.Popen([sys.executable, '-c', child])
    sys.exit(0)
if mode == 'refused' or (mode == 'recover' and count == 1):
    sys.exit('error: connection refused')
if mode == 'mixed':
    sys.exit('not logged in\\nbackground: permission denied\\nunknown failure')
if mode == 'config_denied':
    sys.exit('Error loading config.toml: Failed to read config file config.toml: Operation not permitted (os error 1)')
if mode == 'auth':
    sys.exit('error: authentication required')
if mode == 'bind_denied':
    print('fatal: failed to start: listen tcp 127.0.0.1:0: bind: operation not permitted', file=sys.stderr)
    sys.exit('server stopped')
if mode == 'local_proxy':
    sys.exit('dial tcp 127.0.0.1:7890: connect: permission denied')
if mode == 'bind_warning':
    print('listen tcp 127.0.0.1:0: bind: operation not permitted', file=sys.stderr)
    sys.exit('error: quota exceeded')
if mode == 'partial':
    print('partial')
    sys.exit('error: connection refused')
if mode == 'empty':
    sys.exit(0)
print('not logged in', file=sys.stderr)
print('PONG')
"""


class BridgeTests(unittest.TestCase):
    def invoke(self, mode, *args, target="antigravity", timing=None):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name)
        cli = path / "cli"
        cli.write_text(FAKE)
        cli.chmod(0o700)
        env = dict(os.environ, PEER_AGY_BIN=str(cli), PEER_CODEX_BIN=str(cli), STUB_MODE=mode, STUB_DIR=str(path))
        env.pop("WORKSPACE_PEER_ACTIVE", None)
        if timing:
            env.update(TEST_AGY_IDLE=str(timing[0]), TEST_AGY_CAP=str(timing[1]))
        run = subprocess.run([sys.executable, "-c", RUNNER, str(TOOLS), target, *args],
                             cwd=path, env=env, input="ping", text=True, capture_output=True, timeout=10)
        events = [json.loads(line) for line in (path / "events").read_text().splitlines()]
        return run, events, int((path / "calls").read_text()), path

    def test_success_with_noisy_diagnostics_in_both_directions(self):
        for target in ("codex", "antigravity"):
            with self.subTest(target=target):
                run, events, count, _ = self.invoke("ok", target=target)
                self.assertEqual((run.returncode, run.stdout.strip(), count), (0, "PONG", 1))
                self.assertEqual(events[-1], ["done", None])

    def test_retries_only_once(self):
        for mode, expected in (("recover", ["done", None]), ("refused", ["failed", "refused"])):
            with self.subTest(mode=mode):
                run, events, count, _ = self.invoke(mode)
                self.assertEqual((events[-1], count), (expected, 2))
                self.assertIn(["retrying", None], events)
                self.assertEqual(run.returncode, int(mode == "refused"))

    def test_never_replays_execution_or_partial_output(self):
        for mode, args in (("refused", ["--execute"]), ("partial", [])):
            run, events, count, _ = self.invoke(mode, *args)
            self.assertEqual((run.returncode, events[-1], count), (1, ["failed", "refused"], 1))

    def test_failure_classification_and_empty_reply(self):
        for mode, reason in (("mixed", "cli"), ("auth", "auth"), ("config_denied", "permission"), ("empty", "no_reply")):
            run, events, count, _ = self.invoke(mode)
            self.assertEqual((run.returncode, events[-1], count), (1, ["failed", reason], 1))

    def test_loopback_bind_denial_is_distinct_from_proxy_and_nonfatal_warnings(self):
        for mode, reason in (("bind_denied", "permission"), ("local_proxy", "cli"), ("bind_warning", "quota")):
            with self.subTest(mode=mode):
                run, events, count, _ = self.invoke(mode)
                self.assertEqual((run.returncode, events[-1], count), (1, ["failed", reason], 1))
                self.assertEqual("监听本地回环端口" in run.stderr, mode == "bind_denied")
        run, events, count, _ = self.invoke("bind_denied", "--check")
        self.assertIn("桥接进程", run.stderr)
        self.assertEqual((run.returncode, events[-1], count), (1, ["failed", "permission"], 1))

    def test_consultation_ends_on_loopback_denial(self):
        run, events, count, _ = self.invoke("bind_denied", "--ask", "ping")
        self.assertEqual((run.returncode, events[-1], count), (1, ["failed", "permission"], 1))
        self.assertIn("本次 CLI 调用已结束", run.stderr)
        self.assertNotIn("桌面", run.stderr)

    def test_review_hint_only_for_unstarted_codex_consultation(self):
        for target, args, hint in (("codex", [], True), ("codex", ["--execute"], False),
                                   ("antigravity", [], False)):
            with self.subTest(target=target, args=args):
                run, events, count, _ = self.invoke("config_denied", *args, target=target)
                self.assertEqual("提交一次客户端正常权限审查" in run.stderr, hint)
                self.assertEqual((run.returncode, events[-1], count), (1, ["failed", "permission"], 1))

    def test_unique_checked_reply_from_empty_directory(self):
        for target in ("codex", "antigravity"):
            run, events, _, _ = self.invoke("echo_check", "--check", target=target)
            self.assertEqual((run.returncode, events[-1]), (0, ["done", None]))
            self.assertRegex(run.stdout.strip(), "^" + target.upper() + "-[0-9a-f]{12}$")
        run, events, count, _ = self.invoke("ok", "--check")
        self.assertEqual((run.returncode, events[-1], count), (1, ["failed", "mismatch"], 1))

    def test_one_command_consult(self):
        run, _, _, _ = self.invoke("ask", "--ask", "A & B")
        self.assertEqual((run.returncode, run.stdout.strip()), (0, "ok"))

    def test_real_activity_extends_original_turn_without_replay(self):
        run, events, count, _ = self.invoke("activity_ok", "--ask", "ping", timing=(1, 4))
        self.assertEqual((run.returncode, run.stdout.strip(), events[-1], count), (0, "PONG", ["done", None], 1))
        self.assertIn("继续等待原请求", run.stderr)
        self.assertNotIn("private-thought", run.stdout + run.stderr)

    def test_silence_noise_and_busy_forever_have_distinct_deadlines(self):
        for mode, cause, extended in (("slow_new", "未观察到", False), ("activity_noise", "未观察到", False),
                                      ("activity_stall", "未观察到", True), ("activity_cap", "达到总时限", True)):
            with self.subTest(mode=mode):
                run, events, count, _ = self.invoke(mode, "--ask", "ping", timing=(1, 3.5))
                self.assertIn(cause, run.stderr.splitlines()[-1])
                self.assertEqual("继续等待原请求" in run.stderr, extended)
                self.assertEqual((run.returncode, run.stdout, events[-1], count),
                                 (124, "", ["failed", "timeout"], 1))

    def test_explicit_timeout_is_hard_even_with_recent_thoughts(self):
        run, events, count, _ = self.invoke("activity_cap", "--ask", "ping", "--timeout", "1", timing=(1, 3))
        self.assertIn("达到总时限 1 秒", run.stderr)
        self.assertNotIn("继续等待原请求", run.stderr)
        self.assertEqual((run.returncode, run.stdout, events[-1], count), (124, "", ["failed", "timeout"], 1))

        run, events, count, _ = self.invoke("activity_silent", "--ask", "ping", "--timeout", "5", timing=(1, 3))
        self.assertEqual((run.returncode, run.stdout.strip(), events[-1], count), (0, "PONG", ["done", None], 1))
        run, events, count, _ = self.invoke("activity_cap", "--check", timing=(1, 3))
        self.assertEqual((run.returncode, events[-1], count), (124, ["failed", "timeout"], 1))
        self.assertNotIn("继续等待原请求", run.stderr)

    def test_cancel_during_extension_reaps_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            cli = path / "cli"
            cli.write_text(FAKE)
            cli.chmod(0o700)
            env = dict(os.environ, PEER_AGY_BIN=str(cli), STUB_DIR=directory, STUB_MODE="activity_cancel",
                       TEST_AGY_IDLE="1", TEST_AGY_CAP="5")
            env.pop("WORKSPACE_PEER_ACTIVE", None)
            with subprocess.Popen([sys.executable, "-B", "-c", RUNNER, str(TOOLS), "antigravity", "--ask", "ping"],
                                  cwd=path, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc:
                self.assertTrue(any("继续等待原请求" in line for line in proc.stderr))
                proc.terminate()
                stdout, _ = proc.communicate(timeout=4)
                self.assertEqual((proc.returncode, stdout), (130, ""))
            self.assertEqual(json.loads((path / "events").read_text().splitlines()[-1]), ["failed", "cancelled"])
            time.sleep(2)
            self.assertFalse((path / "orphan").exists())

    def test_acp_requires_selected_model_and_completed_turn(self):
        for mode in ("wrong_model", "bad_stop"):
            with self.subTest(mode=mode):
                run, events, count, _ = self.invoke(mode, "--ask", "ping")
                self.assertEqual((run.returncode, run.stdout, count), (130 if mode == "bad_stop" else 1, "", 1))
                self.assertEqual(events[-1], ["failed", "cancelled" if mode == "bad_stop" else "cli"])

    def test_timeout_stops_descendant_holding_stdout(self):
        run, events, count, path = self.invoke("timeout", "--timeout", "1")
        self.assertEqual((run.returncode, events[-1], count), (124, ["failed", "timeout"], 1))
        time.sleep(1.5)
        self.assertFalse((path / "orphan").exists())

    def test_acp_timeout_reports_last_stage_without_partial_success(self):
        for mode, stage in (("slow_new", "正在请求 session/new"), ("slow_end", "已收到首段答复")):
            with self.subTest(mode=mode):
                run, events, count, _ = self.invoke(mode, "--check", "--timeout", "2")
                self.assertIn(stage, run.stderr.splitlines()[-1])
                self.assertEqual((run.returncode, run.stdout, events[-1], count),
                                 (124, "", ["failed", "timeout"], 1))
                if mode == "slow_new":
                    self.assertIn("模型列表/I/O 超时", run.stderr.splitlines()[-1])
                    self.assertNotIn("private-value-123", run.stderr)


class EntryPointTests(unittest.TestCase):
    def test_fixed_probes_share_bridge_deadline_and_codex_prefers_app(self):
        with patch.object(sys, "path", [str(TOOLS), *sys.path]):
            import peer
        bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        seen = []

        def attempt(command, directory, env, message, timeout, activity_file):
            self.assertIsNone(activity_file)
            seen.append((command, timeout))
            return 0, message.split()[3].rstrip("."), ""

        for target, seconds in (("antigravity", 120), ("codex", 90)):
            with patch.dict(os.environ, {"PATH":"/broken/bin"}, clear=True), \
                    patch.object(sys, "argv", ["peer-check", target]), \
                    patch.object(peer.shutil, "which", side_effect=lambda name: "/broken/bin/" + name), \
                    patch.object(peer.os, "access", return_value=True), \
                    patch.object(peer, "use_macos_agy_proxy"), patch.object(peer, "pet_status"), \
                    patch.object(peer, "run_attempt", side_effect=attempt), patch("builtins.print"):
                runpy.run_path(str(TOOLS / "peer-check"), run_name="__main__")
            command, timeout = seen[-1]
            self.assertTrue(seconds - 1 < timeout <= seconds)
            if target == "codex":
                self.assertEqual(command[0], bundled)
                self.assertIn("gpt-6.2-astra", command)
                self.assertIn('model_reasoning_effort="medium"', command)


class MacProxyTests(unittest.TestCase):
    def setUp(self):
        with patch.object(sys, "path", [str(TOOLS), *sys.path]):
            from peer import use_macos_agy_proxy
        self.configure = use_macos_agy_proxy
        self.settings = """<dictionary> {
  ExceptionsList : <array> {
    0 : 10.0.0.0/8
    1 : *.local
  }
  HTTPSEnable : 0
  SOCKSEnable : 1
  SOCKSProxy : 127.0.0.1
  SOCKSPort : 10895
}"""

    def test_system_proxy_and_exclusions_are_applied_to_child(self):
        env = {"no_proxy": "example.test", "HTTPS_PROXY": ""}
        with patch.object(sys, "platform", "darwin"), patch("subprocess.run") as run:
            run.return_value.stdout = self.settings
            self.configure(env)
        self.assertEqual(env["HTTPS_PROXY"], "socks5://127.0.0.1:10895")
        self.assertEqual(env["HTTPS_PROXY"], env["https_proxy"])
        self.assertTrue({"example.test", "10.0.0.0/8", "*.local", "127.0.0.1"} <= set(env["NO_PROXY"].split(",")))

    def test_existing_proxy_or_managed_context_is_preserved(self):
        for key in ("http_proxy", "ALL_PROXY", "CODEX_NETWORK_PROXY_ACTIVE", "CODEX_SANDBOX_NETWORK_DISABLED"):
            env = {key: "1"}
            with patch.object(sys, "platform", "darwin"), patch("subprocess.run") as run:
                self.configure(env)
                run.assert_not_called()
            self.assertEqual(env, {key: "1"})

    def test_inactive_or_automatic_proxy_is_skipped(self):
        for settings in (self.settings.replace("SOCKSEnable : 1", "SOCKSEnable : 0"),
                         self.settings + "\n  ProxyAutoConfigEnable : 1\n"):
            env = {}
            with patch.object(sys, "platform", "darwin"), patch("subprocess.run") as run:
                run.return_value.stdout = settings
                self.configure(env)
            self.assertEqual(env, {})


if __name__ == "__main__":
    unittest.main()

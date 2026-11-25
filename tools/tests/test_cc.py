"""Exercise the guest bridge with a local, controlled Claude CLI."""
import json
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]
RUN = """
import runpy, sys
from pathlib import Path
sys.path.insert(0, sys.argv.pop(1))
import peer
def record(request, target, phase, *args, **meta):
    with Path('events').open('a') as log:
        print(request, target, phase, args[0], meta['sender'], meta['provider'], file=log)
peer.pet_status=record
runpy.run_path(str(Path(sys.path[0])/'ask-cc'),run_name='__main__')
"""


class GuestBridge(unittest.TestCase):
    def call(self, mode, *args, route="https://api.deepseek.com/anthropic"):
        with tempfile.TemporaryDirectory() as path:
            d = Path(path)
            (d / "claude").write_text("""#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
mode=os.environ['MODE']
assert sys.stdin.read().strip()
if mode=='slow': time.sleep(10)
if mode=='crash': sys.exit(23)
if '--allowedTools' in sys.argv:
    assert 'Edit(/answer.txt)' in sys.argv and 'Bash(./verify)' in sys.argv
    if mode in ('write','invalid'): Path('answer.txt').write_text(mode)
else:
    assert '--bare' in sys.argv and sys.argv[sys.argv.index('--tools')+1]==''
print(json.dumps(dict(result='回执',is_error=mode=='error',modelUsage={('other' if mode=='wrong' else 'deepseek-flash'): {}})))
""")
            (d / "claude").chmod(0o700)
            (d / "verify").write_text("#!/bin/sh\ntest \"$(cat answer.txt)\" = write || exit 7\n")
            (d / "verify").chmod(0o700)
            env=dict(os.environ, PATH=path+os.pathsep+os.environ["PATH"], MODE=mode, ANTHROPIC_BASE_URL=route)
            env.pop("WORKSPACE_PEER_ACTIVE",None)
            run=subprocess.run([sys.executable,"-B","-c",RUN,str(TOOLS),"--from","antigravity",*args,"ping"],
                               cwd=d,env=env,capture_output=True,text=True,timeout=6)
            rows=(d/"events").read_text().splitlines() if (d/"events").exists() else []
            if rows:
                self.assertEqual(len(set(row.split()[0] for row in rows)),1)
                self.assertTrue(all(row.endswith("antigravity deepseek") for row in rows))
                if mode in ("invalid","write"):
                    expected = "verification" if mode == "invalid" else "verified"
                    self.assertEqual(rows[-1].split()[3],expected)
            return run, [row.split()[2] for row in rows]

    def test_receipt_and_failed_routes(self):
        for mode,code in [("ok",0),("wrong",1),("error",1),("crash",1)]:
            run, phases=self.call(mode)
            self.assertEqual(run.returncode,code)
            self.assertEqual(phases,["busy","done" if code==0 else "failed"])
        run,phases=self.call("ok",route="https://example.org")
        self.assertNotEqual(run.returncode,0)
        self.assertFalse(phases)

    def test_timeout_and_output(self):
        run,phases=self.call("slow","--timeout","1")
        self.assertEqual((run.returncode,phases),(124,["busy","failed"]))
        for mode,code in [("write",0),("ok",1),("invalid",1)]:
            run,phases=self.call(mode,"--cwd",".","--output","answer.txt")
            self.assertEqual(run.returncode,code)
            self.assertEqual(phases[-1],"done" if not code else "failed")
            if mode == "invalid":
                self.assertEqual(run.stdout.strip(),"回执")
                self.assertIn("./verify 退出码 7",run.stderr)
            if mode == "write":
                self.assertIn("桥接复验 ./verify 退出码 0",run.stderr)

    def test_cleanup_keeps_old_live_orders(self):
        with patch.object(sys, "path", [str(TOOLS), *sys.path]):
            import peer
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            order = root / "locked.json"
            legacy = root / "legacy.json"
            for path in (order, legacy):
                path.write_text(json.dumps(dict(phase="busy", pid=os.getpid(), ownerLocked=path == order)))
                os.utime(path, (1, 1))
            with order.open() as owner:
                fcntl.flock(owner, fcntl.LOCK_EX)
                peer.prune_old_events(root, time.time()-86400)
                self.assertTrue(order.exists() and legacy.exists())
            peer.prune_old_events(root, time.time()-86400)
            self.assertFalse(order.exists())
            self.assertTrue(legacy.exists())

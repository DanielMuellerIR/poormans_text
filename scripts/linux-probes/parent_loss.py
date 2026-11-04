#!/usr/bin/env python3
"""Negativprobe: überlebt ein Werkzeug den Verlust des echten ProcessRunner-Hosts?"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("runner", type=Path)
args = parser.parse_args()
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0):
    raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
with tempfile.TemporaryDirectory(prefix="pmt-parent-loss-") as temporary:
    root = Path(temporary)
    process = subprocess.Popen([str(args.runner.resolve()), "--parent-loss", temporary])
    child = None
    try:
        deadline = time.monotonic() + 5
        marker = root / "child.pid"
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        child = int(marker.read_text())
        assert os.getpgid(child) == child != os.getpgrp()
        process.kill()
        process.wait(timeout=3)
        time.sleep(0.1)
        state = Path(f"/proc/{child}/stat").read_text().rsplit(")", 1)[1].split()[0]
        alive = state not in ("Z", "X")
        print(json.dumps({"runnerKilled": True, "toolStillRunning": alive,
                          "expectedSafetyGapReproduced": alive}))
        assert alive, "Befund hat sich geändert: Verlustbehandlung neu prüfen"
    finally:
        # Den Runner vor der Ermittlung seiner Kinder anhalten: Sonst könnte
        # zwischen /proc-Abfrage und Kill noch eine neue Werkzeuggruppe entstehen.
        if process.poll() is None:
            try:
                process.send_signal(signal.SIGSTOP)
            except ProcessLookupError:
                pass
        owned_groups = set()
        # Auch ohne vollständigen Marker bleiben die direkten Kinder des
        # Runners bzw. bereits vom Subreaper übernommenen Kinder erreichbar.
        for parent in (process.pid, os.getpid()):
            children = Path(f"/proc/{parent}/task/{parent}/children")
            try:
                candidates = [int(value) for value in children.read_text().split()]
            except FileNotFoundError:
                candidates = []
            for candidate in candidates:
                if candidate == process.pid:
                    continue
                try:
                    if os.getpgid(candidate) == candidate != os.getpgrp():
                        owned_groups.add(candidate)
                except ProcessLookupError:
                    pass
        if process.poll() is None:
            process.kill()
            process.wait(timeout=3)
        for group in owned_groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if not pid:
                time.sleep(0.01)
        else:
            raise RuntimeError("Kindprozesse nicht vollständig geerntet")

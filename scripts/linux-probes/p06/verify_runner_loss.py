#!/usr/bin/env python3
"""Fehlerinjektion gegen die echte CLI; beendet ausschließlich eigene Prozesse."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', type=Path, required=True)
parser.add_argument('--evidence', type=Path)
args = parser.parse_args()
cli = args.cli.resolve()
assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0  # Nur dieser äußere Testbesitzer.
records = {}


def parent(pid):
    for row in Path(f'/proc/{pid}/status').read_text().splitlines():
        if row.startswith('PPid:'):
            return int(row.split()[1])
    raise AssertionError('missing process ancestry')


def reap_all():
    deadline = time.monotonic() + 5
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            assert time.monotonic() < deadline, 'owned descendants did not terminate'
            time.sleep(0.01)


with tempfile.TemporaryDirectory(prefix='pmt-p06-runner-loss-') as temporary:
    root = Path(temporary)
    tool = root / 'slow-pandoc'
    tool.write_text('''#!/bin/sh
trap '' TERM
setsid /bin/sh -c 'trap "" TERM; if (exec 9</proc/1/fd/0) 2>/dev/null; then echo reopened > lease; else echo denied > lease; fi; while :; do printf x >>heartbeat; sleep 0.01; done' &
wait
''')
    tool.chmod(0o755)
    for case in ['timeout', 'cancel', 'runner-loss', 'wrapper-loss', 'guard-loss']:
        directory = root / case
        directory.mkdir()
        source = directory / 'source.rtf'
        original = b'{\\rtf1 PROCESSLOSSALPHA}'
        source.write_bytes(original)
        command = [str(cli), '--json', '--pandoc', str(tool), '--output', str(directory / 'out')]
        if case == 'timeout':
            command += ['--timeout', '0.3']
        process = subprocess.Popen(command + ['--', str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        namespace_fd = wrapper_fd = heartbeat_fd = None
        try:
            deadline = time.monotonic() + 10
            while heartbeat_fd is None:
                for info in directory.glob('.poormans-text-*.tmp/work/.process-*.namespace'):
                    try:
                        child = json.loads(info.read_text())['child-pid']
                        heartbeat = info.parent / 'heartbeat'
                        if heartbeat.exists() and (info.parent / 'lease').exists():
                            wrapper = parent(child)
                            assert parent(wrapper) == process.pid
                            namespace_fd = os.pidfd_open(child)
                            wrapper_fd = os.pidfd_open(wrapper)
                            heartbeat_fd = os.open(heartbeat, os.O_RDONLY | os.O_CLOEXEC)
                            assert (info.parent / 'lease').read_text().strip() == 'denied'
                            break
                    except (ValueError, FileNotFoundError):
                        continue
                assert process.poll() is None, 'CLI ended before fault injection'
                assert time.monotonic() < deadline, 'tool did not start'
                time.sleep(0.005)
            if case == 'cancel':
                process.send_signal(signal.SIGTERM)
            elif case == 'runner-loss':
                process.kill()
            elif case == 'wrapper-loss':
                signal.pidfd_send_signal(wrapper_fd, signal.SIGKILL)
            elif case == 'guard-loss':
                signal.pidfd_send_signal(namespace_fd, signal.SIGKILL)
            stdout, stderr = process.communicate(timeout=10)
            if case != 'runner-loss':
                assert select.select([namespace_fd], [], [], 0)[0], 'CLI returned before namespace end'
            else:
                assert select.select([namespace_fd], [], [], 5)[0], 'runner loss did not terminate namespace'
            before = os.fstat(heartbeat_fd).st_size
            time.sleep(0.1)
            assert os.fstat(heartbeat_fd).st_size == before, 'descendant wrote after end barrier'
            reap_all()
            expected = {'timeout': 124, 'cancel': 130, 'runner-loss': -9}
            assert process.returncode == expected.get(case, 70), (case, process.returncode, stdout, stderr)
            assert not (directory / 'out').exists()
            assert source.read_bytes() == original
            records[case] = {'passed': True, 'exit': process.returncode,
                             'namespaceEndedBeforeCleanup': True, 'heartbeatStopped': True,
                             'leaseReopenDenied': True, 'sourceUnchanged': True, 'noOutput': True}
            print(case, 'PASS', flush=True)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=10)
            if namespace_fd is not None:
                assert select.select([namespace_fd], [], [], 5)[0]
            reap_all()
            for descriptor in [namespace_fd, wrapper_fd, heartbeat_fd]:
                if descriptor is not None:
                    os.close(descriptor)
    for index, delay in enumerate([0, .001, .003, .01, .02, .03, .05, .08, .12, .2, .3, .5]):
        directory = root / f"startup-{index}"
        directory.mkdir()
        source = directory / "source.rtf"
        original = b"{\\rtf1 STARTUPALPHA}"
        source.write_bytes(original)
        process = subprocess.Popen([str(cli), "--json", "--pandoc", str(tool), "--output", str(directory / "out"), "--", str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(delay)
            process.kill()
            process.communicate(timeout=10)
            assert process.returncode == -9
            # ECHILD beim äußeren Subreaper ist die Barriere auch dann, wenn
            # Runnerverlust noch vor dem Namespace-Infoprotokoll eintritt.
            reap_all()
            assert source.read_bytes() == original and not (directory / "out").exists()
            records[f"startup-{index}"] = {"passed": True, "delaySeconds": delay, "exit": -9,
                                           "allOwnedDescendantsReapedBeforeCleanup": True,
                                           "sourceUnchanged": True, "noOutput": True}
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=10)
            children = Path(f"/proc/self/task/{os.getpid()}/children")
            for child in children.read_text().split():
                try:
                    descriptor = os.pidfd_open(int(child))
                except ProcessLookupError:
                    continue
                try:
                    signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                finally:
                    os.close(descriptor)
            reap_all()
    print("12 startup runner-loss cases PASS", flush=True)
if args.evidence:
    args.evidence.write_text(json.dumps(records, indent=2) + '\n')

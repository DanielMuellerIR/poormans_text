#!/usr/bin/env python3
"""P03-Entscheidungsprobe: PID-Namespace mit Lebensdauer-Pipe, kein Produktadapter."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def wait_for(condition, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.005)
    raise TimeoutError('Probe hat ihren erwarteten Zustand nicht erreicht')


def marker(root, role):
    try:
        return json.loads((root / (role + '.ready')).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def children(parent):
    result = set()
    for task in Path(f'/proc/{parent}/task').glob('*'):
        try:
            result.update(map(int, (task / 'children').read_text().split()))
        except (FileNotFoundError, ProcessLookupError):
            pass
    return result


def descendants(parent):
    result = set()
    pending = list(children(parent))
    while pending:
        pid = pending.pop()
        if pid in result:
            continue
        result.add(pid)
        pending.extend(children(pid))
    return result


def owned_pidfd(pid):
    fd = os.pidfd_open(pid)
    # Besitz NACH dem Binden prüfen. Ist die numerische PID vor pidfd_open
    # wiederverwendet worden, darf der neue fremde Prozess kein Signal erhalten.
    current = pid
    visited = set()
    try:
        while current != os.getpid():
            if current <= 1 or current in visited:
                raise ProcessLookupError('PID gehört nicht zum eigenen Probenbaum')
            visited.add(current)
            fields = Path(f'/proc/{current}/stat').read_text().rsplit(')', 1)[1].split()
            current = int(fields[1])
        return fd
    except BaseException:
        os.close(fd)
        raise


def reap_until_empty(timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            time.sleep(0.005)
    raise TimeoutError('Eigene Kindprozesse sind nicht vollständig beendet/geerntet')


def owner(root, fixture, scenario):
    with (root / 'capture').open('wb') as capture, (root / 'namespace.json').open('wb') as info:
        command = ['bwrap', '--unshare-pid', '--unshare-net', '--as-pid-1',
                   '--new-session', '--ro-bind', '/', '/',
                   '--tmpfs', '/home', '--tmpfs', '/root', '--tmpfs', '/run',
                   '--tmpfs', '/tmp', '--ro-bind', str(fixture), '/tmp/probe',
                   '--bind', str(root), '/tmp/work', '--proc', '/proc', '--dev', '/dev',
                   '--info-fd', str(info.fileno()), '/tmp/probe/guard',
                   '/usr/bin/python3', '/tmp/probe/process_tree.py', '/tmp/work']
        if scenario == 'main-exit':
            command.append('--exit-main')
        sandbox = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=capture,
                                   stderr=capture, pass_fds=(info.fileno(),))
        (root / 'wrapper.ready').write_text(str(sandbox.pid))
        def cancel(_number, _frame):
            sandbox.stdin.close()
        signal.signal(signal.SIGTERM, cancel)
        try:
            sandbox.stdin.write(b'\x01')
            sandbox.stdin.flush()
            if scenario == 'timeout':
                wait_for(lambda: (root / 'escaped.ready').exists())
                time.sleep(0.1)
                sandbox.stdin.close()
            return sandbox.wait(timeout=15)
        finally:
            sandbox.stdin.close()
            if sandbox.poll() is None:
                # Der äußere Beobachter räumt auch bei einem fehlgeschlagenen
                # Guard-Nachweis über gehaltene pidfds seine Kinder auf.
                sandbox.kill()
                sandbox.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--owner', type=Path)
    parser.add_argument('--fixture', type=Path)
    parser.add_argument('--scenario', default='runner-loss')
    parser.add_argument('--swift-owner', type=Path,
                        help='Optionaler kompilierter Swift-Harness statt Python-Runner')
    args = parser.parse_args()
    if args.owner:
        return owner(args.owner, args.fixture, args.scenario)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0):
        raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER')
    source = Path(__file__).resolve().parent
    results = []
    with tempfile.TemporaryDirectory(prefix='pmt-p03-supervision-') as temporary:
        root = Path(temporary)
        fixture = root / 'fixture'
        fixture.mkdir()
        shutil.copyfile(source / 'process_tree.py', fixture / 'process_tree.py')
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-O2',
                        str(source / 'namespace_guard.c'), '-o', str(fixture / 'guard')],
                       check=True, timeout=30)
        scenarios = ['runner-loss', 'cancel', 'timeout', 'main-exit', 'guard-loss', 'wrapper-loss']
        scenarios += ['startup-loss'] * 12
        for index, scenario in enumerate(scenarios):
            case = root / str(index)
            case.mkdir()
            if args.swift_owner:
                command = [str(args.swift_owner.resolve()), str(case), str(fixture), scenario]
            else:
                command = [sys.executable, str(Path(__file__).resolve()), '--owner', str(case),
                           '--fixture', str(fixture), '--scenario', scenario]
            process = subprocess.Popen(command)
            handles = []
            try:
                wait_for(lambda: (case / 'wrapper.ready').exists())
                if scenario not in ('startup-loss', 'main-exit'):
                    try:
                        wait_for(lambda: marker(case, 'tool') and marker(case, 'escaped'))
                    except TimeoutError as error:
                        raise RuntimeError((case / 'capture').read_text()) from error
                if scenario == 'startup-loss':
                    time.sleep((index % 4) * 0.002)
                tracked = descendants(process.pid)
                for pid in tracked:
                    try:
                        handles.append(owned_pidfd(pid))
                    except (ProcessLookupError, FileNotFoundError):
                        pass
                started = time.monotonic()
                if scenario in ('runner-loss', 'startup-loss'):
                    process.kill()
                elif scenario == 'cancel':
                    process.terminate()
                elif scenario == 'guard-loss':
                    info = json.loads((case / 'namespace.json').read_text())
                    guard = owned_pidfd(info['child-pid'])
                    try:
                        signal.pidfd_send_signal(guard, signal.SIGKILL)
                    finally:
                        os.close(guard)
                elif scenario == 'wrapper-loss':
                    wrapper = owned_pidfd(int((case / 'wrapper.ready').read_text()))
                    try:
                        signal.pidfd_send_signal(wrapper, signal.SIGKILL)
                    finally:
                        os.close(wrapper)
                process.wait(timeout=5)
                expected_exit = {'runner-loss': -9, 'startup-loss': -9,
                                 'main-exit': 0, 'cancel': 130, 'timeout': 130,
                                 'guard-loss': 137, 'wrapper-loss': -9}[scenario]
                # sys.exit(-9) des Python-Testowners wird zum Shellstatus 247.
                if scenario == 'wrapper-loss':
                    expected_exit = 137 if args.swift_owner else 247
                assert process.returncode == expected_exit, (scenario, process.returncode,
                                                              (case / 'capture').read_text())
                # Der Subreaper beobachtet auch beim frühen Runnerverlust alle
                # verwaisten eigenen Wrapper; ESRCH allein wäre wegen PID-Reuse schwächer.
                reap_until_empty()
                assert all(select.select([fd], [], [], 0)[0] for fd in handles)
                sizes = {p.name: p.stat().st_size for p in case.glob('*.heartbeat')}
                time.sleep(0.05)
                assert sizes == {p.name: p.stat().st_size for p in case.glob('*.heartbeat')}
                if scenario not in ('startup-loss', 'main-exit'):
                    assert len(sizes) == 2
                    assert marker(case, 'tool')['controlPipeAccessDenied']
                    assert marker(case, 'escaped')['controlPipeAccessDenied']
                    assert marker(case, 'tool')['session'] != marker(case, 'escaped')['session']
                    assert marker(case, 'tool')['processGroup'] != marker(case, 'escaped')['processGroup']
                if scenario == 'main-exit':
                    assert (case / 'escaped.ready').exists()
                results.append({'scenario': scenario, 'trackedProcesses': len(handles),
                                'allTrackedExited': True, 'allChildrenReaped': True,
                                'writesStopped': True,
                                'tool': marker(case, 'tool'), 'escapedGrandchild': marker(case, 'escaped'),
                                'observationSeconds': round(time.monotonic() - started, 4),
                                'runnerExit': process.returncode})
            finally:
                # Ausschließlich eigene, aktuell gehaltene Prozessidentitäten.
                if process.poll() is None:
                    process.send_signal(signal.SIGSTOP)
                for pid in descendants(os.getpid()):
                    try:
                        fd = owned_pidfd(pid)
                    except (ProcessLookupError, FileNotFoundError):
                        continue
                    try:
                        signal.pidfd_send_signal(fd, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    finally:
                        os.close(fd)
                process.wait(timeout=3)
                reap_until_empty()
                for fd in handles:
                    os.close(fd)
    print(json.dumps({'probe': 'P03-lifetime-pipe-pid-namespace',
                      'owner': 'Swift-Foundation-Process' if args.swift_owner else 'Python-subprocess',
                      'bubblewrap': subprocess.check_output(['bwrap', '--version'], text=True).strip(),
                      'cases': results, 'productIntegration': False}, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())

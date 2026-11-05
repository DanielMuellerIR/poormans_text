"""Nur eigene Fixture-Snapshots: privater PID-/Netz-Namespace, Systemruntime RO."""
import argparse, hashlib, json, os, pathlib, select, signal, subprocess, time
ROOT = pathlib.Path(__file__).resolve().parent
p = argparse.ArgumentParser()
p.add_argument('--root', type=pathlib.Path, required=True)
p.add_argument('--guard', type=pathlib.Path, required=True)
p.add_argument('case')
p.add_argument('script')
p.add_argument('args', nargs='*')
a = p.parse_args()
ROOT = a.root.resolve()
output = ROOT / 'output' / a.case
output.mkdir(mode=448)
info_r, info_w = os.pipe2(os.O_CLOEXEC)
command = ['/usr/bin/bwrap', '--unshare-pid', '--unshare-net', '--as-pid-1', '--die-with-parent', '--new-session']
for path in ['/usr', '/bin', '/sbin', '/lib', '/lib64', '/etc/ld.so.cache', '/etc/fonts', '/etc/localtime', '/etc/libreoffice']:
    if pathlib.Path(path).exists():
        command += ['--ro-bind', path, path]
command += ['--dir', '/pmt', '--ro-bind', str(ROOT / 'input'), '/pmt/input', '--ro-bind', str(pathlib.Path(a.script).resolve()), '/pmt/probe.py', '--bind', str(output), '/pmt/output', '--bind', str(output), '/pmt/work-scope', '--ro-bind', str(a.guard.resolve()), '/pmt/guard', '--tmpfs', '/tmp', '--proc', '/proc', '--dev', '/dev', '--chdir', '/pmt/output', '--info-fd', str(info_w), '--', '/pmt/guard', '--pmt-ui-guard-v1', '250', '--', '/usr/bin/python3', '/pmt/probe.py'] + a.args
source = ROOT / 'input' / pathlib.Path(a.args[0]).name if a.args and a.args[0].startswith('/pmt/input/') else None
before = hashlib.sha256(source.read_bytes()).hexdigest() if source is not None and source.is_file() else None
started = time.monotonic()
env = {'PATH': '/usr/bin:/bin', 'HOME': '/pmt/output/home', 'TMPDIR': '/tmp', 'SAL_USE_VCLPLUGIN': 'svp', 'LANG': 'C.UTF-8'}
process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(info_w,), env=env)
os.close(info_w)
ns = None
try:
    deadline = time.monotonic() + 5
    data = b''
    while True:
        if not select.select([info_r], [], [], max(0, deadline - time.monotonic()))[0]:
            raise RuntimeError('no complete namespace info')
        chunk = os.read(info_r, 4096 - len(data))
        if not chunk:
            raise RuntimeError('namespace info ended before complete JSON')
        data += chunk
        try:
            pid = json.loads(data)['child-pid']
            break
        except json.JSONDecodeError:
            if len(data) >= 4096 or time.monotonic() >= deadline:
                raise RuntimeError('invalid or incomplete namespace info')
    ns = os.pidfd_open(pid)
    process.stdin.write(b'\x01')
    process.stdin.flush()
    if not select.select([ns], [], [], 45)[0]:
        signal.pidfd_send_signal(ns, signal.SIGKILL)
        raise TimeoutError('isolated UNO probe exceeded 45 seconds')
    process.wait(timeout=5)
    stdout = process.stdout.read(65537)
    stderr = process.stderr.read(65537)
    (output / 'stdout.log').write_bytes(stdout)
    (output / 'stderr.log').write_bytes(stderr)
    after = hashlib.sha256(source.read_bytes()).hexdigest() if before is not None else None
    assert before == after
    print(json.dumps({'sourceSHA256': before, 'sourceUnchanged': before == after, 'case': a.case, 'exit': process.returncode, 'seconds': round(time.monotonic() - started, 3), 'stdout': stdout.decode(errors='replace'), 'stderr': stderr.decode(errors='replace')[-4096:]}))
finally:
    process.stdin.close()
    os.close(info_r)
    if ns is not None:
        if not select.select([ns], [], [], 0)[0]:
            signal.pidfd_send_signal(ns, signal.SIGKILL)
        select.select([ns], [], [], 5)
        os.close(ns)
    if process.poll() is None:
        process.kill()
        process.wait()

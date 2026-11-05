from pathlib import Path
import hashlib, json, os, select, signal, subprocess, time
import argparse
parser = argparse.ArgumentParser()
parser.add_argument('--root', type=pathlib.Path if 'pathlib' in globals() else Path, required=True)
parser.add_argument('--cli', required=True)
parser.add_argument('--source', required=True)
parser.add_argument('--pandoc', required=True)
args = parser.parse_args()
ROOT = args.root.resolve()
ROOT.mkdir(mode=448, parents=True, exist_ok=True)
(ROOT / 'e2e').mkdir(mode=448, exist_ok=True)
cli = Path(args.cli)
source = Path(args.source)
original = hashlib.sha256(source.read_bytes()).hexdigest()
records = []

def ancestor(pid, root):
    for _ in range(64):
        if pid == root:
            return True
        try:
            pid = int(Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[1])
        except (OSError, ValueError):
            return False
        if pid <= 1:
            return False
    return False

def run(name, flags=(), cancel=False):
    target = ROOT / 'e2e' / name
    p = subprocess.Popen([str(cli), '--json', '--progress', '--pandoc', args.pandoc, '--output', str(target), *flags, '--', str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    office = None
    office_limit = None
    deadline = time.monotonic() + 10
    while p.poll() is None and time.monotonic() < deadline:
        for entry in Path('/proc').iterdir():
            if not entry.name.isdigit():
                continue
            try:
                if b'soffice.bin' not in (entry / 'cmdline').read_bytes() or not ancestor(int(entry.name), p.pid):
                    continue
                office = os.pidfd_open(int(entry.name))
                limits = (entry / 'limits').read_text().splitlines()
                row = next(line.split() for line in limits if line.startswith('Max address space'))
                office_limit = tuple(row[3:5])
                if not ancestor(int(entry.name), p.pid):
                    os.close(office)
                    office = None
                    office_limit = None
                    continue
                break
            except OSError:
                continue
        if office is not None:
            break
        time.sleep(0.01)
    if cancel:
        assert office is not None, 'no active LibreOffice process observed'
        p.send_signal(signal.SIGTERM)
    stdout, stderr = p.communicate(timeout=15)
    response = json.loads(stdout)
    checks = {'exit': p.returncode == (130 if cancel else 124), 'sourceUnchanged': hashlib.sha256(source.read_bytes()).hexdigest() == original, 'noOutput': not target.exists(), 'noStaging': not list(target.parent.glob('.poormans-text-*')), 'activeOfficeObserved': office is not None, 'officeAddressSpaceBounded': office_limit == ('3221225472', '3221225472')}
    if office is not None:
        checks['officePidfdEnded'] = bool(select.select([office], [], [], 3)[0])
        os.close(office)
    records.append({'case': name, 'exit': p.returncode, 'checks': checks, 'error': response.get('error')})
    assert all(checks.values()), records[-1]
run('cancel-active', cancel=True)
run('timeout-active', ['--timeout', '0.6'])
parent = ROOT / 'e2e/readonly-parent'
parent.mkdir()
parent.chmod(365)
try:
    target = parent / 'output'
    p = subprocess.run([str(cli), '--json', '--pandoc', args.pandoc, '--output', str(target), '--', str(source)], capture_output=True, timeout=10)
    records.append({'case': 'readonly-parent', 'exit': p.returncode, 'checks': {'failed': p.returncode != 0, 'noOutput': not target.exists(), 'sourceUnchanged': hashlib.sha256(source.read_bytes()).hexdigest() == original}, 'response': json.loads(p.stdout)})
    assert all(records[-1]['checks'].values())
finally:
    parent.chmod(493)
(ROOT / 'cli-extra.json').write_text(json.dumps(records, indent=2))
print(json.dumps(records, indent=2))

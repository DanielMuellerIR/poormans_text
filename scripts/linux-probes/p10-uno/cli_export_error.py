import ctypes, json, os, pathlib, select, struct, subprocess, time
import argparse
parser = argparse.ArgumentParser()
parser.add_argument('--root', type=pathlib.Path if 'pathlib' in globals() else Path, required=True)
parser.add_argument('--cli', required=True)
parser.add_argument('--source', required=True)
parser.add_argument('--pandoc', required=True)
args = parser.parse_args()
root = args.root.resolve()
root.mkdir(mode=448, parents=True, exist_ok=True)
output = root / 'output'
libc = ctypes.CDLL(None, use_errno=True)
fd = libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
assert fd >= 0
watches = {}
denied = None

def watch(path):
    wd = libc.inotify_add_watch(fd, os.fsencode(path), 256 | 128)
    assert wd >= 0
    watches[wd] = path
    global denied
    if path.name == 'html' and any((p.startswith('.pmt-backend-') for p in path.parts)):
        path.chmod(365)
        denied = str(path)
    for child in path.iterdir():
        if child.is_dir() and (not child.is_symlink()):
            watch(child)
watch(root)
p = subprocess.Popen([args.cli, '--json', '--report', '--pandoc', args.pandoc, '--output', str(output), '--', args.source], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
deadline = time.monotonic() + 15
try:
    while p.poll() is None and time.monotonic() < deadline:
        if not select.select([fd], [], [], 0.1)[0]:
            continue
        data = os.read(fd, 65536)
        offset = 0
        while offset < len(data):
            wd, mask, cookie, length = struct.unpack_from('iIII', data, offset)
            offset += 16
            name = data[offset:offset + length].split(b'\x00')[0].decode()
            offset += length
            if wd not in watches or not name:
                continue
            path = watches[wd] / name
            if mask & 1073741824:
                try:
                    watch(path)
                except (AssertionError, FileNotFoundError):
                    continue
                if name == 'html' and any((p.startswith('.pmt-backend-') for p in path.parts)):
                    path.chmod(365)
                    denied = str(path)
    stdout, stderr = p.communicate(timeout=10)
    response = json.loads(stdout)
    result = {'exit': p.returncode, 'error': response.get('error'), 'deniedAtExport': denied is not None, 'noOutput': not output.exists(), 'noStaging': not list(root.glob('.poormans-text-*'))}
    assert p.returncode == 74 and denied is not None and result['noOutput'] and result['noStaging'], (result, stderr)
    assert 'com.sun.star.io.IOException' in result['error'], result
    print(json.dumps(result, indent=2))
    (root / 'cli-export-error.json').write_text(json.dumps(result, indent=2))
finally:
    os.close(fd)
    if p.poll() is None:
        p.kill()
        p.wait()

"""Echte Produktions-GUI unter privatem Weston-Headless/Pixman und AT-SPI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=Path('/usr/bin/poormans-text-app'))
parser.add_argument('--evidence', type=Path, required=True)
parser.add_argument('--work', type=Path)
args = parser.parse_args()
assert os.getuid() == 1000
assert 'LD_LIBRARY_PATH' not in os.environ
if args.work is None:
    with tempfile.TemporaryDirectory(prefix='pmt-wayland-') as temporary:
        root = Path(temporary)
        environment = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'LANGUAGE': 'en',
                       'GDK_BACKEND': 'wayland', 'WAYLAND_DISPLAY': 'pmt-wayland',
                       'GSK_RENDERER': 'gl', 'LIBGL_ALWAYS_SOFTWARE': '1',
                       'GTK_A11Y': 'atspi', 'XDG_SESSION_TYPE': 'wayland',
                       'XDG_CURRENT_DESKTOP': 'Weston'}
        for key, name in [('HOME', 'home'), ('TMPDIR', 'tmp'), ('XDG_RUNTIME_DIR', 'runtime'),
                          ('XDG_CONFIG_HOME', 'config'), ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data')]:
            directory = root / name
            directory.mkdir(mode=0o700)
            environment[key] = str(directory)
        command = ['dbus-run-session', '--', '/usr/bin/python3', '-I', __file__,
                   '--app', str(args.app), '--evidence', str(args.evidence), '--work', str(root)]
        raise SystemExit(subprocess.run(command, env=environment, timeout=100).returncode)

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


def descendants(node, depth=0):
    if depth > 18:
        return
    yield node
    for index in range(min(node.get_child_count(), 500)):
        child = node.get_child_at_index(index)
        if child is not None:
            yield from descendants(child, depth + 1)


assert 'DISPLAY' not in os.environ and os.environ['GDK_BACKEND'] == 'wayland'
root = args.work
socket = Path(os.environ['XDG_RUNTIME_DIR']) / os.environ['WAYLAND_DISPLAY']
source = root / 'source.png'
original = Path('/fixture/source.png').read_bytes()
source.write_bytes(original)
weston_log = root / 'weston.log'
app_log = root / 'app.log'
weston = None
app = None
result = None
try:
    with weston_log.open('wb') as log:
        weston = subprocess.Popen(['weston', '--backend=headless', '--renderer=pixman',
            '--socket=pmt-wayland', '--width=1280', '--height=1000', '--no-config',
            '--idle-time=0', '--debug'], stdout=log, stderr=log)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and weston.poll() is None:
        if socket.exists() and stat.S_ISSOCK(socket.stat().st_mode):
            break
        time.sleep(0.1)
    assert socket.exists() and weston.poll() is None, weston_log.read_text(errors='replace')
    environment = os.environ.copy()
    environment['WAYLAND_DEBUG'] = 'client'
    with app_log.open('wb') as log:
        app = subprocess.Popen([str(args.app), str(source)], env=environment, stdout=log, stderr=log)
    uid = next(line for line in Path(f'/proc/{app.pid}/status').read_text().splitlines() if line.startswith('Uid:'))
    assert set(uid.split()[1:]) == {'1000'}
    def nodes():
        return [n for n in descendants(Atspi.get_desktop(0)) if n.get_process_id() == app.pid]
    def wait_node(name, seconds=10):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            for n in nodes():
                if n.get_name() == name:
                    return n
            time.sleep(.1)
        raise AssertionError('Accessible control absent: '+name)
    def activate(n):
        action = n.get_action_iface()
        if action is not None and action.get_n_actions() > 0:
            assert action.do_action(0), n.get_name()
        else:
            selection = n.get_parent().get_selection_iface()
            if selection is not None:
                assert selection.select_child(n.get_index_in_parent()), n.get_name()
            else:
                children = [c for c in descendants(n) if c != n and c.get_role_name() == 'toggle button' and c.get_action_iface() is not None]
                assert len(children) == 1, ('No existing action or selection', n.get_name(), n.get_role_name())
                assert children[0].get_action_iface().do_action(0)
        time.sleep(.2)
    def capture_to(path):
        before = set(root.glob('*.png')) | set((root / 'home').glob('*.png'))
        c = subprocess.run(['weston-screenshooter'], cwd=root, capture_output=True, timeout=10)
        after = set(root.glob('*.png')) | set((root / 'home').glob('*.png'))
        generated = sorted(after - before)
        assert c.returncode == 0 and generated, c.stderr
        shutil.copyfile(generated[-1], path)
    activate(wait_node('OCR / PDF'))
    time.sleep(.3)
    print('ACCESSIBLE_OCR_TREE', [(n.get_role_name(), n.get_name()) for n in nodes()], flush=True)
    labelnode = wait_node('Image OCR')
    candidates = [n for n in descendants(labelnode.get_parent()) if n.get_role_name() == 'combo box']
    assert len(candidates) == 1, [(n.get_role_name(), n.get_name()) for n in descendants(labelnode.get_parent())]
    dropdown = candidates[0]
    activate(dropdown)
    print('ACCESSIBLE_POPUP_TREE', [(n.get_role_name(), n.get_name()) for n in nodes()], flush=True)
    options = [n for n in nodes() if n.get_name() == 'Off' and n.get_state_set().contains(Atspi.StateType.SHOWING)]
    assert options, 'No visible Off option'
    target = options[0]
    if target.get_action_iface() is None:
        target = target.get_parent()
    activate(target)
    assert any(n.get_name() == 'Off' for n in descendants(dropdown)), 'Dropdown did not retain Off'
    activate(wait_node('Output'))
    deadline = time.monotonic() + 30
    convert = None
    while time.monotonic() < deadline and app.poll() is None:
        for node in descendants(Atspi.get_desktop(0)):
            if node.get_process_id() != app.pid or node.get_name() not in ['Convert', 'Umwandeln']:
                continue
            if node.get_state_set().contains(Atspi.StateType.SENSITIVE):
                action = node.get_action_iface()
                if action is not None and action.get_n_actions() > 0 and action.do_action(0):
                    convert = node
                    break
        if convert is not None:
            break
        time.sleep(0.1)
    assert convert is not None, app_log.read_text(errors='replace')[-8000:]
    markdown = root / 'source-markdown/source.md'
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline and app.poll() is None:
        if markdown.is_file() and convert.get_state_set().contains(Atspi.StateType.SENSITIVE):
            break
        time.sleep(0.1)
    assert markdown.is_file(), app_log.read_text(errors='replace')[-8000:]
    assert convert.get_state_set().contains(Atspi.StateType.SENSITIVE), 'GUI did not finish receiving the result'
    text = markdown.read_text()
    assert '## OCR text' not in text and 'images/image01.png' in text
    assert (markdown.parent / 'images/image01.png').read_bytes() == original
    assert source.read_bytes() == original
    activate(wait_node('Compare source…'))
    wait_node('Source bytes match the comparison identity.', seconds=20)
    activate(wait_node('One preview pixel per logical pixel'))
    wait_node('Zoom · 100%')
    capture_to(args.evidence.with_name('zoom-100.png'))
    activate(wait_node('Fit'))
    wait_node('Zoom · Fit')
    protocol = app_log.read_text(errors='replace')
    assert 'wl_display' in protocol and 'get_registry' in protocol and 'xdg_wm_base' in protocol
    time.sleep(0.3)
    # Native Capture bleibt im privaten Debugsocket dieses einzelnen Tests.
    capture = subprocess.run(['weston-screenshooter'], cwd=root, capture_output=True, timeout=10)
    screenshots = sorted(root.glob('*.png')) + sorted((root / 'home').glob('*.png'))
    screenshot = None
    if capture.returncode == 0 and screenshots:
        from PIL import Image
        with Image.open(screenshots[-1]) as image:
            assert image.width > 0 and image.height > 0
        screenshot = args.evidence.with_suffix('.png')
        shutil.copyfile(screenshots[-1], screenshot)
    result = {'uid': 1000, 'productionGUI': True, 'privateHeadlessWeston': True,
              'compositorRenderer': 'pixman', 'clientRenderer': 'software GL',
              'DISPLAYAbsent': True, 'GDKBackendForcedWayland': True,
              'realWaylandProtocol': True, 'realAccessibleConvertAction': True,
              'GUIFinishedReceivingResult': True, 'actualDropdownOCROff': True, 'actualCompareAction': True, 'actualZoom100AndFit': True, 'originalPNGAssetByteEqual': True,
              'sourceSHA256': hashlib.sha256(original).hexdigest(),
              'sourceUnchanged': True, 'markdownSHA256': hashlib.sha256(markdown.read_bytes()).hexdigest(),
              'outputFiles': {str(path.relative_to(markdown.parent)): hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in markdown.parent.rglob('*') if path.is_file()},
              'nativeCaptureExit': capture.returncode, 'nativeScreenshot': screenshot is not None,
              'captureStderr': capture.stderr.decode(errors='replace')[-2000:]}
    if screenshot:
        result['screenshotSHA256'] = hashlib.sha256(screenshot.read_bytes()).hexdigest()
finally:
    for process in [app, weston]:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    for source_log, name in [(weston_log, 'weston.log'), (app_log, 'client.log')]:
        if source_log.exists():
            sanitized = source_log.read_text(errors='replace').replace(str(root), '$WORK')
            args.evidence.with_name(name).write_text(sanitized[:2_000_000])

assert result is not None
result['GUIAndWestonWaitedAfterTermination'] = True
args.evidence.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))

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
parser.add_argument('--dialogs', action='store_true', help='Exercise real portal file/folder/target dialogs and cancel them.')
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
        if args.dialogs:
            command.append('--dialogs')
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
source = root / 'Quelle ü.csv'
original = 'Key,Value\nWAYLANDCSVMARKER,Grüße\n'.encode()
source.write_bytes(original)
weston_log = root / 'weston.log'
app_log = root / 'app.log'
weston = None
app = None
result = None
monitor = None
dialogs = []
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
    markdown = root / 'Quelle ü-markdown/Quelle ü.md'
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline and app.poll() is None:
        if markdown.is_file() and convert.get_state_set().contains(Atspi.StateType.SENSITIVE):
            break
        time.sleep(0.1)
    if not markdown.is_file():
        accessible = []
        for node in descendants(Atspi.get_desktop(0)):
            if node.get_process_id() == app.pid:
                record = {'role': node.get_role_name(), 'name': node.get_name()}
                text = node.get_text_iface()
                if text is not None:
                    record['text'] = Atspi.Text.get_text(text, 0, min(Atspi.Text.get_character_count(text), 16384))
                accessible.append(record)
        args.evidence.with_suffix('.failure.json').write_text(json.dumps(accessible, ensure_ascii=False, indent=2))
    assert markdown.is_file(), app_log.read_text(errors='replace')[-8000:]
    assert convert.get_state_set().contains(Atspi.StateType.SENSITIVE), 'GUI did not finish receiving the result'
    text = markdown.read_text()
    assert 'WAYLANDCSVMARKER' in text and 'Grüße' in text
    assert source.read_bytes() == original
    protocol = app_log.read_text(errors='replace')
    assert 'wl_display' in protocol and 'get_registry' in protocol and 'xdg_wm_base' in protocol
    if args.dialogs:
        portal_log = root / 'portal.log'
        with portal_log.open('wb') as log:
            monitor = subprocess.Popen(['dbus-monitor', '--session',
                "type='method_call',interface='org.freedesktop.portal.FileChooser'"], stdout=log, stderr=log)
        time.sleep(0.2)
        for title in ['Choose files…', 'Choose folder…', 'Choose target…']:
            button = next(node for node in descendants(Atspi.get_desktop(0))
                          if node.get_process_id() == app.pid and node.get_role() == Atspi.Role.PUSH_BUTTON
                          and node.get_name() == title)
            assert button.get_action_iface().do_action(0), title
            deadline = time.monotonic() + 12
            cancelled_dialog = False
            while time.monotonic() < deadline:
                for node in descendants(Atspi.get_desktop(0)):
                    if node.get_role() != Atspi.Role.PUSH_BUTTON or node.get_name() != 'Cancel' or not node.get_state_set().contains(Atspi.StateType.SENSITIVE):
                        continue
                    action = node.get_action_iface()
                    if action is not None and action.get_n_actions() and action.do_action(0):
                        cancelled_dialog = True
                        break
                if cancelled_dialog:
                    break
                time.sleep(0.1)
            assert cancelled_dialog, 'No accessible file dialog: ' + title
            time.sleep(0.2)
            assert markdown.read_text() == text and source.read_bytes() == original
            dialogs.append(title)
        monitor.terminate()
        monitor.wait(timeout=5)
        calls = portal_log.read_text(errors='replace')
        assert calls.count('member=OpenFile') == 2 and calls.count('member=SaveFile') == 1, calls
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
              'GUIFinishedReceivingResult': True, 'CSVMarkerAndUnicode': True,
              'sourceSHA256': hashlib.sha256(original).hexdigest(),
              'sourceUnchanged': True, 'portalDialogsCancelled': dialogs, 'markdownSHA256': hashlib.sha256(markdown.read_bytes()).hexdigest(),
              'outputFiles': {str(path.relative_to(markdown.parent)): hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in markdown.parent.rglob('*') if path.is_file()},
              'nativeCaptureExit': capture.returncode, 'nativeScreenshot': screenshot is not None,
              'captureStderr': capture.stderr.decode(errors='replace')[-2000:]}
    if screenshot:
        result['screenshotSHA256'] = hashlib.sha256(screenshot.read_bytes()).hexdigest()
finally:
    for process in [monitor, app, weston]:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    for source_log, name in [(weston_log, 'weston.log'), (app_log, 'client.log'), (root / 'portal.log', 'portal.log')]:
        if source_log.exists():
            sanitized = source_log.read_text(errors='replace').replace(str(root), '$WORK')
            args.evidence.with_name(name).write_text(sanitized[:2_000_000])

assert result is not None
result['GUIAndWestonWaitedAfterTermination'] = True
args.evidence.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))

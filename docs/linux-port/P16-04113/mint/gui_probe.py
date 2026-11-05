"""Produkt-GUI im eigenen Xvfb/Sessionbus; Aktivierung über echte AT-SPI-Aktion."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--inner', action='store_true')
parser.add_argument('--screenshot', type=Path)
args = parser.parse_args()
assert os.getuid() == 1000, 'GUI proof must run as the private non-root test user'
assert 'LD_LIBRARY_PATH' not in os.environ, 'GTK must use host distro libraries'
if not args.inner:
    environment = os.environ.copy()
    for key in ['DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'AT_SPI_BUS_ADDRESS']:
        environment.pop(key, None)
    environment.update(GDK_BACKEND='x11', GSK_RENDERER='gl', LIBGL_ALWAYS_SOFTWARE='1',
                       GTK_A11Y='atspi', LANG='C.UTF-8', LANGUAGE='en')
    command = ['xvfb-run', '-a', '-s', '-screen 0 1280x1000x24 -nolisten tcp',
               'dbus-run-session', '--', '/usr/bin/python3', '-I', __file__,
               '--app', str(args.app), '--inner']
    if args.screenshot:
        command += ['--screenshot', str(args.screenshot)]
    raise SystemExit(subprocess.run(command, env=environment, timeout=55).returncode)

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


with __import__('contextlib').nullcontext(Path(__file__).resolve().parent / 'gui-case') as root:
    root.mkdir(mode=0o700)
    source = root / 'Quelle ü.csv'
    original = 'Key,Value\nARCHGUIMARKER,Grüße\n'.encode()
    source.write_bytes(original)
    log = root / 'gui.log'
    with log.open('wb') as output:
        app = subprocess.Popen([str(args.app), str(source)], stdout=output, stderr=output)
        try:
            uid = next(line for line in Path(f'/proc/{app.pid}/status').read_text().splitlines() if line.startswith('Uid:'))
            assert set(uid.split()[1:]) == {'1000'}, uid
            deadline = time.monotonic() + 25
            activated = False
            while time.monotonic() < deadline and app.poll() is None:
                desktop = Atspi.get_desktop(0)
                for application in descendants(desktop):
                    if application.get_process_id() != app.pid:
                        continue
                    if application.get_name() not in ['Convert', 'Umwandeln']:
                        continue
                    if not application.get_state_set().contains(Atspi.StateType.SENSITIVE):
                        continue
                    action = application.get_action_iface()
                    if action is not None and action.get_n_actions() > 0:
                        convert_button = application
                        activated = action.do_action(0)
                        break
                if activated:
                    break
                time.sleep(0.1)
            assert activated, log.read_text(errors='replace')
            markdown = root / 'Quelle ü-markdown/Quelle ü.md'
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and not markdown.is_file() and app.poll() is None:
                time.sleep(0.1)
            assert markdown.is_file(), log.read_text(errors='replace')
            assert 'ARCHGUIMARKER' in markdown.read_text() and 'Grüße' in markdown.read_text()
            assert source.read_bytes() == original
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not convert_button.get_state_set().contains(Atspi.StateType.SENSITIVE):
                time.sleep(0.1)
            assert convert_button.get_state_set().contains(Atspi.StateType.SENSITIVE), 'GUI did not finish receiving the result'
            deadline = time.monotonic() + 10
            completed = False
            while time.monotonic() < deadline:
                names = [n.get_name() for n in descendants(Atspi.get_desktop(0)) if n.get_process_id() == app.pid]
                completed = any(n in ['Completed', 'Abgeschlossen'] for n in names)
                if completed: break
                time.sleep(0.1)
            assert completed, 'GUI Completed state was not observed'
            if args.screenshot:
                from PIL import ImageGrab
                ImageGrab.grab().save(args.screenshot)
            print('PMT_ARCH_GUI_RESULT ' + json.dumps({'uid': 1000, 'productionGUI': True, 'privateXvfbAndDBus': True,
                              'GTKUsesDistroLibraries': True, 'realAccessibleConvertAction': True, 'GUIFinishedReceivingResult': True,
                              'CSVMarkerAndUnicode': True, 'sourceUnchanged': True,
                              'completedStateObserved': completed, 'sourceSHA256': hashlib.sha256(original).hexdigest(), 'markdownSHA256': hashlib.sha256(markdown.read_bytes()).hexdigest(), 'markdown': markdown.read_text()}))
        except Exception:
            if args.screenshot:
                args.screenshot.with_suffix('.log').write_text(log.read_text(errors='replace'))
                try:
                    from PIL import ImageGrab
                    ImageGrab.grab().save(args.screenshot)
                except Exception:
                    pass
            raise
        finally:
            if app.poll() is None:
                windows = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(app.pid)],
                                         capture_output=True, text=True, timeout=3).stdout.split()
                for window in windows:
                    subprocess.run(['xdotool', 'windowclose', window], capture_output=True, timeout=3)
                try:
                    app.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    app.terminate()
                    app.wait(timeout=5)

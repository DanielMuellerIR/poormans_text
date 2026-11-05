"""Positive Portal-Auswahl ausschließlich im privaten Xvfb-Testdesktop."""
import argparse
import ctypes
import hashlib
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

KEY_CONTROL = 0xFFE3
KEY_RETURN = 0xFF0D

parser = argparse.ArgumentParser()
parser.add_argument('--evidence', required=True, type=Path)
parser.add_argument('--work', type=Path, help=argparse.SUPPRESS)
args = parser.parse_args()
assert os.getuid() == 1000 and 'LD_LIBRARY_PATH' not in os.environ
if args.work is None:
    with tempfile.TemporaryDirectory(prefix='pmt-portal-positive-') as temporary:
        root = Path(temporary)
        env = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'LANGUAGE': 'en', 'GDK_BACKEND': 'x11', 'GSK_RENDERER': 'gl', 'LIBGL_ALWAYS_SOFTWARE': '1', 'GTK_A11Y': 'atspi', 'XDG_CURRENT_DESKTOP': 'GNOME', 'XDG_SESSION_TYPE': 'x11'}
        for key, name in [('HOME', 'home'), ('TMPDIR', 'tmp'), ('XDG_RUNTIME_DIR', 'runtime'), ('XDG_CONFIG_HOME', 'config'), ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data')]:
            path = root / name
            path.mkdir(mode=0o700)
            env[key] = str(path)
        raise SystemExit(subprocess.run(['xvfb-run', '-a', '-s', '-screen 0 1280x1000x24 -nolisten tcp', 'dbus-run-session', '--', 'python3', '-I', __file__, '--evidence', str(args.evidence), '--work', str(root)], env=env, timeout=100).returncode)
import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi
root = args.work
assert root.is_absolute() and root.name.startswith('pmt-portal-positive-') and root.stat().st_uid == os.getuid()
assert os.environ['DISPLAY'].startswith(':') and 'WAYLAND_DISPLAY' not in os.environ
assert Path(os.environ['XAUTHORITY']).resolve(strict=True).is_relative_to(root.resolve())
x11 = ctypes.CDLL('libX11.so.6')
xtst = ctypes.CDLL('libXtst.so.6')
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x11.XKeysymToKeycode.restype = ctypes.c_uint
x11.XFlush.argtypes = [ctypes.c_void_p]
x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
xtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
display = x11.XOpenDisplay(os.environ['DISPLAY'].encode())
assert display
x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x11.XDefaultRootWindow.restype = ctypes.c_ulong
x11.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint)]
x11.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_char_p)]
x11.XFree.argtypes = [ctypes.c_void_p]
x11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x11.XInternAtom.restype = ctypes.c_ulong
x11.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]

# Im privaten Xvfb fehlt ein Fenstermanager; nur das an Titel und Portal-PID
# gebundene Fenster darf Fokus für die eigenen Testeingaben erhalten.
def focus_portal(title, pid):
    root_window = x11.XDefaultRootWindow(display)
    parent = ctypes.c_ulong()
    actual_root = ctypes.c_ulong()
    children = ctypes.POINTER(ctypes.c_ulong)()
    count = ctypes.c_uint()
    assert x11.XQueryTree(display, root_window, ctypes.byref(actual_root), ctypes.byref(parent), ctypes.byref(children), ctypes.byref(count))
    matches = []
    try:
        for index in range(count.value):
            window = children[index]
            name = ctypes.c_char_p()
            if not x11.XFetchName(display, window, ctypes.byref(name)) or not name:
                continue
            try:
                actual_name = ctypes.string_at(name).decode(errors='replace')
            finally:
                x11.XFree(name)
            if actual_name != title:
                continue
            kind = ctypes.c_ulong()
            fmt = ctypes.c_int()
            items = ctypes.c_ulong()
            after = ctypes.c_ulong()
            data = ctypes.c_void_p()
            assert x11.XGetWindowProperty(display, window, x11.XInternAtom(display, b'_NET_WM_PID', False), 0, 1, False, 6, ctypes.byref(kind), ctypes.byref(fmt), ctypes.byref(items), ctypes.byref(after), ctypes.byref(data)) == 0
            try:
                if fmt.value == 32 and items.value == 1 and (ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[0] == pid):
                    matches.append(window)
            finally:
                if data:
                    x11.XFree(data)
    finally:
        x11.XFree(children)
    assert len(matches) == 1, (title, matches)
    x11.XSetInputFocus(display, matches[0], 2, 0)
    x11.XFlush(display)
    time.sleep(0.1)

def key(sym, pressed):
    code = x11.XKeysymToKeycode(display, sym)
    assert code
    assert xtst.XTestFakeKeyEvent(display, code, int(pressed), 0)
    x11.XFlush(display)
    time.sleep(0.05)

def press(sym):
    key(sym, True)
    key(sym, False)

def nodes(node=None, depth=0):
    node = Atspi.get_desktop(0) if node is None else node
    if depth > 32:
        return
    yield node
    for index in range(min(500, node.get_child_count())):
        child = node.get_child_at_index(index)
        if child is not None:
            yield from nodes(child, depth + 1)

def wait(predicate, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError('Timed out waiting for ' + predicate.__name__)

def button(title, pid=None):
    for n in nodes():
        if n.get_name() != title or (pid is not None and n.get_process_id() != pid):
            continue
        action = n.get_action_iface()
        if action is not None and action.get_n_actions() and n.get_state_set().contains(Atspi.StateType.SENSITIVE):
            return n
    return None

def click(title):
    n = wait(lambda: button(title, app.pid))
    assert n.get_action_iface().do_action(0)

def dialog():
    return next((n for n in nodes() if n.get_role() == Atspi.Role.FILE_CHOOSER and n.get_process_id() != app.pid), None)

def app_texts():
    result = []
    for n in nodes():
        if n.get_process_id() == app.pid:
            text = n.get_text_iface()
            if text is not None:
                result.append(Atspi.Text.get_text(text, 0, min(Atspi.Text.get_character_count(text), 65536)))
    return result

def click_native(node):
    rectangle = node.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
    assert rectangle.width > 0 and rectangle.height > 0
    x = rectangle.x + rectangle.width // 2
    y = rectangle.y + rectangle.height // 2
    assert 0 <= x < 1280 and 0 <= y < 1000
    assert xtst.XTestFakeMotionEvent(display, -1, x, y, 0)
    assert xtst.XTestFakeButtonEvent(display, 1, True, 0)
    assert xtst.XTestFakeButtonEvent(display, 1, False, 0)
    x11.XFlush(display)

def choose(title, path):
    click(title)
    chooser = wait(dialog)
    pid = chooser.get_process_id()
    focus_portal(chooser.get_name(), pid)
    if path.is_dir():
        home = wait(lambda: next((n for n in nodes() if n.get_process_id() == pid and n.get_name() == 'Home' and (n.get_role() == Atspi.Role.LABEL)), None))
        click_native(home)

        def folder_node():
            for n in nodes():
                if n.get_process_id() != pid or not n.get_state_set().contains(Atspi.StateType.SHOWING):
                    continue
                if n.get_name().strip() == path.name and n.get_component_iface() is not None:
                    return n
            return None
        row = wait(folder_node)
        click_native(row)
    else:
        key(KEY_CONTROL, True)
        try:
            press(ord('l'))
        finally:
            key(KEY_CONTROL, False)

        def focused_entry():
            return next((n for n in nodes() if n.get_process_id() == pid and n.get_editable_text_iface() is not None and n.get_state_set().contains(Atspi.StateType.FOCUSED)), None)
        entry = wait(focused_entry)
        assert entry.get_editable_text_iface().set_text_contents(str(path))
        press(KEY_RETURN)
    time.sleep(0.7)
    if dialog() is not None:
        try:
            confirm = wait(lambda: next((button(name, pid) for name in ['Open', 'Select', 'Save'] if button(name, pid) is not None), None), 8)
        except AssertionError:
            raise AssertionError('Native confirmation button unavailable: ' + title)
        assert confirm.get_action_iface().do_action(0)
    wait(lambda: dialog() is None)
    wait(lambda: any((str(path) in text for text in app_texts())))
    return {'title': title, 'selectedOwnPath': True}

def convert(target, marker):
    click('Convert')

    def converted():
        files = list(target.rglob('*.md')) if target.exists() else []
        return files if files and any((marker in p.read_text() for p in files)) and (button('Convert', app.pid) is not None) else None
    files = wait(converted, 25)
    assert any(('Grüße' in p.read_text() for p in files))
    return {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
source = root / 'Portal ü.csv'
source.write_text('Key,Value\nPORTALFILEMARKER,Grüße\n')
folder = root / 'home/Ordner ü'
folder.mkdir()
member = folder / 'Teil ü.csv'
member.write_text('Key,Value\nPORTALFOLDERMARKER,Grüße\n')
before = {str(p): p.read_bytes() for p in [source, member]}
app = None
monitor = None
result = None
try:
    with (root / 'portal.log').open('wb') as log:
        monitor = subprocess.Popen(['dbus-monitor', '--session', "type='method_call',interface='org.freedesktop.portal.FileChooser'"], stdout=log, stderr=log)
    with (root / 'app.log').open('wb') as log:
        app = subprocess.Popen(['/usr/bin/poormans-text-app'], stdout=log, stderr=log)
    wait(lambda: button('Choose files…', app.pid), 25)
    selected = [choose('Choose files…', source), choose('Choose target…', root / 'Dateiausgabe ü')]
    first = convert(root / 'Dateiausgabe ü', 'PORTALFILEMARKER')
    click('Clear')
    assert folder.is_dir() and member.is_file() and (source.read_bytes() == before[str(source)])
    selected.append(choose('Choose folder…', folder))
    selected.append(choose('Choose target…', root / 'Ordnerausgabe ü'))
    second = convert(root / 'Ordnerausgabe ü', 'PORTALFOLDERMARKER')
    assert all((p.read_bytes() == before[str(p)] for p in [source, member]))
    monitor.terminate()
    monitor.wait(timeout=5)
    calls = (root / 'portal.log').read_text()
    assert calls.count('member=OpenFile') == 2 and calls.count('member=SaveFile') == 2, calls
    from PIL import ImageGrab
    ImageGrab.grab().save(args.evidence.with_suffix('.png'))
    result = {'productionGUI': True, 'privateXvfbAndDBus': True, 'hostDisplayAbsent': True, 'portalSelectionsAccepted': selected, 'fileOutput': first, 'folderOutput': second, 'sourceBytesUnchanged': True, 'portalOpenFileCalls': 2, 'portalSaveFileCalls': 2}
except BaseException:
    from PIL import ImageGrab
    ImageGrab.grab().save(args.evidence.with_suffix('.failure.png'))
    args.evidence.with_suffix('.tree.json').write_text(json.dumps([{'name': n.get_name(), 'role': n.get_role_name(), 'roleID': int(n.get_role()), 'pid': n.get_process_id(), 'table': n.get_table_iface() is not None} for n in nodes()], ensure_ascii=False, indent=2))
    raise
finally:
    for p in [app, monitor]:
        if p is not None and p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait(timeout=5)
    for name in ['app.log', 'portal.log']:
        if (root / name).exists():
            args.evidence.with_name(name).write_text((root / name).read_text(errors='replace').replace(str(root), '$WORK')[:2000000])
    x11.XCloseDisplay(display)
assert result is not None
result['allOwnProcessesWaited'] = True
args.evidence.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(result, ensure_ascii=False, indent=2))

"""Produkt-GUIaktionen und echte Editor-Kopie im eigenen Xvfb/DBus, ohne Testfeatures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--inner', action='store_true')
args = parser.parse_args()
root = Path('/probe')
work = root / 'work-keyboard'
work.mkdir(exist_ok=True)
if not args.inner:
    env = {'PATH': '/pandoc:/usr/bin:/bin', 'LANG': 'C.UTF-8', 'LANGUAGE': 'en',
           'GDK_BACKEND': 'x11', 'GSK_RENDERER': 'cairo', 'GTK_A11Y': 'none',
           'GIO_USE_VFS': 'local', 'GTK_USE_PORTAL': '0'}
    for key, name in [('HOME', 'home'), ('TMPDIR', 'tmp'), ('XDG_RUNTIME_DIR', 'runtime'),
                      ('XDG_CONFIG_HOME', 'config'), ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data')]:
        directory = work / name
        directory.mkdir(mode=0o700, exist_ok=True)
        env[key] = str(directory)
    applications = work / 'data/applications'
    applications.mkdir(exist_ok=True)
    (applications / 'pmt-fastra-test.desktop').write_text('[Desktop Entry]\nType=Application\nName=Private Fastra snapshot\nExec=/probe/fastra/bin/fastra %F\nDBusActivatable=false\nTerminal=false\nMimeType=text/markdown;text/plain;text/x-markdown;\n')
    (work / 'config/mimeapps.list').write_text('[Default Applications]\ntext/markdown=pmt-fastra-test.desktop;\ntext/plain=pmt-fastra-test.desktop;\ntext/x-markdown=pmt-fastra-test.desktop;\n')
    command = ['xvfb-run', '-a', '-s', '-screen 0 1600x1100x24 -nolisten tcp',
               'dbus-run-session', '--', 'env', 'LD_LIBRARY_PATH=/probe/tools/lib',
               '/usr/bin/python3', '-I', __file__, '--inner']
    raise SystemExit(subprocess.run(command, env=env, timeout=200).returncode)

sys.path.insert(0, '/probe/tools/python')
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk, Gdk, GLib, Gio
from PIL import ImageGrab
Gtk.init()
clipboard = Gdk.Display.get_default().get_clipboard()
environment = os.environ.copy()
environment.pop('LD_LIBRARY_PATH', None)
assert Gio.AppInfo.get_default_for_type('text/markdown', False).get_id() == 'pmt-fastra-test.desktop'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def xdo(*arguments):
    result = subprocess.run(['xdotool', *map(str, arguments)], capture_output=True, timeout=5)
    assert result.returncode == 0, result.stderr
    return result.stdout.decode().strip()


def window(pid):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(pid)], capture_output=True)
        if result.returncode == 0:
            return result.stdout.decode().split()[0]
        time.sleep(0.1)
    raise AssertionError('No visible window for the actual product PID')


def click(win, x, y):
    xdo('windowfocus', '--sync', win)
    xdo('mousemove', '--window', win, x, y, 'click', 1)


def pump(seconds=0.2):
    deadline = time.monotonic() + seconds
    context = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        time.sleep(0.01)


def read_clipboard():
    values = []
    def done(source, result):
        try:
            values.append(source.read_text_finish(result) or '')
        except Exception:
            values.append('')
    clipboard.read_text_async(None, done)
    deadline = time.monotonic() + 4
    while not values and time.monotonic() < deadline:
        pump(0.05)
    return values[0] if values else ''


def editor_buffer(win, expected, image_link, label):
    # Leerer eigener Clipboardbesitz verhindert einen alten Quelltextbeleg.
    clipboard.set('')
    pump()
    click(win, 600, 300)
    xdo('key', '--clearmodifiers', 'ctrl+a', 'ctrl+c')
    pump(0.3)
    copied = read_clipboard()
    (root / (label + '-buffer.txt')).write_text(copied)
    assert expected.strip() in copied, copied[:2000]
    assert image_link in copied and 'PMTFASTRAGRAMARKER' in copied
    assert 'München' in copied and 'Größe' in copied and 'α' in copied
    return {'actualEditorCtrlACopy': True, 'completeMarkdownInCopiedBuffer': True,
            'imageMarkdownLinkInSameBuffer': True, 'UnicodeMarkerInBuffer': True,
            'copiedBufferSHA256': hashlib.sha256(copied.encode()).hexdigest()}


def fastra_pids():
    result = set()
    for path in Path('/proc').iterdir():
        if path.name.isdigit():
            try:
                if os.readlink(path / 'exe') == '/probe/fastra/libexec/fastra-linux':
                    result.add(int(path.name))
            except OSError:
                pass
    return result


pins = {}
def pin(pid):
    pins[pid] = os.pidfd_open(pid)
    deadline = time.monotonic() + 5
    expected = 'e83f7e59677a39db95f60a5b9501746a3a8df492b0fcd086f7fa356480e03582'
    while time.monotonic() < deadline:
        executable = sha(f'/proc/{pid}/exe')
        if executable == expected:
            break
        assert not select.select([pins[pid]], [], [], 0)[0], 'Launcher exited before exec'
        pump(0.03)
    assert executable == 'e83f7e59677a39db95f60a5b9501746a3a8df492b0fcd086f7fa356480e03582'
    return {'pid': pid, 'executableSHA256': executable}


def stop(pid):
    fd = pins.pop(pid)
    try:
        if not select.select([fd], [], [], 0)[0]:
            signal.pidfd_send_signal(fd, signal.SIGTERM)
        if not select.select([fd], [], [], 5)[0]:
            signal.pidfd_send_signal(fd, signal.SIGKILL)
        assert select.select([fd], [], [], 5)[0]
    finally:
        os.close(fd)


source = root / 'fixture-build/fixtures/picture-round2.docx'
before = sha(source)
markdown = source.parent / (source.stem + '-markdown') / (source.stem + '.md')
assert not markdown.exists() and not fastra_pids()
pmt = fresh = None
result = {}
with (root / 'pmt-keyboard.log').open('wb') as log, (root / 'reopen-keyboard.log').open('wb') as reopenlog:
    try:
        pmt = subprocess.Popen(['/probe/pmt/ui/poormans-text-app', str(source)], env=environment, stdout=log, stderr=log)
        win = window(pmt.pid)
        pump(2)
        ImageGrab.grab().save(root / 'pmt-before.png')
        click(win, 65, 540)
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline and not markdown.is_file():
            pump(0.1)
        ImageGrab.grab().save(root / 'pmt-after.png')
        assert markdown.is_file(), (root / 'pmt-keyboard.log').read_text(errors='replace')[-4000:]
        pump(1)
        text = markdown.read_text()
        assert 'PMTFASTRAGRAMARKER' in text and 'München' in text
        image_link = re.search(r'!\[[^\]]*\]\(([^)]+\.png)\)', text).group(1)
        asset = markdown.parent / image_link
        assert sha(asset) == sha(root / 'fixture-build/fixture.png')
        published = {str(path.relative_to(markdown.parent)): sha(path) for path in markdown.parent.rglob('*') if path.is_file()}
        click(win, 600, 797)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not fastra_pids():
            pump(0.1)
        first_pid = next(iter(fastra_pids()))
        first = pin(first_pid)
        consumer_window = window(first_pid)
        xdo('windowsize', consumer_window, 1300, 1000)
        pump(2)
        ImageGrab.grab().save(root / 'first-before-copy.png')
        first.update(editor_buffer(consumer_window, text, image_link, 'first'))
        ImageGrab.grab().save(root / 'first.png')
        stop(first_pid)
        pmt.terminate()
        pmt.wait(timeout=10)
        assert not fastra_pids()
        assert {str(path.relative_to(markdown.parent)): sha(path) for path in markdown.parent.rglob('*') if path.is_file()} == published
        fresh = subprocess.Popen(['/probe/fastra/bin/fastra', str(markdown)], env=environment, stdout=reopenlog, stderr=reopenlog)
        second = pin(fresh.pid)
        assert fresh.pid != first_pid
        fresh_window = window(fresh.pid)
        xdo('windowsize', fresh_window, 1300, 1000)
        pump(2)
        second.update(editor_buffer(fresh_window, text, image_link, 'reopen'))
        ImageGrab.grab().save(root / 'reopen.png')
        stop(fresh.pid)
        fresh.wait(timeout=5)
        assert sha(source) == before
        assert {str(path.relative_to(markdown.parent)): sha(path) for path in markdown.parent.rglob('*') if path.is_file()} == published
        result = {'actualPMTConvertButton': True, 'actualPMTGIOOpenButton': True,
                  'privateDefaultApplication': 'pmt-fastra-test.desktop', 'DBusActivatable': False,
                  'first': first, 'freshReopen': second, 'bothAppsEndedBeforeReopen': True,
                  'sourceDOCXSHA256': before, 'sourceUnchanged': True,
                  'publishedFilesSHA256': published, 'publishedFilesUnchangedAfterReopen': True}
    finally:
        for pid in list(pins):
            stop(pid)
        for process in [pmt, fresh]:
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=10)

(root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))

#!/usr/bin/env python3
"""Isolierter GTK-Selbsttest; benötigt Binärdatei mit Feature ui-self-test und Xvfb."""
import argparse, hashlib, json, os, pathlib, subprocess, tempfile, sys, time

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
parser.add_argument('--cli', required=True)
parser.add_argument('--guard')
parser.add_argument('--display', required=True)
parser.add_argument('--work-directory', required=True)
args = parser.parse_args()
if args.guard: os.environ['PMT_PROCESS_GUARD']=os.path.abspath(args.guard)
work = pathlib.Path(args.work_directory)
work.mkdir(parents=True, exist_ok=True)
if 'PMT_UI_TEST_BUS' not in os.environ:
    from xml.sax.saxutils import escape
    runtime=work/'session-runtime';runtime.mkdir(exist_ok=True);runtime.chmod(0o700)
    config=work/'session-bus.conf'
    config.write_text('<busconfig><type>session</type><listen>unix:tmpdir='+escape(str(runtime.resolve()))+'</listen><auth>EXTERNAL</auth><policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy></busconfig>')
    env=os.environ.copy();env['PMT_UI_TEST_BUS']='1';env.update(DISPLAY=args.display,GDK_BACKEND='x11',GSK_RENDERER='cairo',GTK_A11Y='none',GTK_USE_PORTAL='0')
    sys.exit(subprocess.run(['dbus-run-session','--config-file='+str(config.resolve()),'--',sys.executable,__file__,*sys.argv[1:]],env=env).returncode)

root = pathlib.Path(tempfile.mkdtemp(prefix='gtk-test-', dir=work))
sources = root/'sources'
sources.mkdir()
for name, marker in [('é.csv', 'NFCMARKER'), ('e\u0301.csv', 'NFDMARKER')]:
    (sources/name).write_text(f'Key,Value\n{marker},42\n')
originals = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources.iterdir()}
def run(name, extra, initial=None):
    env = os.environ.copy()
    env.update(DISPLAY=args.display, GDK_BACKEND='x11', GSK_RENDERER='cairo', GTK_A11Y='none', LANG='de_DE.UTF-8', PMT_CLI=os.path.abspath(args.cli),
               PMT_UI_TEST_INPUT=str(sources) if initial is None else '', PMT_UI_TEST_OUTPUT=str(root/name), PMT_UI_TEST_QUIT_ON_FINISH='1')
    env.update(extra)
    p = subprocess.run([os.path.abspath(args.binary)] + (initial or []), env=env, capture_output=True, timeout=45)
    log = p.stderr.decode('utf-8', errors='replace')
    (root/f'{name}.log').write_text(log)
    assert p.returncode == 0, (p.returncode, log)
    assert 'panicked at' not in log, log
    return log
log = run('success', {})
line = next(line for line in log.splitlines() if line.startswith('PMT_UI_TEST_RESULT '))
result = json.loads(line.split(' ', 1)[1])
assert result['ok'] is True, result
assert len(result['results']) == 2, result
texts = [pathlib.Path(item['markdownFile']).read_text() for item in result['results']]
for marker in ('NFCMARKER','NFDMARKER'):
    assert sum(marker in text for text in texts) == 1, texts
startup = run('startup', {}, [str(sources/'é.csv'), str(sources/'e\u0301.csv')])
startup_result = json.loads(next(line for line in startup.splitlines() if line.startswith('PMT_UI_TEST_RESULT ')).split(' ',1)[1])
assert startup_result['ok'] is True and len(startup_result['results']) == 2
raw = os.fsencode(root) + b'/bad-\xff.csv'
with open(raw,'wb') as file: file.write(b'Key,Value\nRAW_INVALID,42\n')
replacement = root/'bad-\ufffd.csv'
replacement.write_text('Key,Value\nWRONG_VALID_SIBLING,42\n')
invalid = run('invalid-path', {}, [raw])
assert 'PMT_UI_TEST_ERROR' in invalid and 'valid UTF-8' in invalid, invalid
assert 'PMT_UI_TEST_RESULT' not in invalid and not (root/'invalid-path').exists()
assert open(raw,'rb').read() == b'Key,Value\nRAW_INVALID,42\n'
assert 'WRONG_VALID_SIBLING' in replacement.read_text()
cancel = run('cancel', {'PMT_UI_TEST_CANCEL_MS':'0'})
assert 'PMT_UI_TEST_CANCELLED cleanup-finished' in cancel, cancel
assert 'PMT_UI_TEST_RESULT' not in cancel, cancel
close = run('close', {'PMT_UI_TEST_CLOSE_MS':'0'})
assert 'PMT_UI_TEST_CANCELLED cleanup-finished closing=true' in close, close
assert 'PMT_UI_TEST_RESULT' not in close, close
assert originals == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources.iterdir()}
# Zweite Instanz muss an dasselbe GTK/GApplication weitergeben; eigener Sessionbus.
env=os.environ.copy();env.update(DISPLAY=args.display,GDK_BACKEND='x11',GSK_RENDERER='cairo',GTK_A11Y='none',PMT_CLI=os.path.abspath(args.cli))
log_path=root/'second-instance.log'
with log_path.open('w') as log_file:
    server=subprocess.Popen([os.path.abspath(args.binary),str(sources/'é.csv')],env=env,stdout=log_file,stderr=log_file)
    try:
        for _ in range(100):
            if 'PMT_UI_TEST_OPERATION_FINISHED conversion=false' in log_path.read_text():break
            time.sleep(.05)
        else:raise AssertionError('initial catalog did not finish')
        client=subprocess.run([os.path.abspath(args.binary),str(sources/'e\u0301.csv')],env=env,capture_output=True,timeout=10)
        assert client.returncode==0 and server.poll() is None
        for _ in range(100):
            changes=[json.loads(line.split(' ',1)[1]) for line in log_path.read_text().splitlines() if line.startswith('PMT_UI_TEST_SOURCES ')]
            if len(changes)>=2:break
            time.sleep(.05)
        assert changes[-1]==[list(os.fsencode(sources/'e\u0301.csv'))],changes
    finally:
        server.terminate();server.wait(timeout=10)
busy_sources=root/'busy-sources';busy_sources.mkdir()
for index in range(600): (busy_sources/f'{index:04}.csv').write_text('A,B\nBUSYMARKER,42\n')
env=os.environ.copy();env.update(DISPLAY=args.display,GDK_BACKEND='x11',GSK_RENDERER='cairo',GTK_A11Y='none',PMT_CLI=os.path.abspath(args.cli),PMT_UI_TEST_INPUT=str(busy_sources),PMT_UI_TEST_OUTPUT=str(root/'busy-output'),PMT_UI_TEST_QUIT_ON_FINISH='1',PMT_UI_TEST_CANCEL_MS='500')
busy_log=root/'busy-open.log'
with busy_log.open('w') as log_file:
    server=subprocess.Popen([os.path.abspath(args.binary)],env=env,stdout=log_file,stderr=log_file)
    try:
        for _ in range(100):
            if 'PMT_UI_TEST_JOB_STARTED conversion=true' in busy_log.read_text():break
            time.sleep(.01)
        else:raise AssertionError('conversion did not start')
        client=subprocess.run([os.path.abspath(args.binary),str(replacement)],env=env,capture_output=True,timeout=10)
        server.wait(timeout=20)
        text=busy_log.read_text()
        assert client.returncode==0 and 'PMT_UI_TEST_REJECTED_SOURCE busy' in text,text
        assert 'PMT_UI_TEST_RESULT' not in text and 'PMT_UI_TEST_CANCELLED' in text,text
        changes=[line for line in text.splitlines() if line.startswith('PMT_UI_TEST_SOURCES ')]
        assert len(changes)==1,changes
    finally:
        if server.poll() is None: server.terminate();server.wait(timeout=10)
summary = {'gtkConversion':'pass','canonicalSourcePair':'pass','cancelCleanup':'pass','closeWaitsForCleanup':'pass','sourceHashes':'unchanged','startupArguments':'pass','secondInstanceOpen':'pass','busyFileOpen':'rejected without changing generation/source','invalidUTF8Argument':'rejected without sibling substitution','evidenceDirectory':str(root)}
(work/'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary))

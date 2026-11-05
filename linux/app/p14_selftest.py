#!/usr/bin/env python3
"""P14-Tests ausschließlich mit synthetischen Daten, Xvfb und abgeschirmter GTK-Sitzung."""
import argparse, hashlib, json, os, pathlib, pwd, re, subprocess, zipfile, shutil

parser=argparse.ArgumentParser()
parser.add_argument('--binary',required=True)
parser.add_argument('--cli',required=True)
parser.add_argument('--guard',required=True)
parser.add_argument('--support-root',required=True,help='Read-only root containing the CLI launcher and its complete runtime')
parser.add_argument('--display',required=True,help='Dedicated Xvfb display, e.g. :2')
parser.add_argument('--heic-fixture', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[2]/'docs/linux-port/P16-04112/preview/heic-fixtures/single.heic')
parser.add_argument('--work-directory',required=True)
args=parser.parse_args()
display=re.fullmatch(r':([0-9]+)',args.display)
if not display or int(display[1])<2: parser.error('Use a dedicated Xvfb display >= :2.')
binary=pathlib.Path(args.binary).resolve(strict=True);guard=pathlib.Path(args.guard).resolve(strict=True)
support=pathlib.Path(args.support_root).resolve(strict=True);cli=pathlib.Path(args.cli).resolve(strict=True)
try: relative_cli=cli.relative_to(support)
except ValueError: parser.error('--cli must be inside --support-root')
if support in (pathlib.Path('/'),pathlib.Path('/home'),pathlib.Path.home(),pathlib.Path('/tmp')): parser.error('Choose a narrowly scoped runtime/repository support root.')
work=pathlib.Path(args.work_directory).resolve();work.mkdir(parents=True,exist_ok=True)
for name in ['home','config','data','cache','runtime','gio','fixtures','cwd']:
    (work/name).mkdir(exist_ok=True);(work/name).chmod(0o700)
(work/'bus.conf').write_text('<busconfig><type>session</type><listen>unix:tmpdir=/probe/runtime</listen><auth>EXTERNAL</auth><policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy></busconfig>')
fixtures=work/'fixtures'
from PIL import Image
image=Image.new('RGB',(24,16),(10,30,240));second=Image.new('RGB',(24,16),(240,30,10))
for ext,fmt in [('png','PNG'),('jpg','JPEG'),('gif','GIF'),('tiff','TIFF'),('bmp','BMP'),('webp','WEBP')]:
    options={'save_all':True,'append_images':[second]} if ext in ('gif','tiff') else {}
    image.save(fixtures/f'source.{ext}',format=fmt,**options)
shutil.copyfile(args.heic_fixture, fixtures/'source.heic')
(fixtures/'source.html').write_bytes(b'<p>PRIVATE_CLIPBOARD_SYNTHETIC</p>')
(fixtures/'source.rtf').write_bytes(b'{\\rtf1\\ansi\\ansicpg1252 ORIGINAL_\xe4_BYTES}')
for filename,token in [('profile.xlsx','PROFILE_UI_MARKER'),('profile-changed.xlsx','CHANGED_UI_MARKER')]:
    with zipfile.ZipFile(fixtures/filename,'w',zipfile.ZIP_STORED) as archive:
        entries={
          '[Content_Types].xml':'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
          '_rels/.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
          'xl/workbook.xml':'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Fixture" sheetId="1" r:id="rId1"/></sheets></workbook>',
          'xl/_rels/workbook.xml.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
          'xl/worksheets/sheet1.xml':f'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Key</t></is></c><c r="B1" t="inlineStr"><is><t>Value</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>{token}</t></is></c><c r="B2"><v>42</v></c></row></sheetData></worksheet>'}
        for name,xml in entries.items():archive.writestr(name,xml)

base=['bwrap','--unshare-all','--new-session','--die-with-parent']
for path in ['/usr','/etc','/lib','/lib64','/bin']:base+=['--ro-bind',path,path]
base+=['--proc','/proc','--dev','/dev','--dir','/home','--bind',str(work/'home'),pwd.getpwuid(os.getuid()).pw_dir,
       '--bind',str(work),'/probe','--tmpfs','/tmp','--dir','/tmp/.X11-unix',
       '--ro-bind',f'/tmp/.X11-unix/X{display[1]}',f'/tmp/.X11-unix/X{display[1]}',
       '--ro-bind',str(binary),'/app/poormans-text-app','--ro-bind',str(guard),'/app/poormans-text-process-guard',
       '--ro-bind',str(support),'/runtime']
settings={'DISPLAY':args.display,'TMPDIR':'/tmp','GDK_BACKEND':'x11','GSK_RENDERER':'cairo','GTK_A11Y':'none','GTK_USE_PORTAL':'0','LANGUAGE':'de','LC_ALL':'C.UTF-8',
          'XDG_CONFIG_HOME':'/probe/config','XDG_DATA_HOME':'/probe/data','XDG_CACHE_HOME':'/probe/cache','XDG_RUNTIME_DIR':'/probe/runtime',
          'GIO_USE_VFS':'local','GIO_USE_VOLUME_MONITOR':'unix','GIO_MODULE_DIR':'/probe/gio','GIO_EXTRA_MODULES':'/probe/gio','GSETTINGS_BACKEND':'memory',
          'PMT_CLI':str(pathlib.Path('/runtime')/relative_cli),'PMT_PROCESS_GUARD':'/app/poormans-text-process-guard'}
for key,value in settings.items():base+=['--setenv',key,value]
for key in ['DBUS_SESSION_BUS_ADDRESS','LD_LIBRARY_PATH','PYTHONPATH','PYTHONHOME','XAUTHORITY']:base+=['--unsetenv',key]
base+=['--chdir','/probe/cwd']
env={key:value for key,value in os.environ.items() if not key.startswith('PMT_UI_TEST_')}
def run(mode,settings):
    command=base.copy()
    for key,value in settings.items():command+=['--setenv',key,value]
    command+=['/usr/bin/dbus-run-session','--config-file=/probe/bus.conf','--','/app/poormans-text-app']
    with (work/f'{mode}.log').open('w') as log:
        completed=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=90)
    text=(work/f'{mode}.log').read_text()
    assert completed.returncode==0,(mode,completed.returncode,text)
    assert 'FAILURE' not in text and 'panicked at' not in text,text
    return text
clipboard=run('clipboard',{'PMT_UI_TEST_CLIPBOARD':'/probe/fixtures'})
assert clipboard.count('exact-bytes-sealed-no-host-file')==9,clipboard
for marker in ['64MiB-rejected','cancelled-and-cleaned','during-real-cli-job','complete-real-md-exact','clear-cleaned-after-real-job','PMT_UI_TEST_CLIPBOARD_CLOSE released-after-job-barrier']:assert marker in clipboard,(marker,clipboard)
result=json.loads(next(line.split(' ',1)[1] for line in clipboard.splitlines() if line.startswith('PMT_UI_TEST_RESULT ')))
assert result['ok'] is True and result['sourceIdentity']['sha256']==hashlib.sha256((fixtures/'source.png').read_bytes()).hexdigest(),result
close=run('clipboard-close',{'PMT_UI_TEST_CLIPBOARD':'/probe/fixtures','PMT_UI_TEST_CLIPBOARD_CLOSE_DURING_JOB':'1'})
assert 'cleanup-finished closing=true' in close and 'PMT_UI_TEST_CLIPBOARD_CLOSE released-after-job-barrier' in close and 'PMT_UI_TEST_RESULT ' not in close,close
profiles=run('profiles',{'PMT_UI_TEST_PROFILES':'/probe/fixtures'})
for marker in ['PMT_UI_TEST_PROFILE_DEFAULTS','changed-source-rejected','rejected-without-consent','explicitly-authorized-save-only','export-import-list-exact-name','PMT_UI_TEST_PROFILE_COMPLETE']:assert marker in profiles,(marker,profiles)
summary={'originalClipboardEncodings':9,'readLimit':'64 MiB+1 rejected','clipboardCancel':'pass','clipboardRealConversionAndHash':'pass','copyCompleteRealMarkdown':'pass','clearCleanup':'pass','closeCleanupAfterJobBarrier':'pass','profileDefaultsNotOverridden':'pass','boundSourceMismatch':'rejected','localProfileConsent':'required','profileExportImport':'pass'}
(work/'summary.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary))

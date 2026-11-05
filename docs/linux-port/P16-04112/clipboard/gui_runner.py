#!/usr/bin/env python3
"""Nur eigener Xvfb/private D-Bus-Sitzung; synthetische Fixtures, kein Benutzerdesktop."""
import argparse,os,pathlib,pwd,re,subprocess
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--candidate',required=True,help='Private CLI-support directory with cli launcher, ELF, resources and guard');p.add_argument('--runtime',required=True,help='Read-only Swift runtime root');p.add_argument('--fixtures',required=True);p.add_argument('--display',required=True);p.add_argument('--work-directory',required=True);p.add_argument('--mode',choices=['bound','clipboard','clipboard-close','profiles'],default='pdf');p.add_argument('--source',default='source.png');a=p.parse_args()
match=re.fullmatch(r':([0-9]+)',a.display);assert match and int(match[1])>=2,'Dedicated Xvfb display >= :2 required'
work=pathlib.Path(a.work_directory).resolve();assert work not in [pathlib.Path('/'),pathlib.Path.home(),pathlib.Path('/tmp')];work.mkdir(parents=True,exist_ok=True)
for name in ['home','config','data','cache','runtime','gio','cwd']:(work/name).mkdir(exist_ok=True);(work/name).chmod(0o700)
(work/'bus.conf').write_text('<busconfig><type>session</type><listen>unix:tmpdir=/probe/runtime</listen><auth>EXTERNAL</auth><policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy></busconfig>')
command=['bwrap','--unshare-all','--new-session','--die-with-parent']
for path in ['/usr','/etc','/lib','/lib64','/bin']:command+=['--ro-bind',path,path]
command+=['--proc','/proc','--dev','/dev','--dir','/home','--bind',str(work/'home'),pwd.getpwuid(os.getuid()).pw_dir,'--bind',str(work),'/probe','--tmpfs','/tmp','--dir','/tmp/.X11-unix','--ro-bind',f'/tmp/.X11-unix/X{a.display[1:]}',f'/tmp/.X11-unix/X{a.display[1:]}','--ro-bind',str(pathlib.Path(a.binary).resolve()),'/app/poormans-text-app','--ro-bind',str(pathlib.Path(a.candidate).resolve()),'/candidate','--ro-bind',str(pathlib.Path(a.runtime).resolve()),'/base-runtime','--bind',str(pathlib.Path(a.fixtures).resolve()),'/clip-fixtures']
settings={'DISPLAY':a.display,'HOME':pwd.getpwuid(os.getuid()).pw_dir,'GDK_BACKEND':'x11','GSK_RENDERER':'cairo','GTK_A11Y':'none','GTK_USE_PORTAL':'0','LANGUAGE':'de','LC_ALL':'C.UTF-8','XDG_CONFIG_HOME':'/probe/config','XDG_DATA_HOME':'/probe/data','XDG_CACHE_HOME':'/probe/cache','XDG_RUNTIME_DIR':'/probe/runtime','GIO_USE_VFS':'local','GIO_USE_VOLUME_MONITOR':'unix','GIO_MODULE_DIR':'/probe/gio','GIO_EXTRA_MODULES':'/probe/gio','GSETTINGS_BACKEND':'memory','PMT_CLI':'/candidate/cli','PMT_PROCESS_GUARD':'/candidate/poormans-text-process-guard'}
if a.mode=='bound':settings['PMT_UI_TEST_BOUND_SOURCE']='/clip-fixtures/'+a.source;settings['PMT_UI_TEST_BOUND_PANDOC']='/tools/pandoc'
elif a.mode=='profiles':settings['PMT_UI_TEST_PROFILES']='/clip-fixtures'
else:settings['PMT_UI_TEST_CLIPBOARD']='/clip-fixtures'
if os.environ.get('PMT_PROBE_ERROR'):settings['PMT_UI_TEST_BOUND_ERROR']='1'
if os.environ.get('PMT_PROBE_RELEASE'):settings['PMT_UI_TEST_BOUND_RELEASE']='1'
if os.environ.get('PMT_PROBE_PAUSE'):settings['PMT_UI_TEST_BOUND_PAUSE_MS']='3000'
if os.environ.get('PMT_PROBE_BOUND_CLOSE'):settings['PMT_UI_TEST_BOUND_CLOSE']='1'
if a.mode=='clipboard-close':settings['PMT_UI_TEST_CLIPBOARD_CLOSE_DURING_JOB']='1'
command+=['--ro-bind','/tmp/pmt-night-tools/pandoc','/tools/pandoc']
for key,value in settings.items():command+=['--setenv',key,value]
for key in ['DBUS_SESSION_BUS_ADDRESS','LD_LIBRARY_PATH','XAUTHORITY','PYTHONHOME','PYTHONPATH']:command+=['--unsetenv',key]
command+=['--chdir','/probe/cwd','/usr/bin/dbus-run-session','--config-file=/probe/bus.conf','--','/app/poormans-text-app']
env={k:v for k,v in os.environ.items() if not k.startswith('PMT_UI_TEST_')}
with (work/'run.log').open('w') as out:
 if os.environ.get('PMT_PROBE_SCREENSHOT'):
  import time
  result=subprocess.Popen(command,env=env,stdout=out,stderr=subprocess.STDOUT);captured=False;deadline=time.monotonic()+60
  while result.poll() is None and time.monotonic()<deadline:
   if not captured and 'PMT_UI_TEST_BOUND_RASTER_COMPLETE' in (work/'run.log').read_text():
    displayenv={**os.environ,'DISPLAY':a.display}
    ids=subprocess.run(['xdotool','search','--name','Verifizierter Quellvergleich'],env=displayenv,capture_output=True,text=True).stdout.split()
    for xid in ids:subprocess.run(['xdotool','windowsize',xid,'700','700'],env=displayenv,check=True)
    subprocess.run(['import','-window','root',str(work/'screenshot.png')],env=displayenv,check=True);captured=True
   time.sleep(.05)
  if result.poll() is None:result.kill()
  result.wait(timeout=5);assert captured
 else:result=subprocess.run(command,env=env,stdout=out,stderr=subprocess.STDOUT,timeout=60)
text=(work/'run.log').read_text();marker=('PMT_UI_TEST_BOUND_TEXT_COMPLETE' if a.source.endswith(('.html','.rtf')) else 'PMT_UI_TEST_BOUND_RASTER_COMPLETE') if a.mode=='bound' else 'PMT_UI_TEST_PROFILE_COMPLETE' if a.mode=='profiles' else 'PMT_UI_TEST_CLIPBOARD_CLOSE released-after-job-barrier' if a.mode=='clipboard-close' else 'PMT_UI_TEST_CLIPBOARD_UI clear-cleaned-after-real-job'
if os.environ.get('PMT_PROBE_ERROR'):marker='PMT_UI_TEST_BOUND_ERROR_RELEASE'
if os.environ.get('PMT_PROBE_RELEASE'):marker='PMT_UI_TEST_BOUND_RELEASE_COMPLETE'
if os.environ.get('PMT_PROBE_BOUND_CLOSE'):marker='PMT_UI_TEST_BOUND_CANCEL_COMPLETE'
assert result.returncode==0 and marker in text and 'FAILURE' not in text,(result.returncode,text)
print(a.mode,'PASS')

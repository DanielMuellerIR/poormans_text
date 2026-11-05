#!/usr/bin/env python3
"""Begrenzte private DPKG-Rootprobe ohne Overlay oder Hostsystem-Schreibbindung."""
import argparse,hashlib,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--old',type=Path,required=True);p.add_argument('--new',type=Path,required=True);p.add_argument('--root',type=Path,required=True);a=p.parse_args()
assert os.getuid()!=0,'outer process must be unprivileged';assert not a.root.exists();a.root.mkdir();root=a.root/'root';root.mkdir();results=a.root/'result';results.mkdir()
sha=lambda p:hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
marker=a.root/'outside-marker';marker.write_text('OUTSIDE-PRIVATE-ROOT\n')
watch={'true':Path('/usr/bin/true'),'hostDPKGStatus':Path('/var/lib/dpkg/status'),'oldDEB':a.old,'newDEB':a.new,'outsideMarker':marker};before={k:sha(v) for k,v in watch.items()}
for n in ['host/usr','usr/bin','usr/lib','usr/share/applications','usr/share/doc','etc','var/lib','var/log','var/cache','proc','dev','tmp','run','work','inputs','private-home']:(root/n).mkdir(parents=True,exist_ok=True)
# Nur private Verzeichnisse; alle fremden Programme/Bibliotheken sind RO-Symlinkziele.
def proxy(source,dest,exceptions):
 for entry in source.iterdir():
  if entry.name not in exceptions:(dest/entry.name).symlink_to('/host/'+str(entry.relative_to('/')))
proxy(Path('/usr'),root/'usr',{'bin','lib','share'});proxy(Path('/usr/bin'),root/'usr/bin',{'poormans-text','poormans-text-app'});proxy(Path('/usr/lib'),root/'usr/lib',{'poormans-text'});proxy(Path('/usr/share'),root/'usr/share',{'applications','doc'});proxy(Path('/usr/share/doc'),root/'usr/share/doc',{'poormans-text'})
if Path('/usr/share/applications').is_dir():proxy(Path('/usr/share/applications'),root/'usr/share/applications',{'org.poormanstext.Linux.desktop','mimeinfo.cache'})
for n in ['bin','sbin','lib','lib64']:
 if Path('/'+n).exists():(root/n).symlink_to('usr/'+n)
locks={'/var/lib/dpkg':{'lock','lock-frontend'},'/var/lib/dpkg/triggers':{'Lock'}}
shutil.copytree('/var/lib/dpkg',root/'var/lib/dpkg',symlinks=True,ignore=lambda directory,names:locks.get(directory,set()))
for name in ['lock','lock-frontend','triggers/Lock']:(root/'var/lib/dpkg'/name).touch()
for n in ['dpkg','alternatives']:
 if Path('/etc',n).is_dir():shutil.copytree(Path('/etc',n),root/'etc'/n,symlinks=True)
for n in ['passwd','group','nsswitch.conf','ld.so.cache','debian_version','os-release']:
 if Path('/etc',n).is_file():shutil.copyfile(Path('/etc',n),root/'etc'/n)
shutil.copyfile(Path(__file__).with_name('inside.py'),root/'work/inside.py')
(root/'work/source.csv').write_text('Name,Count\nÄpfel,12\nBirnen,7\n');source_before=sha(root/'work/source.csv')
for n in ['outside-marker','inputs/old.deb','inputs/new.deb']:(root/n).touch()
cmd=['bwrap','--die-with-parent','--new-session','--unshare-user','--uid','0','--gid','0','--unshare-pid','--unshare-net','--unshare-ipc','--unshare-uts','--bind',str(root),'/','--ro-bind','/usr','/host/usr','--ro-bind',str(marker),'/outside-marker','--ro-bind',str(a.old.resolve()),'/inputs/old.deb','--ro-bind',str(a.new.resolve()),'/inputs/new.deb','--proc','/proc','--dev','/dev','--tmpfs','/tmp','--clearenv','--setenv','PATH','/usr/sbin:/usr/bin:/sbin:/bin','--setenv','LANG','C.UTF-8','--setenv','HOME','/private-home','--setenv','TMPDIR','/tmp','--chdir','/work','--','/usr/bin/python3','/work/inside.py']
try:
 result=subprocess.run(cmd,capture_output=True,text=True,timeout=180);(results/'stdout.txt').write_text(result.stdout);(results/'stderr.txt').write_text(result.stderr)
except subprocess.TimeoutExpired as e:
 result=None;(results/'stderr.txt').write_text('outer timeout180s');raise
finally:
 after={k:sha(v) for k,v in watch.items()};report={'outerUID':os.getuid(),'innerUIDMapping':'0 maps to outer unprivileged user; no host-root claim','before':before,'after':after,'hostAndPackageInputsUnchanged':before==after,'sourceUnchanged':sha(root/'work/source.csv')==source_before,'exit':result.returncode if result else None};(results/'outer.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report));assert report['hostAndPackageInputsUnchanged'] and report['sourceUnchanged'];raise SystemExit(result.returncode)

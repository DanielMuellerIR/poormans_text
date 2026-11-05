from pathlib import Path
import os,hashlib,subprocess,json,shutil,sys
root=Path(sys.argv[1]).resolve();assert str(root).startswith('/tmp/pmt-mint-pdf13.') and root.is_dir() and root.stat().st_uid==os.getuid()
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def tree(p):
 return {str(f.relative_to(p)):{'sha256':sha(f),'mode':f.stat().st_mode&0o777,'link':os.readlink(f) if f.is_symlink() else None} for f in Path(p).rglob('*') if f.is_file()}
standard=Path('/usr/lib/x86_64-linux-gnu/girepository-1.0');baseline={'girepo':tree(standard),'dso':sha('/usr/lib/x86_64-linux-gnu/libpoppler-glib.so.8'),'true':sha('/usr/bin/true'),'dpkgStatus':sha('/var/lib/dpkg/status')}
(root/'host-before.json').write_text(json.dumps(baseline,indent=2)+'\n')
pkg=root/'gir1.2-poppler-0.18_24.02.0-1ubuntu9.11_amd64.deb';assert pkg.stat().st_size==26266 and sha(pkg)=='8231c377b2c736c2c80699b935350441e6b18839610037e816cf8cf9281dc229'
metadata=subprocess.check_output(['dpkg-deb','-f',str(pkg),'Version','Architecture'],text=True);assert '24.02.0-1ubuntu9.11' in metadata and 'amd64' in metadata
subprocess.run(['dpkg-deb','-x',str(pkg),str(root/'typepkg')],check=True)
shutil.copytree(standard,root/'girepo',symlinks=False)
typefile=root/'typepkg/usr/lib/x86_64-linux-gnu/girepository-1.0/Poppler-0.18.typelib';assert typefile.is_file();shutil.copy2(typefile,root/'girepo/Poppler-0.18.typelib')
for name in ['home','run','tmp']:(root/name).mkdir(mode=0o700)
inner='''import gi,cairo,os,json,pathlib
gi.require_version('Poppler','0.18')
from gi.repository import Poppler
entries=[line for line in pathlib.Path('/proc/self/mountinfo').read_text().splitlines() if line.split()[4]=='/usr/lib/x86_64-linux-gnu/girepository-1.0']
assert len(entries)==1 and 'ro' in entries[0].split()[5].split(',')
print(json.dumps({'PopplerVersion':Poppler.get_version(),'cairoVersion':cairo.cairo_version_string(),'giVersion':gi.__version__,'typelibBindReadOnly':True,'uid':os.getuid(),'namespaces':{n:os.readlink('/proc/self/ns/'+n) for n in ['user','pid','net','mnt']}}))
'''
(root/'import_inside.py').write_text(inner)
command=['bwrap','--unshare-all','--die-with-parent','--new-session','--ro-bind','/','/','--tmpfs','/home','--tmpfs','/root','--tmpfs','/run','--tmpfs','/tmp','--proc','/proc','--dev','/dev','--bind',str(root),str(root),'--ro-bind',str(root/'girepo'),str(standard),'--clearenv','--setenv','PATH','/usr/bin:/bin','--setenv','HOME',str(root/'home'),'--setenv','TMPDIR',str(root/'tmp'),'--chdir',str(root),'--','/usr/bin/python3','-I',str(root/'import_inside.py')]
p=subprocess.run(command,capture_output=True,text=True,timeout=15);assert p.returncode==0,(p.returncode,p.stdout,p.stderr);result=json.loads(p.stdout);hostNS={n:os.readlink('/proc/self/ns/'+n) for n in result['namespaces']};assert all(result['namespaces'][n]!=hostNS[n] for n in hostNS)
(root/'import-proof.json').write_text(json.dumps({'result':result,'hostNamespaces':hostNS,'packageMetadata':metadata,'typelibSHA256':sha(typefile)},indent=2)+'\n');print(p.stdout)

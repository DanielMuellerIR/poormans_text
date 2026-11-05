from pathlib import Path
import os,json,subprocess,hashlib,stat
root=Path(__file__).resolve().parent;assert str(root).startswith('/tmp/pmt-mint-doc14.')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def profile():
 p=Path.home()/'.config/libreoffice';rows=[]
 if p.exists():
  for f in [p,*p.rglob('*')]:
   m=f.lstat();rows.append([hashlib.sha256(os.fsencode(str(f.relative_to(p)))).hexdigest(),m.st_mode,m.st_size,m.st_mtime_ns,m.st_ctime_ns])
 return {'exists':p.exists(),'entries':len(rows),'metadataSHA256':hashlib.sha256(json.dumps(sorted(rows)).encode()).hexdigest()}
baseline={'hostProfile':profile(),'true':sha('/usr/bin/true'),'dpkgStatus':sha('/var/lib/dpkg/status')};(root/'host-before.json').write_text(json.dumps(baseline,indent=2)+'\n')
pkg=root/'.build/linux-preview-04114/poormans-text_0.41.14~linuxpreview1_amd64.deb';assert sha(pkg)=='c93e87876b3882fe078f93cd27741937d4368c32bfe6cb3924fcb4e212e19cb0';subprocess.run(['dpkg-deb','-x',str(pkg),str(root/'extracted')],check=True,timeout=30)
for name in ['home','tmp','session']:(root/name).mkdir(mode=0o700,exist_ok=True)
command=['bwrap','--unshare-all','--die-with-parent','--new-session','--ro-bind','/','/','--tmpfs','/home','--tmpfs','/root','--tmpfs','/run','--tmpfs','/tmp','--proc','/proc','--dev','/dev','--bind',str(root),str(root),'--clearenv','--setenv','PATH','/usr/bin:/bin','--setenv','HOME',str(root/'home'),'--setenv','XDG_CONFIG_HOME',str(root/'home/config'),'--setenv','XDG_CACHE_HOME',str(root/'home/cache'),'--setenv','XDG_DATA_HOME',str(root/'home/data'),'--setenv','XDG_RUNTIME_DIR',str(root/'session'),'--setenv','TMPDIR',str(root/'tmp'),'--chdir',str(root),'--','/usr/bin/python3','-I',str(root/'verify_inside.py')]
p=subprocess.run(command,capture_output=True,text=True,timeout=100);(root/'doc-run.log').write_text(p.stdout+'\nSTDERR\n'+p.stderr);print(p.stdout);print(p.stderr);raise SystemExit(p.returncode)

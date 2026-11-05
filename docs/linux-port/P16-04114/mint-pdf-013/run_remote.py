from pathlib import Path
import subprocess,json,hashlib,os
root=Path(__file__).resolve().parent;assert str(root).startswith('/tmp/pmt-mint-pdf13.')
pkg=root/'.build/linux-preview-04113/poormans-text_0.41.13~linuxpreview1_amd64.deb';assert hashlib.sha256(pkg.read_bytes()).hexdigest()=='640be59eeacddca4fdb0626a84de2ccba8012cf49eb0e98627af404d28cf80ff'
subprocess.run(['dpkg-deb','-x',str(pkg),str(root/'extracted')],check=True,timeout=30)
command=['bwrap','--unshare-all','--die-with-parent','--new-session','--ro-bind','/','/','--tmpfs','/home','--tmpfs','/root','--tmpfs','/run','--tmpfs','/tmp','--proc','/proc','--dev','/dev','--bind',str(root),str(root),'--ro-bind',str(root/'girepo'),'/usr/lib/x86_64-linux-gnu/girepository-1.0','--ro-bind',str(root/'fixtures'),str(root/'fixtures'),'--clearenv','--setenv','PATH','/usr/bin:/bin','--setenv','HOME',str(root/'home'),'--setenv','TMPDIR',str(root/'tmp'),'--chdir',str(root),'--','/usr/bin/python3','-I',str(root/'verify_inside.py')]
p=subprocess.run(command,capture_output=True,text=True,timeout=180);(root/'pdf-run.log').write_text(p.stdout+'\nSTDERR\n'+p.stderr);print(p.stdout);print(p.stderr);raise SystemExit(p.returncode)

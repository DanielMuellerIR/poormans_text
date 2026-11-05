"""Eigener neuer Arbeitsordner mit runtime/, gui_probe.py und private_session.py."""
import pathlib,os,sys,subprocess,hashlib,json
root=pathlib.Path(sys.argv[1]).resolve();manifest=json.loads((root/'runtime-manifest.json').read_text());assert all(hashlib.sha256((root/'runtime'/p).read_bytes()).hexdigest()==h for p,h in manifest['files'].items())
(root/'home').mkdir(mode=0o700,exist_ok=True);(root/'session').mkdir(mode=0o700)
env=dict(os.environ,HOME=str(root/'home'),XDG_CONFIG_HOME=str(root/'home/config'),XDG_CACHE_HOME=str(root/'home/cache'),XDG_DATA_HOME=str(root/'home/data'),XDG_RUNTIME_DIR=str(root/'session'),TMPDIR='/tmp',PATH='/usr/bin:/bin',LANG='C.UTF-8',PMT_CLI=str(root/'runtime/ui/poormans-text'),PMT_PROCESS_GUARD=str(root/'runtime/ui/poormans-text-process-guard'))
for k in ['LD_LIBRARY_PATH','DISPLAY','WAYLAND_DISPLAY','DBUS_SESSION_BUS_ADDRESS','AT_SPI_BUS_ADDRESS','XAUTHORITY']:env.pop(k,None)
command=['/usr/bin/bwrap','--unshare-all','--die-with-parent','--new-session','--ro-bind','/','/','--tmpfs','/home','--tmpfs','/root','--tmpfs','/run','--tmpfs','/tmp','--proc','/proc','--dev','/dev','--bind',str(root),str(root),'--chdir',str(root),'/usr/bin/python3','-I',str(root/'private_session.py')]
raise SystemExit(subprocess.run(command,env=env,timeout=100).returncode)

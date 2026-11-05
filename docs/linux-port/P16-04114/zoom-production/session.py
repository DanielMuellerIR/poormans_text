import os,pathlib,subprocess,select,signal,json,time
r=pathlib.Path('/work');(r/'home').mkdir(mode=0o700);(r/'session').mkdir(mode=0o700)
rd,wr=os.pipe();log=(r/'xvfb.log').open('wb');x=subprocess.Popen(['/usr/bin/Xvfb','-displayfd',str(wr),'-screen','0','1500x1100x24','-nolisten','tcp'],pass_fds=(wr,),stdout=log,stderr=log);os.close(wr);xf=os.pidfd_open(x.pid)
try:
 assert select.select([rd],[],[],8)[0];display=os.read(rd,64).decode().strip();os.close(rd);assert display.isdigit();(r/'display.txt').write_text(':'+display)
 env=dict(os.environ,DISPLAY=':'+display,HOME='/work/home',XDG_CONFIG_HOME='/work/home/config',XDG_CACHE_HOME='/work/home/cache',XDG_DATA_HOME='/work/home/data',XDG_RUNTIME_DIR='/work/session',TMPDIR='/tmp',GDK_BACKEND='x11',GSK_RENDERER='gl',LIBGL_ALWAYS_SOFTWARE='1',GALLIUM_DRIVER='llvmpipe',LANG='C.UTF-8',LANGUAGE='en');env.pop('LD_LIBRARY_PATH',None)
 for key in list(env):
  if key.startswith('PMT_'):env.pop(key)
 output=(r/'gui.log').open('wb');p=subprocess.Popen(['/usr/bin/dbus-run-session','--','/runtime/ui/poormans-text-app','/work/Quelle ü.png'],env=env,stdout=output,stderr=output);pf=os.pidfd_open(p.pid)
 try:
  code=p.wait(timeout=360);(r/'exit.json').write_text(json.dumps({'exit':code,'rendererRequested':'gl','softwareDriverRequested':'llvmpipe','noPMTOverrides':True}));assert code==0
 except subprocess.TimeoutExpired:signal.pidfd_send_signal(pf,signal.SIGTERM);p.wait(timeout=5);(r/'exit.json').write_text(json.dumps({'timeout':True,'exit':p.returncode}))
 finally:
  if p.poll() is None:signal.pidfd_send_signal(pf,signal.SIGKILL);p.wait()
  os.close(pf);output.close()
finally:
 signal.pidfd_send_signal(xf,signal.SIGTERM);x.wait(timeout=5);os.close(xf);log.close()

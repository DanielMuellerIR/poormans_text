"""Nur innerhalb des privaten bwrap-Namensraums ausführen."""
import os,subprocess,select,pathlib,sys,json,signal
root=pathlib.Path(__file__).resolve().parent;assert os.environ['HOME']==str(root/'home');assert 'LD_LIBRARY_PATH' not in os.environ
readfd,writefd=os.pipe();xlog=(root/'xvfb.log').open('wb')
x=subprocess.Popen(['/usr/bin/Xvfb','-displayfd',str(writefd),'-screen','0','1280x1000x24','-nolisten','tcp','-noreset'],pass_fds=(writefd,),stdout=xlog,stderr=xlog);os.close(writefd)
fd=os.pidfd_open(x.pid)
try:
 assert select.select([readfd],[],[],8)[0], 'Xvfb displayfd timeout'
 display=os.read(readfd,64).decode().strip();assert display.isdigit();os.close(readfd)
 env=dict(os.environ,DISPLAY=':'+display,GDK_BACKEND='x11',GSK_RENDERER='gl',LIBGL_ALWAYS_SOFTWARE='1',GTK_A11Y='atspi',LANG='C.UTF-8',LANGUAGE='en')
 command=['/usr/bin/dbus-run-session','--','/usr/bin/python3','-I',str(root/'gui_probe.py'),'--app',str(root/'runtime/ui/poormans-text-app'),'--inner','--screenshot',str(root/'gui.png')]
 p=subprocess.run(command,env=env,capture_output=True,text=True,timeout=80)
 (root/'gui-session.log').write_text(p.stdout+'\nSTDERR\n'+p.stderr);print(p.stdout);print(p.stderr,file=sys.stderr);sys.exit(p.returncode)
finally:
 signal.pidfd_send_signal(fd,signal.SIGTERM)
 try:x.wait(timeout=5)
 except subprocess.TimeoutExpired:signal.pidfd_send_signal(fd,signal.SIGKILL);x.wait()
 os.close(fd);xlog.close()

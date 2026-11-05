import os,pathlib,subprocess,signal,select,time,json,hashlib
from PIL import Image,ImageDraw,ImageGrab
r=pathlib.Path('/work');(r/'home').mkdir(mode=0o700);(r/'session').mkdir(mode=0o700);(r/'fixtures').mkdir();im=Image.new('RGB',(1024,768),'white');draw=ImageDraw.Draw(im)
for y in range(0,768,64):
 for x in range(0,1024,64):draw.rectangle((x,y,x+63,y+63),fill=(230,235,250) if (x//64+y//64)%2 else (255,255,255));draw.text((x+4,y+10),f'{x},{y}',fill='black')
draw.rectangle((0,0,1023,767),outline='red',width=5);im.save(r/'fixtures/source.png');sourcehash=hashlib.sha256((r/'fixtures/source.png').read_bytes()).hexdigest()
(r/'cli').write_text('#!/bin/sh\nLD_LIBRARY_PATH=/runtime/lib exec /runtime/bin/poormans-text "$@"\n');(r/'cli').chmod(0o700)
readfd,writefd=os.pipe();xlog=(r/'xvfb.log').open('wb');x=subprocess.Popen(['/usr/bin/Xvfb','-displayfd',str(writefd),'-screen','0',('3000x2200x24' if os.environ.get('GDK_SCALE')=='2' else '1500x1100x24'),'-nolisten','tcp'],pass_fds=(writefd,),stdout=xlog,stderr=xlog);os.close(writefd);xf=os.pidfd_open(x.pid)
try:
 assert select.select([readfd],[],[],8)[0];display=os.read(readfd,64).decode().strip();os.close(readfd);assert display.isdigit();os.environ['DISPLAY']=':'+display
 env=dict(os.environ,HOME='/work/home',XDG_CONFIG_HOME='/work/home/config',XDG_CACHE_HOME='/work/home/cache',XDG_DATA_HOME='/work/home/data',XDG_RUNTIME_DIR='/work/session',TMPDIR='/tmp',GDK_BACKEND='x11',GSK_RENDERER='cairo',LANG='C.UTF-8',LANGUAGE='en',GTK_A11Y='none',PMT_CLI='/work/cli',PMT_PROCESS_GUARD='/runtime/bin/poormans-text-process-guard',PMT_UI_TEST_RASTER='/work/fixtures/source.png',PMT_UI_TEST_RASTER_ZOOM='1');env.pop('LD_LIBRARY_PATH',None)
 mode=os.environ.get('PMT_ZOOM_MODE','zoom')
 if mode!='zoom':
  env.pop('PMT_UI_TEST_RASTER',None);env.pop('PMT_UI_TEST_RASTER_ZOOM',None);env['PMT_UI_TEST_BOUND_SOURCE']='/work/fixtures/source.png'
  env['PMT_UI_TEST_BOUND_RELEASE' if mode=='release' else 'PMT_UI_TEST_BOUND_ERROR']='1'
  if mode=='verify-error':env['PMT_UI_TEST_BOUND_VERIFY_ERROR']='1'
 log=(r/'gui.log').open('wb');app=subprocess.Popen(['/usr/bin/dbus-run-session','--','/app'],env=env,stdout=log,stderr=log);af=os.pidfd_open(app.pid);seen=set();deadline=time.monotonic()+50
 try:
  while app.poll() is None and time.monotonic()<deadline:
   text=(r/'gui.log').read_text(errors='replace')
   for n in [1,3,5,7,9,11,13,15]:
    if f'PMT_UI_TEST_ZOOM_STAGE {n} ' in text and n not in seen:ImageGrab.grab().save(r/f'stage-{n}.png');seen.add(n)
   time.sleep(.02)
  if app.poll() is None:signal.pidfd_send_signal(af,signal.SIGTERM);app.wait(timeout=5);raise RuntimeError('private GUI timeout')
  assert app.returncode==0,(r/'gui.log').read_text(errors='replace')
  text=(r/'gui.log').read_text()
  assert ('PMT_UI_TEST_ZOOM_RELEASE window-canvas-texture-dropped' if mode=='zoom' else 'PMT_UI_TEST_BOUND_RELEASE_COMPLETE app-open-source-cleared-fds=0' if mode=='release' else 'PMT_UI_TEST_BOUND_ERROR_RELEASE app-open-source-cleared-fds=0') in text
  if mode=='verify-error':assert 'PMT_UI_TEST_BOUND_ERROR_CANVAS_RELEASE window-canvas-dropped-no-texture' in text
  if mode=='release':assert 'PMT_UI_TEST_BOUND_WIDGET_RELEASE window-and-texture-dropped' in text
  assert len(seen)==(8 if mode=='zoom' else 0),seen;assert hashlib.sha256((r/'fixtures/source.png').read_bytes()).hexdigest()==sourcehash
  (r/'result.json').write_text(json.dumps({'exit':app.returncode,'stages':sorted(seen),'sourceSHA256':sourcehash,'sourceUnchanged':True,'GTKUsesSwiftLD':False},indent=2));print('ZOOMPASS')
 finally:
  if app.poll() is None:signal.pidfd_send_signal(af,signal.SIGKILL);app.wait()
  os.close(af);log.close()
finally:
 signal.pidfd_send_signal(xf,signal.SIGTERM);x.wait(timeout=5);os.close(xf);xlog.close()

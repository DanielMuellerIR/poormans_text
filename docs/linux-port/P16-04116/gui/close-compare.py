import ctypes, subprocess
x=ctypes.CDLL('libX11.so.6'); x.XOpenDisplay.restype=ctypes.c_void_p; x.XInternAtom.restype=ctypes.c_ulong
x.XOpenDisplay.argtypes=[ctypes.c_char_p]; x.XInternAtom.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int]; x.XSendEvent.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_long,ctypes.c_void_p]; x.XFlush.argtypes=[ctypes.c_void_p]
class Data(ctypes.Union): _fields_=[('l',ctypes.c_long*5),('pad',ctypes.c_byte*40)]
class Event(ctypes.Structure): _fields_=[('type',ctypes.c_int),('serial',ctypes.c_ulong),('send_event',ctypes.c_int),('display',ctypes.c_void_p),('window',ctypes.c_ulong),('message_type',ctypes.c_ulong),('format',ctypes.c_int),('data',Data)]
d=x.XOpenDisplay(None); w=int(subprocess.check_output(['xdotool','search','--onlyvisible','--name','Verified source comparison']).splitlines()[0]); e=Event(); e.type=33;e.display=d;e.window=w;e.message_type=x.XInternAtom(d,b'WM_PROTOCOLS',0);e.format=32;e.data.l[0]=x.XInternAtom(d,b'WM_DELETE_WINDOW',0);e.data.l[1]=0;x.XSendEvent(d,w,0,0,ctypes.byref(e));x.XFlush(d)

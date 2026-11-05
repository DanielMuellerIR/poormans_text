import os,sys,stat,subprocess,json,datetime
from pathlib import Path
root=Path(sys.argv[1]);assert root.parent==Path('/private/tmp') and root.name.startswith('pmt-ocr-mac-')
rows={}
for line in subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,command='],text=True).splitlines():
 fields=line.strip().split(None,2)
 if len(fields)==3:rows[int(fields[0])]=(int(fields[1]),fields[2])
ancestors=set();pid=os.getpid()
while pid and pid not in ancestors:
 ancestors.add(pid);pid=rows.get(pid,(0,''))[0]
others=[pid for pid,(_,cmd) in rows.items() if pid not in ancestors and str(root) in cmd]
assert not others,others
parent=os.open(str(root.parent),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
held=os.open(root.name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
identity=os.fstat(held);assert identity.st_uid==os.getuid()
files=directories=0
def same(a,b):return a.st_dev==b.st_dev and a.st_ino==b.st_ino and stat.S_IFMT(a.st_mode)==stat.S_IFMT(b.st_mode)
def clear(fd):
 global files,directories
 for name in os.listdir(fd):
  initial=os.stat(name,dir_fd=fd,follow_symlinks=False)
  if stat.S_ISDIR(initial.st_mode):
   child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
   try:
    assert same(initial,os.fstat(child));clear(child);assert same(os.fstat(child),os.stat(name,dir_fd=fd,follow_symlinks=False));os.rmdir(name,dir_fd=fd);directories+=1
   finally:os.close(child)
  else:
   assert same(initial,os.stat(name,dir_fd=fd,follow_symlinks=False));os.unlink(name,dir_fd=fd);files+=1
clear(held);assert same(identity,os.stat(root.name,dir_fd=parent,follow_symlinks=False));os.rmdir(root.name,dir_fd=parent);os.close(held);os.close(parent)
print(json.dumps({'remoteRootRemoved':not root.exists(),'noOwnProcessesBeforeCleanup':not others,'deletedFiles':files,'deletedDirectories':directories+1,'heldDirectoryFDsAndNoFollow':True,'UTC':datetime.datetime.now(datetime.timezone.utc).isoformat()}))

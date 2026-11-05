import hashlib,json,os,stat,sys
from pathlib import Path
root=Path('/tmp/pmt-linux-04117-j2z2PkHe')
proof=Path('/tmp/pmt-linux-04117-proof-191369f9e40d42749ffd3049a7e1a49a.tar.gz')
expected=(33,28993932)
flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
rows={}
for item in Path('/proc').iterdir():
    if not item.name.isdigit():continue
    try:
        raw=(item/'stat').read_text();tail=raw[raw.rfind(')')+2:].split()
        rows[int(item.name)]=(int(tail[1]),(item/'cmdline').read_bytes())
    except (OSError,ValueError):pass
ancestors=set();pid=os.getpid()
while pid and pid not in ancestors:
    ancestors.add(pid);pid=rows.get(pid,(0,b''))[0]
others=[pid for pid,(_,command) in rows.items() if pid not in ancestors and os.fsencode(root) in command]
assert not others,others
parent=os.open('/tmp',flags);held=os.open(root.name,flags,dir_fd=parent)
initial=os.fstat(held);assert (initial.st_dev,initial.st_ino)==expected and initial.st_uid==os.getuid()==1000
files=directories=links=0
def same(a,b):return (a.st_dev,a.st_ino,stat.S_IFMT(a.st_mode))==(b.st_dev,b.st_ino,stat.S_IFMT(b.st_mode))
def clear(fd):
    global files,directories,links
    assert os.fstat(fd).st_uid==os.getuid()
    os.fchmod(fd,0o700)
    listing=os.open('.',flags,dir_fd=fd)
    try:names=os.listdir(listing)
    finally:os.close(listing)
    for name in names:
        before=os.stat(name,dir_fd=fd,follow_symlinks=False)
        if stat.S_ISDIR(before.st_mode):
            child=os.open(name,flags,dir_fd=fd)
            try:
                assert same(before,os.fstat(child));clear(child)
                assert same(os.fstat(child),os.stat(name,dir_fd=fd,follow_symlinks=False))
                os.rmdir(name,dir_fd=fd);directories+=1
            finally:os.close(child)
        else:
            assert same(before,os.stat(name,dir_fd=fd,follow_symlinks=False))
            os.unlink(name,dir_fd=fd)
            files+=1;links+=int(stat.S_ISLNK(before.st_mode))
clear(held)
assert same(initial,os.stat(root.name,dir_fd=parent,follow_symlinks=False))
os.rmdir(root.name,dir_fd=parent);os.close(held)
descriptor=os.open(proof.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC,dir_fd=parent)
with os.fdopen(descriptor,'rb') as stream:
    metadata=os.fstat(stream.fileno());assert stat.S_ISREG(metadata.st_mode) and metadata.st_uid==1000 and metadata.st_nlink==1
    assert hashlib.file_digest(stream,'sha256').hexdigest()=='3b62bd61607a97af3ec8d2378ff9dc8a13a8e5132d65dee50327ab720a228587'
    assert same(metadata,os.stat(proof.name,dir_fd=parent,follow_symlinks=False))
    os.unlink(proof.name,dir_fd=parent)
os.close(parent)
print(json.dumps({'remoteRootRemoved':not root.exists(),'remoteProofRemoved':not proof.exists(),'noOwnProcessesBeforeCleanup':not others,'deletedFiles':files,'deletedDirectories':directories+1,'symlinksUnlinkedWithoutFollowing':links,'heldDirectoryFDsAndNoFollow':True}))

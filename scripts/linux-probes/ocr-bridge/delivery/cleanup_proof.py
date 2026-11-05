import hashlib,json,os,pathlib,stat,subprocess,sys
proof=pathlib.Path(sys.argv[1]);expected=sys.argv[2];work=sys.argv[3]
assert proof.parent==pathlib.Path('/private/tmp') and proof.name.startswith('pmt-ocr-mac-proof-')
parent=os.open('/private/tmp',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
held=os.open(proof.name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=parent)
def stamp(m):return m.st_dev,m.st_ino,m.st_mode,m.st_nlink,m.st_size,m.st_mtime_ns,m.st_ctime_ns
try:
 before=os.fstat(held);assert stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and before.st_nlink==1 and stat.S_IMODE(before.st_mode)==0o600
 digest=hashlib.sha256()
 while block:=os.read(held,1024*1024):digest.update(block)
 assert digest.hexdigest()==expected
 assert stamp(before)==stamp(os.fstat(held))==stamp(os.stat(proof.name,dir_fd=parent,follow_symlinks=False))
 os.unlink(proof.name,dir_fd=parent)
finally:os.close(held);os.close(parent)
rows={}
for line in subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,command='],text=True).splitlines():
 fields=line.strip().split(None,2)
 if len(fields)==3:rows[int(fields[0])]=(int(fields[1]),fields[2])
ancestors=set();pid=os.getpid()
while pid and pid not in ancestors:
 ancestors.add(pid);pid=rows.get(pid,(0,''))[0]
others=[pid for pid,(_,cmd) in rows.items() if pid not in ancestors and (work in cmd or str(proof) in cmd)]
assert not others,others
print(json.dumps({'remoteProofRemoved':not proof.exists(),'remoteRootRemoved':not pathlib.Path(work).exists(),'proofSHA256VerifiedBeforeUnlink':expected,'heldDirectoryFDsAndNoFollow':True,'noOwnProcessesAfterCleanup':True,'bootAfterCleanup':subprocess.check_output(['/usr/sbin/sysctl','-n','kern.boottime'],text=True).strip()}))

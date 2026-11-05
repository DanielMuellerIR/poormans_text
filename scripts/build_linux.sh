#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null || { echo "Python 3 is required for the local Linux build scripts." >&2; exit 69; }
if (( $# > 1 )); then echo "Usage: ./build.sh [debug|release]" >&2; exit 64; fi
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 - "$script_directory/.." "${1:-${CONFIGURATION:-release}}" <<'PY'
import fcntl,os,pathlib,shutil,stat,subprocess,sys,tempfile,uuid
root=pathlib.Path(sys.argv[1]).resolve();configuration=sys.argv[2]
if len(sys.argv)!=3 or configuration not in ('debug','release'):raise SystemExit('Usage: ./build.sh [debug|release]')
flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
def directory(path):
 fd=os.open('/',flags)
 try:
  for part in path.parts[1:]:
   nxt=os.open(part,flags,dir_fd=fd);os.close(fd);fd=nxt
  return fd
 except BaseException:os.close(fd);raise
def same(path,fd):
 try:
  observed=directory(path)
  try:return (os.fstat(fd).st_dev,os.fstat(fd).st_ino)==(os.fstat(observed).st_dev,os.fstat(observed).st_ino)
  finally:os.close(observed)
 except OSError:return False
rootfd=directory(root)
sys.dont_write_bytecode=True
sys.path.insert(0,f'/proc/self/fd/{rootfd}/scripts')
from linux_build_support import publish_launcher
try:
 try:os.mkdir('.build',0o755,dir_fd=rootfd)
 except FileExistsError:pass
 buildfd=os.open('.build',flags,dir_fd=rootfd)
 try:
  lockfd=os.open('linux-build.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=buildfd)
  fcntl.flock(lockfd,fcntl.LOCK_EX|fcntl.LOCK_NB)
  try:os.mkdir('linux',0o755,dir_fd=buildfd)
  except FileExistsError:pass
  scratchfd=os.open('linux',flags,dir_fd=buildfd)
  stage='linux-runtime-new-'+uuid.uuid4().hex
  image=os.environ.get('PMT_LINUX_BUILD_IMAGE')
  if image:
   subprocess.run(['docker','image','inspect',image],check=True,stdout=subprocess.DEVNULL)
  elif not shutil.which('swift'):raise SystemExit('Swift is missing. Install Swift 6.2+ or explicitly set PMT_LINUX_BUILD_IMAGE to an existing local image; no image is pulled automatically.')
  # Sources und Linux-Lock liegen nur für diesen Lauf außerhalb des Repositories.
  with tempfile.TemporaryDirectory(prefix='poormans-text-linux-',dir='/tmp') as temporary:
   source=pathlib.Path(temporary);bound=pathlib.Path('/proc/self/fd')/str(rootfd)
   for name in ['Sources','Tests']:
    if (bound/name).exists():shutil.copytree(bound/name,source/name,symlinks=True)
   shutil.copy2(bound/'Package.swift',source/'Package.swift')
   shutil.copy2(bound/'Package.linux.resolved',source/'Package.resolved')
   shutil.copy2(bound/'scripts/package_linux_runtime.sh',source/'package_linux_runtime.sh')
   if not (same(root,rootfd) and same(root/'.build',buildfd) and same(root/'.build/linux',scratchfd)):raise SystemExit('Project root changed before build; refusing publication.')
   if image:
    # Docker bindet den Inode; vor jedem Schreibzugriff wird dessen Identität geprüft.
    buildpath=str(root/'.build')
    if ',' in buildpath or ',' in str(source):raise SystemExit('Docker bind paths containing commas are unsupported.')
    held=os.fstat(buildfd);cached=os.fstat(scratchfd)
    command=['docker','run','--rm','--pull','never','--user',f'{os.getuid()}:{os.getgid()}',
             '-e','HOME=/tmp','--mount',f'type=bind,source={source},target=/source','--mount',f'type=bind,source={buildpath},target=/out','--mount',f'type=bind,source={buildpath}/linux,target=/out/linux','-w','/source',image]
    inner=['bash','-eu','-c','''python3 -c 'import os,sys; s=os.stat("/out"); assert (s.st_dev,s.st_ino)==(int(sys.argv[1]),int(sys.argv[2])), "build parent changed before bind"' "$3" "$4"
python3 -c 'import os,sys; s=os.stat("/out/linux"); assert (s.st_dev,s.st_ino)==(int(sys.argv[1]),int(sys.argv[2])), "build cache changed before bind"' "$5" "$6"
swift build --package-path /source --scratch-path /out/linux/docker --configuration "$1" --product poormans-text
swift build --package-path /source --scratch-path /out/linux/docker --configuration "$1" --product poormans-text-process-guard
bin=$(swift build --package-path /source --scratch-path /out/linux/docker --configuration "$1" --show-bin-path)
bash /source/package_linux_runtime.sh "$bin/poormans-text" "$bin/poormans-text-process-guard" "/out/$2"
''','build-linux',configuration,stage,str(held.st_dev),str(held.st_ino),str(cached.st_dev),str(cached.st_ino)]
    subprocess.run(command+inner,check=True)
   else:
    os.dup2(scratchfd,200,inheritable=True)
    os.dup2(buildfd,201,inheritable=True)
    scratch='/proc/self/fd/200/native'
    common=['swift','build','--package-path',str(source),'--scratch-path',scratch,'--configuration',configuration]
    for product in ['poormans-text','poormans-text-process-guard']:subprocess.run(common+['--product',product],pass_fds=(200,),check=True)
    binary=subprocess.check_output(common+['--show-bin-path'],pass_fds=(200,),text=True).strip()
    environment=dict(os.environ, PMT_RUNTIME_PARENT_FD='201', PMT_RUNTIME_INPUT_FD='200')
    subprocess.run(['bash',str(source/'package_linux_runtime.sh'),binary+'/poormans-text',binary+'/poormans-text-process-guard',stage],env=environment,pass_fds=(200,201),check=True)
  if not (same(root,rootfd) and same(root/'.build',buildfd) and same(root/'.build/linux',scratchfd)):raise SystemExit('Project root changed; staged runtime retained at held original .build, no success reported.')
  backup=None
  try:
   previous=os.stat('linux-runtime',dir_fd=buildfd,follow_symlinks=False)
  except FileNotFoundError:pass
  else:
   if not stat.S_ISDIR(previous.st_mode):raise SystemExit('Existing linux-runtime is not a regular directory.')
   backup='linux-runtime-old-'+uuid.uuid4().hex
   os.rename('linux-runtime',backup,src_dir_fd=buildfd,dst_dir_fd=buildfd)
  try:os.rename(stage,'linux-runtime',src_dir_fd=buildfd,dst_dir_fd=buildfd)
  except BaseException:
   if backup:os.rename(backup,'linux-runtime',src_dir_fd=buildfd,dst_dir_fd=buildfd)
   raise
  text='''#!/bin/sh
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit
runtime="$base/.build/linux-runtime"
LD_LIBRARY_PATH="$runtime/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$runtime/bin/poormans-text" "$@"
'''
  publish_launcher(rootfd,'poormans-text',text.encode(),'scripts/run_linux_cli.sh')
  if backup:print(f'Previous runtime retained for explicit cleanup: {root}/.build/{backup}')
  if not (same(root,rootfd) and same(root/'.build',buildfd) and same(root/'.build/linux',scratchfd)):raise SystemExit('Project root changed after publication; complete runtime retained at original root, no success reported.')
  print(f'Linux CLI ready: {root}/poormans-text')
  print('Host tools required for external conversions: pandoc and /usr/bin/bwrap (not bundled).')
  missing=[]
  if not shutil.which('pandoc'):missing.append('pandoc')
  if not os.access('/usr/bin/bwrap',os.X_OK):missing.append('/usr/bin/bwrap')
  if missing:print('Missing host conversion tools: '+', '.join(missing),file=sys.stderr)
 finally:
  if not os.environ.get('PMT_LINUX_BUILD_IMAGE'):
   for descriptor in [200,201]:
    try:os.close(descriptor)
    except OSError:pass
  if 'scratchfd' in locals():os.close(scratchfd)
  if 'lockfd' in locals():os.close(lockfd)
  os.close(buildfd)
finally:os.close(rootfd)
PY

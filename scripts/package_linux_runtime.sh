#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null || { echo "Python 3 is required for the local Linux build scripts." >&2; exit 69; }
exec python3 - "$@" <<'PY'
import os,pathlib,re,shutil,stat,subprocess,sys
if len(sys.argv)!=4:raise SystemExit('Usage: package_linux_runtime.sh CLI GUARD NEW_RUNTIME_DIRECTORY')
cli,guard,destination=map(pathlib.Path,sys.argv[1:])
flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
def directory(path):
 fd=os.open('/',flags)
 try:
  for part in path.absolute().parts[1:]:
   nxt=os.open(part,flags,dir_fd=fd);os.close(fd);fd=nxt
  return fd
 except BaseException:os.close(fd);raise
inherited=os.environ.get('PMT_RUNTIME_PARENT_FD')
parent=os.dup(int(inherited)) if inherited else directory(destination.parent)
if not stat.S_ISDIR(os.fstat(parent).st_mode):raise SystemExit('Runtime parent FD is not a directory')
name=destination.name
if name in ('','.','..'):raise SystemExit('Invalid runtime directory')
os.mkdir(name,0o700,dir_fd=parent)
fd=os.open(name,flags,dir_fd=parent);root=pathlib.Path('/proc/self/fd')/str(fd)
try:
 (root/'bin').mkdir();(root/'lib').mkdir()
 libraries={};system=set()
 for binary,is_guard in [(cli,False),(guard,True)]:
  if not stat.S_ISREG(binary.lstat().st_mode):raise SystemExit(f'Not a regular executable: {binary}')
  result=subprocess.run(['ldd',str(binary)],text=True,capture_output=True,pass_fds=(int(inherited),) if inherited else ())
  if result.returncode and 'not a dynamic executable' not in result.stderr+result.stdout and 'statically linked' not in result.stdout:raise SystemExit(result.stderr or result.stdout)
  for line in result.stdout.splitlines():
   if 'not found' in line:raise SystemExit('Unresolved runtime dependency: '+line.strip())
   match=re.match(r'\s*(\S+)\s+=>\s+(/\S+)',line)
   if not match:continue
   soname,path=match.groups()
   swift=soname.startswith(('libswift','libFoundation','lib_Foundation','libdispatch','libBlocksRuntime'))
   if is_guard and swift:raise SystemExit('Process guard must use -static-stdlib: '+soname)
   bundle=swift or soname.startswith(('libxml2.so','libicu','libpng16.so','libz.so','liblzma.so'))
   if bundle:libraries[soname]=path
   else:system.add(soname)
  (root/('guard-ldd.txt' if is_guard else 'cli-ldd.txt')).write_text(result.stdout+result.stderr)
 for soname,path in sorted(libraries.items()):shutil.copy2(path,root/'lib'/soname)
 shutil.copy2(cli,root/'bin/poormans-text');shutil.copy2(guard,root/'bin/poormans-text-process-guard')
 notices=root/'licenses';notices.mkdir()
 license_sources=[pathlib.Path('/usr/share/swift/LICENSE.txt')]
 for package in ['libxml2','libicu74','libpng16-16t64','zlib1g','liblzma5']:
  license_sources.append(pathlib.Path('/usr/share/doc')/package/'copyright')
 for package in ['libxml2','icu','libpng','zlib','zlib-ng','zlib-ng-compat','xz']:
  folder=pathlib.Path('/usr/share/licenses')/package
  if folder.is_dir():
   for notice in folder.iterdir():
    if notice.is_file():license_sources.append(notice)
 for ancestor in cli.resolve().parents:
  checkouts=ancestor/'checkouts'
  if checkouts.is_dir():
   for package in ['swift-crypto','swift-asn1']:
    for name in ['LICENSE.txt','NOTICE.txt']:
     license_sources.append(checkouts/package/name)
   break
 for notice in license_sources:
  if notice.is_file():shutil.copy2(notice,notices/(notice.parent.name+'-'+notice.name))
 (root/'system-libraries.txt').write_text('\n'.join(sorted(system))+'\nELF interpreter/glibc loader: supplied by the host; not bundled.\n')
 (root/'host-tools.txt').write_text('Pandoc and /usr/bin/bwrap are host dependencies; not bundled.\nNo runtime downloads or global installation.\n')
 os.chmod(root/'bin/poormans-text',0o755);os.chmod(root/'bin/poormans-text-process-guard',0o755)
except BaseException:
 # Der Eltern-FD bleibt gebunden, auch wenn dessen früherer Pfad ausgetauscht wurde.
 if os.stat(name,dir_fd=parent,follow_symlinks=False).st_ino==os.fstat(fd).st_ino:shutil.rmtree(name,dir_fd=parent)
 raise
finally:os.close(fd);os.close(parent)
PY

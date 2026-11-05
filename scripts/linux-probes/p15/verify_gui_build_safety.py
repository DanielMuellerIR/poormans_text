#!/usr/bin/env python3
"""Prüft den echten GUI-Buildwriter mit isolierten Fake-Compilern und Pfadtausch."""
from pathlib import Path
import tempfile,shutil,subprocess,os,json,hashlib
scripts_root=Path(__file__).resolve().parents[2]
source=(scripts_root/'build_linux_gui.py').read_bytes()
root=Path(tempfile.mkdtemp(prefix='pmt-gui-build-review-'))
results=[]
def write(path,text,mode=None):
 path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text)
 if mode is not None:path.chmod(mode)
def files(path):
 return {str(p.relative_to(path)):hashlib.sha256(p.read_bytes()).hexdigest() for p in path.rglob('*') if p.is_file() and not p.is_symlink()}
for case in ['unknown-ui','known-ui','known-ui-schema','modified-schema','unknown-schema-file','swap-target','swap-cache','swap-build-parent','ui-rename-race']:
 repo=root/case;script=repo/'scripts/build_linux_gui.py';script.parent.mkdir(parents=True);script.write_bytes(source)
 for helper in ['linux_build_support.py','run_linux_cli.sh','run_linux_gui.sh']:
  shutil.copy2(scripts_root/helper,script.parent/helper)
 write(repo/'Sources/PoorMansTextCore/ProductInfo.swift','static let version = "9.9.9"\n')
 write(repo/'Cargo.toml','[workspace]\nmembers=[]\n')
 write(repo/'Cargo.lock','version=4\n[[package]]\nname="fixture-dep"\nversion="1.0.0"\nsource="registry+https://github.com/rust-lang/crates.io-index"\nchecksum="'+'0'*64+'"\n')
 (repo/'linux').mkdir()
 write(repo/'linux/app/schemas/org.poormanstext.Linux.gschema.xml','<schemalist><schema id="org.poormanstext.Linux" path="/org/poormanstext/Linux/"><key name="own-fixture" type="b"><default>false</default></key></schema></schemalist>\n')
 cache=repo/'.build/linux-ui-cargo';target=repo/'.build/linux-ui-native-target';target.mkdir(parents=True)
 dep=cache/'registry/src/fixture-index/fixture-dep-1.0.0'
 write(dep/'Cargo.toml','[package]\nname="fixture-dep"\nversion="1.0.0"\nlicense="MIT"\n')
 write(dep/'LICENSE','Own synthetic license probe, no real third-party software.\n')
 runtime=repo/'.build/linux-runtime';(runtime/'lib').mkdir(parents=True)
 write(runtime/'bin/poormans-text','#!/bin/sh\nprintf "Poor Man\047s Text 9.9.9\\n"\n',0o755)
 write(runtime/'bin/poormans-text-process-guard','#!/bin/sh\nexit 0\n',0o755)
 ui=runtime/'ui';ui.mkdir()
 if case=='unknown-ui':
  write(ui/'build-info.json','{"producer":"someone-else"}\n');write(ui/'private-note.txt','retain this own fixture\n')
 else:
  write(ui/'poormans-text-app','old own fixture GUI\n',0o755)
  for name in ['poormans-text','poormans-text-process-guard']:write(ui/name,'old own helper\n',0o755)
  write(ui/'THIRD-PARTY-NOTICES.txt','old own fixture notices\n')
  write(ui/'build-info.json',json.dumps({'producer':'pmt-linux-gui-build-v1','product':'Poor Mans Text GTK','version':'9.9.8','binarySHA256':hashlib.sha256((ui/'poormans-text-app').read_bytes()).hexdigest()}))
  if case in ['known-ui-schema','modified-schema','unknown-schema-file']:
   write(ui/'schemas/gschemas.compiled','own synthetic compiled-schema fixture\n')
   info=json.loads((ui/'build-info.json').read_text());info['preferencesSchemaSHA256']=hashlib.sha256((ui/'schemas/gschemas.compiled').read_bytes()).hexdigest();(ui/'build-info.json').write_text(json.dumps(info))
   if case=='modified-schema':write(ui/'schemas/gschemas.compiled','modified schema must survive\n')
   if case=='unknown-schema-file':write(ui/'schemas/foreign-note','must survive\n')
 old=files(ui)
 sysroot=repo/'fake-sysroot';write(sysroot/'share/doc/rust/COPYRIGHT-library.html','<p>Own toolchain fixture</p>\n');write(sysroot/'share/doc/rust/licenses/MIT.txt','Own license fixture\n')
 fake=repo/'fake-bin'
 write(fake/'rustc','#!/bin/sh\nprintf "%s\\n" "$TEST_SYSROOT"\n',0o755)
 write(fake/'cargo', '''#!/usr/bin/python3
from pathlib import Path
import os,json
repo=Path(os.environ['TEST_REPO']);case=os.environ['TEST_CASE'];build=repo/'.build'
if case=='swap-target':
 p=build/'linux-ui-native-target';p.rename(build/'target-held');p.mkdir();(p/'victim').write_text('untouched target')
elif case=='swap-cache':
 p=build/'linux-ui-cargo';p.rename(build/'cargo-held');p.mkdir();(p/'victim').write_text('untouched cache')
elif case=='swap-build-parent':
 build.rename(repo/'.build-held');build.mkdir();(build/'victim').write_text('untouched parent')
target=Path(os.environ['CARGO_TARGET_DIR']);cargo=Path(os.environ['CARGO_HOME'])
(target/'release').mkdir(exist_ok=True)
p=target/'release/poormans-text-gtk';p.write_text('#!/bin/sh\\nexit 0\\n');p.chmod(0o755)
(cargo/'cargo-write-marker').write_text('must remain at held inode')
''',0o755)
 env={k:v for k,v in os.environ.items() if k not in ['PMT_LINUX_GUI_BUILD_IMAGE','PMT_CARGO_HOME','RUSTUP_HOME','CARGO_HOME','CARGO_TARGET_DIR','LD_LIBRARY_PATH']};env.update(PATH=str(fake)+':'+env.get('PATH','/usr/bin:/bin'),HOME=str(repo/'fake-home'),TEST_REPO=str(repo),TEST_CASE=case,TEST_SYSROOT=str(sysroot))
 command=['/usr/bin/python3',str(script),'release']
 if case=='ui-rename-race':
  wrapper=repo/'trace-ui-race.py'
  write(wrapper,'''import sys,runpy
from pathlib import Path
script=Path(sys.argv[1]).resolve();lines=script.read_text().splitlines();done=False
repo=script.parent.parent
sys.argv=[str(script),'release']
def trace(frame,event,arg):
 global done
 if not done and event=='line' and frame.f_code.co_filename==str(script) and "os.rename('ui', backup," in lines[frame.f_lineno-1]:
  done=True;ui=repo/'.build/linux-runtime/ui';ui.rename(ui.with_name('ui-validated-held'));ui.mkdir();(ui/'unknown-note').write_text('must not be deleted')
 return trace
sys.settrace(trace)
runpy.run_path(str(script),run_name='__main__')
''')
  command=['/usr/bin/python3',str(wrapper),str(script)]
 p=subprocess.run(command,env=env,capture_output=True,text=True,timeout=20)
 if case in ['known-ui','known-ui-schema']:
  check={'exitZero':p.returncode==0,'publishedOwnGUI':(ui/'poormans-text-app').read_text()=='#!/bin/sh\nexit 0\n','oldBackupPreserved':any(files(path)==old for path in runtime.glob('ui-old-*')),'noticesPublished':(ui/'THIRD-PARTY-NOTICES.txt').is_file(),'launcherCreated':(repo/'poormans-text-app').is_file()}
 elif case=='ui-rename-race':
  backups=list(runtime.glob('ui-old-*'))
  check={'failed':p.returncode!=0,'validatedUIUnchanged':files(runtime/'ui-validated-held')==old,'unknownBackupRetained':len(backups)==1 and (backups[0]/'unknown-note').read_text()=='must not be deleted','noLauncher':not(repo/'poormans-text-app').exists()}
 elif case in ['unknown-ui','modified-schema','unknown-schema-file']:
  check={'failed':p.returncode!=0,'oldUIUnchanged':files(ui)==old,'noLauncher':not (repo/'poormans-text-app').exists()}
 else:
  foreign=(repo/'.build/linux-ui-native-target' if case=='swap-target' else repo/'.build/linux-ui-cargo' if case=='swap-cache' else repo/'.build')
  heldbuild=repo/'.build-held' if case=='swap-build-parent' else repo/'.build'
  heldtarget=heldbuild/('target-held' if case=='swap-target' else 'linux-ui-native-target')
  heldcache=heldbuild/('cargo-held' if case=='swap-cache' else 'linux-ui-cargo')
  heldui=heldbuild/'linux-runtime/ui'
  check={'failed':p.returncode!=0,'foreignContainsOnlyVictim':set(x.name for x in foreign.iterdir())=={'victim'},'writeWentToHeldTarget':(heldtarget/'release/poormans-text-gtk').is_file(),'writeWentToHeldCargo':(heldcache/'cargo-write-marker').is_file(),'oldUIUnchanged':files(heldui)==old,'noLauncher':not(repo/'poormans-text-app').exists()}
 result={'case':case,'exit':p.returncode,'checks':check,'error':p.stderr.strip().splitlines()[-1:]}
 results.append(result);print(json.dumps(result),flush=True)
summary={'buildScriptSHA256':hashlib.sha256(source).hexdigest(),'scope':'Actual copied build script, synthetic repo and explicit fake cargo/rustc; filesystem/ownership regression only, no real compiler/GUI/Swift/package acceptance.','cases':results,'allPassed':all(all(x['checks'].values()) for x in results)}
(root/'evidence.json').write_text(json.dumps(summary,indent=2)+'\n');print(root)
if not summary['allPassed']:raise SystemExit(1)

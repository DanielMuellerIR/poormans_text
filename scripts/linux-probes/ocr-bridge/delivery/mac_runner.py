import base64,datetime,hashlib,json,os,pathlib,shutil,signal,subprocess,sys,tarfile,threading,time,traceback,uuid
P=pathlib.Path
root=P(sys.argv[1]).resolve();assert root.parent==P('/private/tmp') and root.name.startswith('pmt-ocr-mac-')
assert root.stat().st_uid==os.getuid()
manifest=json.loads((root/'manifest.json').read_text());budget=manifest['budgetSeconds'];assert budget==3600
started=time.monotonic();deadline=started+budget-180;active=None;wake=None;emit_lock=threading.Lock()
evidence=root/'evidence';evidence.mkdir(mode=0o700)
result={'schemaVersion':2,'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'budgetSeconds':budget,'archiveSHA256':manifest['archiveSHA256'],'payloadFileCount':len(manifest['files']),'candidate':False,'stages':[],'noAppActivation':True,'noInstallation':True,'priorMatrixAndFocusedOCRNotRepeated':True,'finished':False}
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def emit(kind,**fields):
 with emit_lock:print(json.dumps({'event':kind,**fields}),flush=True)
def persist():
 (evidence/'result.json').write_text(json.dumps(result,indent=2)+'\n')
 emit('status',result=result)
def interrupted(number,frame):raise SystemExit('Owned runner interrupted by signal '+str(number))
for number in [signal.SIGTERM,signal.SIGINT,signal.SIGHUP]:signal.signal(number,interrupted)
watchdog=threading.Timer(budget-170,lambda:os.kill(os.getpid(),signal.SIGTERM));watchdog.daemon=True;watchdog.start()
def kill_owned_group(process):
 try:os.killpg(process.pid,signal.SIGTERM)
 except ProcessLookupError:pass
 try:process.wait(timeout=3)
 except subprocess.TimeoutExpired:
  try:os.killpg(process.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  process.wait(timeout=3)
 try:os.killpg(process.pid,signal.SIGKILL)
 except ProcessLookupError:pass

def run(name,args,limit=120):
 global active
 remaining=deadline-time.monotonic()
 if remaining<=0:raise RuntimeError('Overall budget exhausted before '+name)
 before=time.monotonic();log=evidence/(name+'.log');reader=None;reader_errors=[]
 emit('stage-start',stage=name,arguments=args)
 with log.open('wb') as stream:
  active=subprocess.Popen(args,cwd=root/'source',env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
  def tee():
   try:
    while True:
     block=active.stdout.read1(16384)
     if not block:break
     stream.write(block);stream.flush()
     emit('log',stage=name,data=base64.b64encode(block).decode('ascii'))
   except BaseException as error:reader_errors.append(repr(error))
  reader=threading.Thread(target=tee,daemon=True);reader.start()
  try:
   try:code=active.wait(timeout=min(limit,remaining))
   except subprocess.TimeoutExpired:
    kill_owned_group(active);code=124
  finally:
   kill_owned_group(active)
   reader.join(timeout=5)
   active.stdout.close();active=None
   if reader.is_alive():raise RuntimeError('Log reader did not finish for '+name)
   if reader_errors:raise RuntimeError('Log transfer failed: '+repr(reader_errors))
 record={'stage':name,'exit':code,'seconds':round(time.monotonic()-before,3),'log':log.name};result['stages'].append(record)
 emit('stage-end',**record);persist()
 if code!=0:raise RuntimeError(name+' exited '+str(code))
 return log

def boot():return subprocess.check_output(['/usr/sbin/sysctl','-n','kern.boottime'],text=True).strip()
try:
 result['bootBefore']=boot();emit('boot-before',boot=result['bootBefore']);persist()
 assert sha(root/'source.tgz')==manifest['archiveSHA256'],'Source archive digest mismatch'
 source=root/'source';source.mkdir(mode=0o700)
 with tarfile.open(root/'source.tgz') as archive:
  members=archive.getmembers();assert len(members)==len(manifest['files'])
  assert all(m.isfile() and not P(m.name).is_absolute() and '..' not in P(m.name).parts and m.name in manifest['files'] for m in members)
  archive.extractall(source)
 for name,digest in manifest['files'].items():assert sha(source/name)==digest,name
 for name in ['home','tmp','cache','config','security','scratch','modules','clang-modules']:(root/name).mkdir(mode=0o700)
 env=dict(os.environ,HOME=str(root/'home'),CFFIXED_USER_HOME=str(root/'home'),TMPDIR=str(root/'tmp')+'/',CFPREFERENCES_AVOID_DAEMON='1',CLANG_MODULE_CACHE_PATH=str(root/'clang-modules'),SWIFTPM_MODULECACHE_OVERRIDE=str(root/'modules'),PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
 seeds=P(os.path.expanduser('~/git/poormans_text/.build'))
 for name,dest in [('artifacts','scratch/artifacts'),('repositories','scratch/repositories'),('repositories','cache/repositories')]:shutil.copytree(seeds/name,root/dest,symlinks=True)
 state=json.loads((seeds/'workspace-state.json').read_text())
 for artifact in state.get('object',{}).get('artifacts',[]):artifact['path']=artifact['path'].replace(str(seeds),str(root/'scratch'),1)
 (root/'scratch/workspace-state.json').write_text(json.dumps(state))
 wake=subprocess.Popen(['/usr/bin/caffeinate','-i','-w',str(os.getpid())],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 run('environment',['/bin/sh','-c','uname -m; sw_vers; xcrun swift --version'],30)
 swift=['/usr/bin/arch','-arm64','/usr/bin/xcrun','swift']
 common=['--package-path',str(source),'--scratch-path',str(root/'scratch'),'--cache-path',str(root/'cache'),'--config-path',str(root/'config'),'--security-path',str(root/'security'),'--manifest-cache','local','--skip-update','--force-resolved-versions','--jobs','4','-Xswiftc','-module-cache-path','-Xswiftc',str(root/'modules'),'-Xcc','-fmodules-cache-path='+str(root/'clang-modules')]
 run('build-tests',swift+['build']+common+['--configuration','debug','--arch','arm64','--build-tests'],1500)
 bin_path=P(run('bin-path',swift+['build']+common+['--configuration','debug','--arch','arm64','--show-bin-path'],30).read_text().splitlines()[-1].strip())
 assert bin_path.is_relative_to(root/'scratch')
 binaries=sorted(p for p in bin_path.glob('*.xctest/Contents/MacOS/*') if p.is_file())
 if {b.name for b in binaries}!={'PoorMansTextCoreTests','PoorMansTextPortableTests'}:raise RuntimeError('Unexpected XCTest products: '+repr([str(p) for p in binaries]))
 result['testExecutables']={}
 for binary in binaries:
  run('test-arch-'+binary.name,['/usr/bin/lipo','-verify_arch','arm64',str(binary)],10)
  result['testExecutables'][str(binary.relative_to(root))]=sha(binary)
 run('full-tests',swift+['test']+common+['--configuration','debug','--arch','arm64','--skip-build'],3500)
 result['sourceFilesUnchanged']=all(sha(source/name)==digest for name,digest in manifest['files'].items())
 assert result['sourceFilesUnchanged'],'Source files changed'
 result['bootAfter']=boot();assert result['bootAfter']==result['bootBefore'],'Host reboot detected'
 result['finished']=True
except BaseException as error:
 result['error']=repr(error);result['traceback']=traceback.format_exc();emit('failure',error=result['error'],traceback=result['traceback'])
finally:
 watchdog.cancel()
 if active is not None:kill_owned_group(active)
 if wake is not None:wake.terminate();wake.wait(timeout=3)
 if (root/'source').is_dir():result['sourceFilesUnchanged']=all((root/'source'/name).is_file() and sha(root/'source'/name)==digest for name,digest in manifest['files'].items())
 result['seconds']=round(time.monotonic()-started,3);result['endedUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();result['bootAfter']=boot();persist()
 (evidence/'manifest.json').write_bytes((root/'manifest.json').read_bytes())
 output=P('/private/tmp')/('pmt-ocr-mac-proof-'+uuid.uuid4().hex+'.tgz')
 with tarfile.open(output,'w:gz') as archive:archive.add(evidence,arcname='evidence')
 os.chmod(output,0o600)
 proof={'proof':str(output),'proofSHA256':sha(output),'remoteRoot':str(root),'finished':result['finished'],'cleanupDeferredUntilProofRetrieved':True}
 (root/'proof-info.json').write_text(json.dumps(proof)+'\n')
 emit('proof',**proof)

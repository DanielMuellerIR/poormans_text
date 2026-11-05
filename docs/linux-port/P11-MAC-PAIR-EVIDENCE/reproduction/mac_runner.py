import os,sys,pathlib,json,hashlib,tarfile,shutil,subprocess,time,signal,datetime,traceback
P=pathlib.Path;root=P(sys.argv[1]).resolve();assert root.parent==P('/private/tmp') and root.name.startswith('pmt-mac-p11-')
start=time.time();hard=datetime.datetime(2026,11,5,7,30,tzinfo=datetime.timezone.utc).timestamp();deadline=min(start+11*60,hard);records=[]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
result={'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'stages':records,'isolation':{'guiStarted':False,'installation':False,'arch':'arm64'}}
(root/'runner.pid').write_text(str(os.getpid()));active=None;wake=None

def persist():
 (root/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')

def run(name,args,timeout=1200,cwd=None):
 global active
 log=root/(name+'.log');before=time.time();remaining=deadline-time.time();assert remaining>0,'overall deadline'
 with log.open('wb') as stream:
  active=subprocess.Popen(args,cwd=cwd or root/'source',env=env,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
  try:code=active.wait(timeout=min(timeout,remaining))
  except subprocess.TimeoutExpired:
   os.killpg(active.pid,signal.SIGTERM)
   try:active.wait(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(active.pid,signal.SIGKILL);active.wait()
   code=124
  finally:
   group=active.pid
   try:os.killpg(group,0)
   except ProcessLookupError:pass
   else:
    os.killpg(group,signal.SIGKILL)
   active=None
 rec={'stage':name,'exit':code,'seconds':round(time.time()-before,3),'log':log.name};records.append(rec);persist()
 if code:raise RuntimeError(name+' exited '+str(code))
 return log
try:
 manifest=json.loads((root/'manifest.json').read_text());assert sha(root/'source.tgz')=='9b9544b7d98ea256a4675276193c904d28c3e6be497cb6dfe6162f600d015b99'
 source=root/'source';source.mkdir()
 with tarfile.open(root/'source.tgz') as archive:
  for member in archive.getmembers():
   p=P(member.name);assert not p.is_absolute() and '..' not in p.parts and member.isfile(),member.name
  archive.extractall(source)
 assert len(manifest['files'])==337
 for name,digest in manifest['files'].items():assert sha(source/name)==digest,name
 result['source']={k:v for k,v in manifest.items() if k!='files'};result['archiveSHA256']=sha(root/'source.tgz');result['verifiedFiles']=len(manifest['files']);persist()
 for name in ['home','tmp','cache','config','security','scratch','modules','clang-modules','evidence']:(root/name).mkdir(mode=0o700)
 env=dict(os.environ,HOME=str(root/'home'),CFFIXED_USER_HOME=str(root/'home'),TMPDIR=str(root/'tmp')+'/',CFPREFERENCES_AVOID_DAEMON='1',CLANG_MODULE_CACHE_PATH=str(root/'clang-modules'),SWIFTPM_MODULECACHE_OVERRIDE=str(root/'modules'),PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
 old=P(os.path.expanduser('~/git/poormans_text/.build'))
 # Nur fertige Binärartefakte und bare Repositories lesen; keine Objektdateien oder alten Checkoutpfade übernehmen.
 shutil.copytree(old/'artifacts',root/'scratch/artifacts',symlinks=True)
 shutil.copytree(old/'repositories',root/'scratch/repositories',symlinks=True)
 shutil.copytree(old/'repositories',root/'cache/repositories',symlinks=True)
 state=json.loads((old/'workspace-state.json').read_text())
 for artifact in state.get('object',{}).get('artifacts',[]):artifact['path']=artifact['path'].replace(str(old),str(root/'scratch'),1)
 # Fehlende Checkoutordner werden von SwiftPM aus den privaten bare Repositories erzeugt.
 (root/'scratch/workspace-state.json').write_text(json.dumps(state))
 wake=subprocess.Popen(['/usr/bin/caffeinate','-i','-w',str(os.getpid())],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 swift=['/usr/bin/arch','-arm64','/usr/bin/xcrun','swift']
 common=['--package-path',str(source),'--scratch-path',str(root/'scratch'),'--cache-path',str(root/'cache'),'--config-path',str(root/'config'),'--security-path',str(root/'security'),'--manifest-cache','local','--skip-update','--force-resolved-versions','--jobs','4','-Xswiftc','-module-cache-path','-Xswiftc',str(root/'modules'),'-Xcc','-fmodules-cache-path='+str(root/'clang-modules')]
 run('environment',['/bin/sh','-c','uname -m; sw_vers; xcrun swift --version'],60)
 for product in ['poormans-text']:run('build-'+product,swift+['build']+common+['--configuration','debug','--arch','arm64','--product',product],1500)
 bin_path=P(subprocess.check_output(swift+['build']+common+['--configuration','debug','--arch','arm64','--show-bin-path'],env=env,text=True).strip())
 binary=bin_path/'poormans-text';assert binary.is_file()
 result['cliSHA256']=sha(binary);result['onlyCLIBuilt']=True;persist()
 run('arch-check',['/usr/bin/lipo','-verify_arch','arm64',str(binary)],30)
 result['version']=run('cli-version',[str(binary),'--version'],10).read_text().strip();assert '0.41.14' in result['version']
 result['cases']=[]
 expected={'structured.png':'e37ca92cf5b8ad22e228eed1c1065177bbbdc6b865b9e027965660353f934369','01030000000132-render.png':'dfe0a1d9bc07db406080ab22b92632f512f94aef6b32aa2a199d2efe4b101db3'}
 for name,digest in expected.items():
  source_image=root/'input'/name;assert sha(source_image)==digest
  output=root/'evidence'/source_image.stem
  args=[str(binary),'--json','--report','--source-map','--ocr-method','structured','--output',str(output),str(source_image)]
  before=time.monotonic();timedout=False
  active=subprocess.Popen(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
  try:stdout,stderr=active.communicate(timeout=min(45,deadline-time.time()))
  except subprocess.TimeoutExpired:
   timedout=True;os.killpg(active.pid,signal.SIGTERM)
   try:stdout,stderr=active.communicate(timeout=3)
   except subprocess.TimeoutExpired:os.killpg(active.pid,signal.SIGKILL);stdout,stderr=active.communicate(timeout=3)
  code=active.returncode;group=active.pid
  try:os.killpg(group,0)
  except ProcessLookupError:pass
  else:os.killpg(group,signal.SIGKILL)
  active=None
  (root/'evidence'/(source_image.stem+'-stdout.json')).write_bytes(stdout)
  (root/'evidence'/(source_image.stem+'-stderr.log')).write_bytes(stderr)
  record={'input':name,'sourceSHA256':digest,'sourceUnchanged':sha(source_image)==digest,'exit':code,'outer45SecondCutoff':timedout,'seconds':round(time.monotonic()-before,3),'outputFiles':{}}
  if output.exists():
   for p in output.rglob('*'):
    if p.is_file():record['outputFiles'][str(p.relative_to(output))]={'sha256':sha(p),'byteCount':p.stat().st_size}
  try:
   response=json.loads(stdout);record['diagnostics']=response.get('diagnostics',[])
   record['structuredApplied']=any(x.get('code')=='image.structuredOCRApplied' or x.get('code')=='ocr.structuredApplied' for x in record['diagnostics'])
  except Exception:pass
  result['cases'].append(record);persist()
  assert record['sourceUnchanged']
  if timedout:result['cutoffBoundary']='One owned CLI process group reached45s; no quality/parity claim';break
 result['cliUnchanged']=sha(binary)==result['cliSHA256']
 result['sourceFilesUnchanged']=all(sha(source/name)==digest for name,digest in manifest['files'].items());assert result['sourceFilesUnchanged'] and result['cliUnchanged']
 result['finished']=True

except BaseException as error:
 result['error']=str(error);result['traceback']=traceback.format_exc();result['finished']=False
finally:
 if active is not None:
  try:os.killpg(active.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  active.wait()
 if wake is not None:
  wake.terminate();wake.wait()
 result['seconds']=round(time.time()-start,3);result['endedUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();persist()

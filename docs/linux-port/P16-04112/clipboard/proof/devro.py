import subprocess,json,os,pathlib,time
b=['/usr/bin/bwrap','--bind','/','/','--proc','/proc','--dev','/dev','--dir','/dev/pmt-input','--remount-ro','/dev','--','/usr/bin/python3','-c',"""import os,json
checks={}
for p in ['/dev/shm/pmt-canary','/dev/pmt-input/out','/dev/../dev/shm/alias']:
 try:os.mkdir(p);checks[p]='UNEXPECTED_WRITE'
 except OSError as e:checks[p]=e.errno
os.chdir('/dev')
try:os.mkdir('shm/relative');checks['relative']='UNEXPECTED_WRITE'
except OSError as e:checks['relative']=e.errno
with open('/dev/null','wb') as f:f.write(b'x')
with open('/dev/urandom','rb') as f:assert len(f.read(16))==16
print(json.dumps({'writes':checks,'devices':True}))"""]
p=subprocess.run(b,capture_output=True,timeout=20);assert p.returncode==0,p.stderr;v=json.loads(p.stdout);assert set(v['writes'].values())=={30},v
root=pathlib.Path('/probe');helper='/helper';cli='/candidate/cli';guard='/candidate/poormans-text-process-guard';fixture=root/'fixtures/source.csv';assert fixture.read_bytes()==b'Name,Value\nKERNEL_RO_CANARY,42\n';runid=str(time.time_ns());rows=[]
for target,success in [(str(root/'proof'/('normal-'+runid)),True),('/dev/shm/out-'+runid,False),('/dev/pmt-input/out-'+runid,False),('/dev/../dev/pmt-input/out-'+runid,False),('/dev/shm/../shm/out-'+runid,False),('dev/shm/out-'+runid,False)]:
 # Relative path is relative to /, strictly within the private /dev.
 p=subprocess.run([helper,cli,guard,str(fixture),'--output',target],cwd='/',capture_output=True,timeout=30)
 if success:assert p.returncode==0,(target,p.stderr);response=json.loads(p.stdout);assert 'KERNEL_RO_CANARY' in pathlib.Path(response['markdownFile']).read_text().replace('\\','')
 else:assert p.returncode!=0 and 'CORE_EXIT=Some(74)' in p.stderr.decode(),(target,p.stdout,p.stderr)
 rows.append({'target':target,'success':p.returncode==0,'error':p.stderr.decode()})
profile_dir=root/'proof'/('profiles-'+runid);source=root/'fixtures/profile.xlsx';target='/dev/shm/profile-'+runid
p=subprocess.run([helper,cli,guard,str(source),'--save-profile','Private dev target','--profiles-directory',str(profile_dir),'--sheets','1','--profile-local','--output',target],env={**os.environ,'PMT_BOUND_OPERATION':'1'},capture_output=True,timeout=30);assert p.returncode==0,p.stderr
p=subprocess.run([helper,cli,guard,str(source),'--profile','Private dev target','--profiles-directory',str(profile_dir),'--profile-local'],capture_output=True,timeout=30);assert p.returncode!=0 and 'CORE_EXIT=Some(74)' in p.stderr.decode(),(p.stdout,p.stderr);rows.append({'profileTarget':target,'success':False,'error':p.stderr.decode()})
for target in ['/dev/shm/no-clipboard-'+runid,'/dev/../dev/pmt-input/no-clipboard-'+runid]:
 p=subprocess.run([helper,cli,guard,str(fixture),'--output',target],cwd='/',env={**os.environ,'PMT_BOUND_NO_INPUT':'1'},capture_output=True,timeout=30)
 expected=73 if '/pmt-input/' in target else 74
 assert p.returncode!=0 and ('CORE_EXIT=Some('+str(expected)+')') in p.stderr.decode(),(p.stdout,p.stderr)
 rows.append({'noClipboardTarget':target,'coreExit':expected,'success':False,'error':p.stderr.decode()})
assert fixture.read_bytes()==b'Name,Value\nKERNEL_RO_CANARY,42\n'
(root/'proof/devro.json').write_text(json.dumps({'kernel':v,'cli':rows,'sourceUnchanged':True},indent=2)+'\n');print('kernel devices + normal CSV + five private-dev targets + local profile PASS')

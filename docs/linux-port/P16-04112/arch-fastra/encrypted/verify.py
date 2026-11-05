import hashlib,json,os,pathlib,shutil,subprocess,tempfile
p=pathlib.Path
assert p('/.dockerenv').is_file() and shutil.which('swift') is None
src=p('/proof/encrypted.pdf'); original=hashlib.sha256(src.read_bytes()).hexdigest()
policy=subprocess.check_output(['pacman-conf','SigLevel','LocalFileSigLevel']).decode()
assert 'PackageRequired' in policy and 'PackageTrustedOnly' in policy
pkg=p('/packages/poormans-text-0.41.12-1-x86_64.pkg.tar.zst')
assert hashlib.sha256(pkg.read_bytes()).hexdigest()==pkg.with_name(pkg.name+'.sha256').read_text().split()[0]
subprocess.run(['pacman','-U','--noconfirm',str(pkg)],check=True,capture_output=True)
try:
 assert hashlib.sha256(p('/usr/lib/poormans-text/bin/poormans-text').read_bytes()).hexdigest()=='2f49d54ecd6d9bae4962fcdb7f968ea4eef9c3844701d278a9a507e3e84db07c'
 with tempfile.TemporaryDirectory(prefix='pmt-encrypted-final-') as tmp:
  root=p(tmp);root.chmod(0o700);os.chown(root,1000,1000)
  env={'PATH':'/usr/bin:/bin','LANG':'C.UTF-8'}
  for key in ['HOME','TMPDIR','XDG_RUNTIME_DIR','XDG_CONFIG_HOME','XDG_CACHE_HOME','XDG_DATA_HOME']:
   v=root/key;v.mkdir(mode=0o700);os.chown(v,1000,1000);env[key]=str(v)
  output=root/'result'
  command=['setpriv','--reuid=1000','--regid=1000','--clear-groups','env','-i',*[k+'='+v for k,v in env.items()],'/usr/bin/poormans-text','--json','--report','--output',str(output),'--',str(src)]
  result=subprocess.run(command,capture_output=True,text=True,timeout=40)
  data=json.loads(result.stdout)
  assert result.returncode==65 and data['ok'] is False,(result.returncode,data,result.stderr)
  assert not output.exists()
  assert hashlib.sha256(src.read_bytes()).hexdigest()==original
  evidence={'version':'0.41.12','uid':1000,'exit':result.returncode,'response':data,'noPublication':True,'sourceSHA256':original,'sourceUnchanged':True,'noSwiftSDK':True,'networkInterfaces':sorted(f.name for f in p('/sys/class/net').iterdir()),'signaturePolicyUnchanged':subprocess.check_output(['pacman-conf','SigLevel','LocalFileSigLevel']).decode()==policy,'CLIsha256':hashlib.sha256(p('/usr/lib/poormans-text/bin/poormans-text').read_bytes()).hexdigest()}
finally:
 subprocess.run(['pacman','-R','--noconfirm','poormans-text'],check=True,capture_output=True)
evidence['packageRemoved']=not p('/usr/lib/poormans-text').exists()
p('/proof/encrypted-result.json').write_text(json.dumps(evidence,indent=2)+'\n');print(json.dumps(evidence,indent=2))

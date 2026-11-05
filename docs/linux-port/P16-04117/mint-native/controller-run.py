import hashlib,json,os,platform,resource,stat,subprocess,sys,tarfile,time,uuid
from pathlib import Path

root=Path(__file__).absolute().parent
assert root.parent==Path('/tmp') and root.name.startswith('pmt-linux-04117-')
assert root.stat().st_uid==os.getuid()==1000
proof=root/'proof';proof.mkdir()
manifest=json.loads((root/'payload.json').read_text())
sha=lambda p:hashlib.file_digest(Path(p).open('rb'),'sha256').hexdigest()
for name,record in manifest.items():
    assert name==Path(name).name and (root/name).stat().st_size==record['byteCount'] and sha(root/name)==record['sha256'],name
host_before={n:sha(p) for n,p in {'dpkgStatus':'/var/lib/dpkg/status','true':'/usr/bin/true'}.items()}
(proof/'payload.json').write_text(json.dumps(manifest,indent=2)+'\n')

def phase(name,command,*,env=None,expect=0,timeout=180):
    print(json.dumps({'phase':name,'state':'started'}),flush=True)
    start=time.monotonic()
    result=subprocess.run(command,capture_output=True,text=True,timeout=timeout,env=env,cwd=root)
    (proof/(name+'.stdout')).write_text(result.stdout)
    (proof/(name+'.stderr')).write_text(result.stderr)
    record={'phase':name,'exit':result.returncode,'seconds':time.monotonic()-start}
    (proof/(name+'.json')).write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record),flush=True)
    assert result.returncode==expect,(name,result.returncode,result.stderr[-2000:])
    return result

def extract(archive,destination,zstd=False):
    destination.mkdir()
    listing=subprocess.check_output(['tar',*(['--zstd'] if zstd else []),'-tf',str(archive)],text=True)
    for name in listing.splitlines():
        p=Path(name)
        assert not p.is_absolute() and '..' not in p.parts
    phase('extract-'+destination.name,['tar',*(['--zstd'] if zstd else []),'-xf',str(archive),'--no-same-owner','-C',str(destination)])

summary={'scope':'Native Mint private DPKG lifecycle, packaged Swift CLI, and offline optional model component with temporary Noble Tesseract dependencies; no host installation or desktop','host':{'architecture':platform.machine(),'python':platform.python_version(),'glibc':platform.libc_ver(),'filesystem':subprocess.check_output(['findmnt','-no','FSTYPE','-T',str(root)],text=True).strip()},'rootIdentity':{'device':root.stat().st_dev,'inode':root.stat().st_ino},'status':'FAIL'}
try:
    old=root/'poormans-text_0.41.14~linuxpreview1_amd64.deb';new=root/'poormans-text_0.41.17~linuxpreview1_amd64.deb'
    phase('dpkg-lifecycle',[sys.executable,str(root/'scaffold.py'),'--old',str(old),'--new',str(new),'--root',str(root/'lifecycle')])
    import shutil
    shutil.copytree(root/'lifecycle/result',proof/'dpkg-outer')
    for name in ('boundary.json','lifecycle.json'):
        shutil.copy2(root/'lifecycle/root/work'/name,proof/name)
    extract_root=root/'package';extract_root.mkdir()
    phase('package-extract',['dpkg-deb','--extract',str(new),str(extract_root)])
    runtime=extract_root/'usr/lib/poormans-text';cli=extract_root/'usr/bin/poormans-text'
    (root/'private-home').mkdir();(root/'private-tmp').mkdir()
    env=dict(os.environ,HOME=str(root/'private-home'),XDG_CONFIG_HOME=str(root/'private-home/config'),TMPDIR=str(root/'private-tmp'))
    phase('native-version',[str(cli),'--version'],env=env)
    (root/'source.csv').write_text('Name,Value\nÄpfel,12\nBirnen,7\n')
    native=phase('native-csv',[str(cli),'--json','--report','--output',str(root/'csv-output'),'--',str(root/'source.csv')],env=env)
    output=json.loads(native.stdout);assert 'Äpfel' in Path(output['markdownFile']).read_text()
    for item in output['outputFiles']:assert sha(root/'csv-output'/item['path'])==item['sha256']
    phase('native-missing-backend',[str(cli),'--json','--ocr-method','structured','--output',str(root/'missing-output'),'--',str(root/'structured.png')],env=env,expect=69)
    assert not (root/'missing-output').exists()
    extract(root/'runtime-candidate.tar.zst',root/'models-source',zstd=True)
    phase('native-runtime-install',[sys.executable,str(root/'install_linux_ocr_runtime.py'),'--source',str(root/'models-source/candidate'),'--runtime-directory',str(runtime),'--expected-manifest-sha256','cd4673de443d7e2570d6c4c4666cecb4924e2ceaf22703cba2a273a544eface6'],timeout=600)
    extract(root/'pmt-mint-tools-04117.tar.gz',root/'tools')
    toolmanifest=json.loads((root/'tools/manifest.json').read_text())
    for name,item in toolmanifest['files'].items():assert sha(root/'tools'/name)==item['sha256']
    model=runtime/'structured-ocr';work=root/'model-work';work.mkdir()
    cpu=','.join(map(str,sorted(os.sched_getaffinity(0))[:2]))
    command=['taskset','-c',cpu,'bwrap','--unshare-all','--die-with-parent','--new-session','--ro-bind','/usr','/usr','--ro-bind','/bin','/bin','--ro-bind','/lib','/lib','--ro-bind','/lib64','/lib64','--dir','/etc','--ro-bind','/etc/ld.so.cache','/etc/ld.so.cache','--proc','/proc','--dev','/dev','--tmpfs','/tmp','--ro-bind',str(model),'/runtime','--ro-bind',str(root/'tools'),'/tools','--ro-bind',str(root/'structured.png'),'/input.png','--ro-bind',str(root/'structured_ocr.py'),'/worker.py','--bind',str(work),'/work','--chdir','/work','--clearenv','--setenv','PATH','/tools/bin:/usr/bin:/bin','--setenv','LD_LIBRARY_PATH','/tools/lib','--setenv','TESSDATA_PREFIX','/tools/data','--setenv','LANG','C.UTF-8','--','/runtime/bin/python3.12','-I','/worker.py','/runtime','/input.png','["eng"]','/work/document.json']
    result=phase('native-model-worker',command,timeout=180)
    binding=json.loads(result.stdout);document=work/'document.json'
    assert binding['sourceSHA256']==manifest['structured.png']['sha256'] and binding['documentSHA256']==sha(document)
    assert binding['width']==1800 and binding['height']==1600
    shutil.copy2(document,proof/'model-document.json');shutil.copy2(root/'tools/manifest.json',proof/'temporary-tools.json')
    cells=json.loads(document.read_text())['tables'][0]['data']['table_cells']
    summary.update(status='PASS',sourceUnchanged=sha(root/'structured.png')==manifest['structured.png']['sha256'],modelCellTexts=[c['text'] for c in cells],qualityStatus='Separate strict quality gate remains FAIL; successful component inference is not semantic completeness')
except Exception as error:
    import traceback
    summary['error']=str(error);summary['traceback']=traceback.format_exc()
finally:
    summary['hostInputsUnchanged']=host_before=={n:sha(p) for n,p in {'dpkgStatus':'/var/lib/dpkg/status','true':'/usr/bin/true'}.items()}
    (proof/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    archive=Path('/tmp')/('pmt-linux-04117-proof-'+uuid.uuid4().hex+'.tar.gz')
    with tarfile.open(archive,'w:gz') as tar:tar.add(proof,arcname='proof')
    print(json.dumps({'proof':str(archive),'sha256':sha(archive),'status':summary['status'],'rootIdentity':summary['rootIdentity']}),flush=True)
raise SystemExit(0 if summary['status']=='PASS' and summary['hostInputsUnchanged'] else 1)

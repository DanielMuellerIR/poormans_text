import argparse,hashlib,json,pathlib
p=argparse.ArgumentParser();p.add_argument('--work',type=pathlib.Path,required=True);p.add_argument('--response',type=pathlib.Path,required=True);p.add_argument('--evidence',type=pathlib.Path,required=True);a=p.parse_args()
h=lambda b:hashlib.sha256(b).hexdigest()
j=json.loads(a.response.read_text());assert j['ok'] is True and j['version']=='0.41.13'
source=a.work/'source.rtf';before='4bf614958d3ff0f9b579063615057cd54f344c7a700c34525361a8f681259a42';assert h(source.read_bytes())==before
assert j['sourceIdentity']['sha256']==before and j['sourceIdentity']['byteCount']==source.stat().st_size
md=a.work/'result/source.md';text=md.read_text();lines=[v for v in text.splitlines() if v]
expected=['PIDONE%05d Alpha Grüße'%i for i in range(12000)];assert lines==expected
for f in j['outputFiles']:
 data=(a.work/'result'/f['path']).read_bytes();assert len(data)==f['byteCount'] and h(data)==f['sha256']
assert not list(a.work.glob('.process-*'))
r={'exit':0,'ok':True,'sourceSHA256':before,'sourceUnchanged':True,'orderedParagraphsIndependentlyCompared':len(lines),'allUnicodeParagraphsEqual':True,'markdownSHA256':h(md.read_bytes()),'outputManifestChecked':True,'noProcessCaptureResidue':True,'firstLine':lines[0],'lastLine':lines[-1]};a.evidence.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r))

import argparse,hashlib,json,pathlib,tarfile
P=pathlib.Path
p=argparse.ArgumentParser();p.add_argument('repository',type=P);p.add_argument('output',type=P);p.add_argument('--candidate',action='store_true');args=p.parse_args()
repo=args.repository.resolve();out=args.output.resolve();assert not out.exists();out.mkdir(mode=0o700,parents=True)
hash_file=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
files=set()
for directory in ['Sources','Tests','App','scripts']:
 files.update(str(f.relative_to(repo)) for f in (repo/directory).rglob('*') if f.is_file() and not f.is_symlink())
for name in ['Package.swift','Package.resolved','README.md','README.de.md','CHANGELOG.md','LICENSE','build.sh','install.sh','release.sh']:
 assert (repo/name).is_file();files.add(name)
files.update(str(f.relative_to(repo)) for f in (repo/'docs').glob('*.md'))
files.update(str(f.relative_to(repo)) for f in (repo/'.github/workflows').glob('*.yml'))
files.update(str(f.relative_to(repo)) for f in (repo/'docs/linux-port/P11-DOCLING-EVIDENCE/documents').glob('*.json'))
original={name:hash_file(repo/name) for name in sorted(files)}
replacements={}
if args.candidate:
 for name in ['Sources/PoorMansTextCore/DocumentOCR.swift','Tests/PoorMansTextCoreTests/StructuredOCRTests.swift']:
  candidate=P(__file__).resolve().parent.parent/'candidate'/name
  replacements[name]=candidate
with tarfile.open(out/'source.tgz','w:gz') as archive:
 for name in sorted(files):archive.add(replacements.get(name,repo/name),arcname=name,recursive=False)
actual={name:hash_file(replacements.get(name,repo/name)) for name in sorted(files)}
manifest={'schemaVersion':1,'budgetSeconds':3600,'archiveSHA256':hash_file(out/'source.tgz'),'files':actual,'originalFiles':original,'candidate':args.candidate,'noRemoteAuthorizationImplied':True}
assert all(hash_file(repo/name)==digest for name,digest in original.items()),'Source changed during packaging'
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
for name in ['mac_runner.py','cleanup.py']:(out/name).write_bytes((P(__file__).parent/name).read_bytes())
(out/'matrix.swift').write_bytes((P(__file__).parent.parent/'probe/matrix.swift').read_bytes())
print(json.dumps({'sourceFiles':len(actual),'sourceArchiveSHA256':manifest['archiveSHA256'],'output':str(out),'candidate':args.candidate}))

import importlib.util,json,pathlib,resource
spec=importlib.util.spec_from_file_location('safe_doc','/pmt/input/legacy_doc.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
assert resource.getrlimit(resource.RLIMIT_AS)==(3*1024**3,)*2
results={}
for name,limit in [('HTML',module.MAX_HTML_BYTES),('TXT',module.MAX_REFERENCE_BYTES)]:
 path=pathlib.Path('/pmt/output')/(name+'.oversized')
 with path.open('wb') as file:file.truncate(limit+1)
 try:module.bounded_bytes(path,limit,name)
 except ValueError:results[name]='rejected before decoding'
 else:raise AssertionError('oversized export accepted')
 path.unlink()
print(json.dumps({'addressSpaceBytes':resource.getrlimit(resource.RLIMIT_AS)[0],'limits':results}))

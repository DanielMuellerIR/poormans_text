import subprocess,os,pathlib,json
command=['/tests/PoorMansTextPackageTests.xctest','PoorMansTextLinuxTests.LinuxOCRTests/testMissingOCRBackendCannotPublishAnImageResult']
p=subprocess.run(command,env={**os.environ,'LD_LIBRARY_PATH':'/test-libs'},capture_output=True,timeout=30)
text=p.stdout.decode()+p.stderr.decode();pathlib.Path('/probe/results/missing-unit.log').write_text(text)
assert p.returncode==0 and 'Executed 1 test' in text and '0 failures' in text and 'skipped' not in text.lower(),(p.returncode,text)
pathlib.Path('/probe/results/missing-unit.json').write_text(json.dumps({'test':command[1],'exit':p.returncode,'executed':1,'failures':0,'skipped':0,'controlledNonExecutableTesseract':True},indent=2)+'\n');print(text)

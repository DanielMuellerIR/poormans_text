#!/usr/bin/env python3
import json, pathlib, shutil
root=pathlib.Path(__file__).resolve().parent/'goldens'
root.mkdir(exist_ok=True)
def write(name,obj): (root/name).write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
base={'ok':True,'version':'0.41.7','futureField':{'ignored':True}}
write('catalog.json',dict(base,formats=[dict(format='mbox',extensions=['mbox'],container='file',containers=['file','package'],requires=['pandoc'],available=True,unavailableReason=None,futureField=1),dict(format='doc',extensions=['doc'],container='file',requires=['pandoc','textutil'],available=False,unavailableReason='missing required tool: textutil')]))
out=pathlib.Path('/synthetic-fixture/out')
write('single.json',dict(base,markdownFile=str(out/'source.md'),assets=[],warnings=['Verlustprobe']))
write('minimal.json',dict(ok=True,markdownFile=str(out/'source.md')))
write('collection.json',dict(base,markdownFile=str(out/'source.md'),assets=[],warnings=[],documents=[dict(sourceIndex=i,title=name,markdownFile=str(out/f'documents/{name}.md'),assets=[],metadata={}) for i,name in enumerate(['one','two'],1)]))
write('error.json',dict(ok=False,version='0.41.7',error='Probe: Werkzeug fehlt'))
(root/'broken.json').write_text('{"ok":true,')
print('Synthetische Vertragsfälle erzeugt; keine aufgezeichneten Producer-Goldens.')

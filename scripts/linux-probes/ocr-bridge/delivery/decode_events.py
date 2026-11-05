import base64,json,pathlib
root=pathlib.Path(__file__).parent
logs=root/'native-logs';logs.mkdir(exist_ok=True)
frames=(root/'live-events.jsonl').read_bytes().splitlines(keepends=True)
data={};summary={'stages':[],'frames':0}
for line in frames:
 if not line.endswith(b'\n'):break
 event=json.loads(line);summary['frames']+=1;kind=event['event']
 if kind=='log':data.setdefault(event['stage'],bytearray()).extend(base64.b64decode(event['data'],validate=True))
 elif kind=='status':summary['result']=event['result']
 elif kind=='stage-end':summary['stages'].append(event)
 elif kind in ['proof','failure','boot-before']:summary[kind]=event
for name,payload in data.items():(logs/(name+'.log')).write_bytes(payload)
(root/'live-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({'frames':summary['frames'],'stages':[(s['stage'],s['exit']) for s in summary['stages']],'finished':summary.get('result',{}).get('finished'),'failure':summary.get('failure'),'proof':summary.get('proof')},indent=2))
if 'full-tests' in data:print(bytes(data['full-tests']).decode('utf-8',errors='replace').splitlines()[-6:])

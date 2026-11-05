#!/usr/bin/env python3
"""Begrenzter echter Modellabbruch; ausschließlich eigene Nachkommen per pidfd beobachten."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli',required=True,type=Path)
parser.add_argument('--source',required=True,type=Path)
parser.add_argument('--evidence',required=True,type=Path)
parser.add_argument('--after-tesseract',action='store_true',
                    help='Erst nach dem echten TSV-Lauf während der Wortverfeinerung abbrechen')
args=parser.parse_args()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before=sha(args.source)
observed={};sent=None;worker_seen=False;tesseract_seen=False
tsv_pids=set();refinement_workers=set()
sentinel=subprocess.Popen(['/bin/sleep','120'],start_new_session=True)
child=None
try:
    with tempfile.TemporaryDirectory(prefix='pmt-model-cancel-') as temporary:
        root=Path(temporary);destination=root/'output'
        child=subprocess.Popen([str(args.cli),'--json','--ocr-method','structured',
                                '--ocr-language','en','--output',str(destination),'--',str(args.source)],
                               stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        deadline=time.monotonic()+100
        while child.poll() is None and time.monotonic()<deadline and sent is None:
            rows={}
            for item in Path('/proc').iterdir():
                if not item.name.isdigit():continue
                try:
                    raw=(item/'stat').read_text();fields=raw[raw.rfind(')')+2:].split()
                    rows[int(item.name)]=(int(fields[1]),(item/'cmdline').read_bytes().split(b'\0'))
                except (OSError,ValueError):continue
            owned={child.pid};changed=True
            while changed:
                added={pid for pid,(parent,_) in rows.items() if parent in owned}-owned
                changed=bool(added);owned.update(added)
            for pid in owned:
                if pid not in observed:
                    try:observed[pid]=os.pidfd_open(pid)
                    except ProcessLookupError:continue
                argv=rows.get(pid,(0,[]))[1]
                if argv and argv[0].endswith(b'/bin/python3.12'):worker_seen=True
                if argv and argv[0].endswith(b'/bin/python3.12') and b'--refine-words' in argv:
                    refinement_workers.add(pid)
                if argv and argv[0].endswith(b'tesseract') and any(a.endswith(b'.png') for a in argv):
                    tesseract_seen=True
                    if b'tsv' in argv:tsv_pids.add(pid)
            refinement_active=(bool(tsv_pids) and all(select.select([observed[pid]],[],[],0)[0]
                               for pid in tsv_pids) and any(pid in rows for pid in refinement_workers))
            if worker_seen and tesseract_seen and (not args.after_tesseract or refinement_active):
                sent=time.monotonic();child.send_signal(signal.SIGTERM)
            else:time.sleep(.02)
        assert sent is not None,'No real model/Tesseract descendant reached before the limit'
        stdout,stderr=child.communicate(timeout=10)
        stopped=all(select.select([fd],[],[],0)[0] for fd in observed.values())
        report={'cliSHA256':sha(args.cli),'sourceSHA256':before,'exit':child.returncode,
                'postSignalSeconds':time.monotonic()-sent,'modelWorkerObserved':worker_seen,
                'realTesseractDescendantObserved':tesseract_seen,'observedOwnedProcesses':len(observed),
                'afterTesseractRequested':args.after_tesseract,
                'refinementWorkerObserved':bool(refinement_workers),'tsvProcessesExitedBeforeSignal':refinement_active,
                'allObservedOwnedPidfdsExited':stopped,'unrelatedSentinelSurvived':sentinel.poll() is None,
                'outputAbsent':not destination.exists(),'stagingAbsent':not list(root.iterdir()),
                'sourceUnchanged':sha(args.source)==before,'response':json.loads(stdout),'stderr':stderr.decode()}
        args.evidence.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        assert child.returncode==130 and stopped and report['unrelatedSentinelSurvived']
        assert report['outputAbsent'] and report['stagingAbsent'] and report['sourceUnchanged']
        print(json.dumps(report,ensure_ascii=False,indent=2))
finally:
    if child is not None and child.poll() is None:
        child.terminate()
        try:child.wait(timeout=10)
        except subprocess.TimeoutExpired:child.kill();child.wait()
    sentinel.terminate();sentinel.wait()
    for fd in observed.values():os.close(fd)

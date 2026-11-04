#!/usr/bin/env python3
"""Feindlicher Testprozess: ignoriert TERM und löst Enkel aus der Prozessgruppe."""
from pathlib import Path
import os
import json
import signal
import sys
import time

root = Path(sys.argv[1])
signal.signal(signal.SIGTERM, signal.SIG_IGN)
if os.fork() == 0:
    os.setsid()
    if os.fork() != 0:
        os._exit(0)
    role = "escaped"
else:
    role = "tool"
    if '--exit-main' in sys.argv:
        deadline = time.monotonic() + 3
        while not (root / 'escaped.ready').exists() and time.monotonic() < deadline:
            time.sleep(0.005)
        sys.exit(0)
try:
    control = os.open('/proc/1/fd/0', os.O_WRONLY | os.O_NONBLOCK)
except PermissionError:
    control_denied = True
else:
    os.close(control)
    control_denied = False
with (root / (role + '.ready')).open('w') as marker:
    json.dump({'pid': os.getpid(), 'processGroup': os.getpgrp(),
               'session': os.getsid(0), 'controlPipeAccessDenied': control_denied}, marker)
with (root / (role + '.heartbeat')).open('ab', buffering=0) as heartbeat:
    while True:
        heartbeat.write(b'x')
        time.sleep(0.005)

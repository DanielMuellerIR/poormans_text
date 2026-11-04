#!/usr/bin/env python3
import json,resource,subprocess,sys,time
start=time.perf_counter();result=subprocess.run(sys.argv[1:],check=False);stats=resource.getrusage(resource.RUSAGE_CHILDREN)
print(json.dumps({'wallSeconds':time.perf_counter()-start,'childUserSeconds':stats.ru_utime,'childSystemSeconds':stats.ru_stime,'maximumChildRSSKiB':stats.ru_maxrss,'exitStatus':result.returncode},indent=2));sys.exit(result.returncode)

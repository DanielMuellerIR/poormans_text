import socket,json
s=socket.socket();s.settimeout(2)
code=s.connect_ex(('1.1.1.1',443))
print(json.dumps(dict(connect_errno=code,routes=open('/proc/net/route').read().splitlines()[1:])))
assert code==101, 'Probe erwartet ENETUNREACH'

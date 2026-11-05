import argparse, pathlib
p=argparse.ArgumentParser();p.add_argument('work',type=pathlib.Path);a=p.parse_args()
a.work.mkdir(exist_ok=True)
text=''.join('PIDONE%05d Alpha Gr\\u252?\\\'dfe \\par\n'%i for i in range(12000))
(a.work/'source.rtf').write_bytes(('{\\rtf1\\ansi\\ansicpg1252\\uc1\n'+text+'}').encode('ascii'))

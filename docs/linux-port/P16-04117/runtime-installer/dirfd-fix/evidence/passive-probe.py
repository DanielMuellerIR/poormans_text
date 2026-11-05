import os,tempfile,pathlib,json,shutil
base=pathlib.Path('/home/dm/git/poormans_text/.build');root=pathlib.Path(tempfile.mkdtemp(prefix='pmt-installer-dirfd-probe-',dir=base));result={'root':str(root),'tests':[]}
flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
try:
 for mode in ['untouched','initial-list','seek-before-list','reopen']:
  p=root/mode;p.mkdir();fd=os.open(p,flags)
  try:
   item={'mode':mode,'initialFdinfo':pathlib.Path(f'/proc/self/fdinfo/{fd}').read_text()}
   if mode=='initial-list':item['initialList']=os.listdir(fd)
   for name in ['bin','lib','models','include','share','notices']:
    os.mkdir(name,dir_fd=fd)
   f=os.open('runtime-manifest.json',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600,dir_fd=fd);os.close(f)
   item['afterCreateFdinfo']=pathlib.Path(f'/proc/self/fdinfo/{fd}').read_text()
   if mode=='seek-before-list':os.lseek(fd,0,os.SEEK_CUR)
   if mode=='reopen':
    fresh=os.open('.',flags,dir_fd=fd)
    try:item['freshList']=os.listdir(fresh)
    finally:os.close(fresh)
   item['firstList']=os.listdir(fd);item['secondList']=os.listdir(fd)
   os.lseek(fd,0,os.SEEK_SET);item['seekSetList']=os.listdir(fd)
   result['tests'].append(item)
  finally:os.close(fd)
finally:shutil.rmtree(root)
print(json.dumps(result,indent=2))

import os,pathlib,tempfile,shutil,importlib.util,json
spec=importlib.util.spec_from_file_location('installer','/tmp/pmt-runtime-installer-dirfd-fix-20261105/scripts/install_linux_ocr_runtime.py');installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
root=pathlib.Path(tempfile.mkdtemp(prefix='pmt-installer-dirfd-probe-',dir='/home/dm/git/poormans_text/.build'));fd=os.open(root,installer.DIRECTORY_FLAGS)
try:
 before=pathlib.Path(f'/proc/self/fdinfo/{fd}').read_text()
 for name in ['bin','lib','models','include','share','notices']:os.mkdir(name,dir_fd=fd)
 f=os.open('runtime-manifest.json',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600,dir_fd=fd);os.close(f)
 fixed=installer.directory_names(fd)
 after=pathlib.Path(f'/proc/self/fdinfo/{fd}').read_text()
 stale=os.listdir(fd)
 assert len(fixed)==7
 assert before==after
 print(json.dumps({'fixedListing':fixed,'originalListingAfterFix':stale,'originalFdinfoUnchanged':before==after,'originalFdinfo':before},indent=2))
finally:
 os.close(fd);shutil.rmtree(root)

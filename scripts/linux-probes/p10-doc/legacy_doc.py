"""Legacy-DOC ausschließlich im lokalen PMT-PID-/Netzwerk-Namespace exportieren."""
import argparse
import hashlib
import errno
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import resource
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024 * 1024,) * 2)
resource.setrlimit(resource.RLIMIT_NOFILE, (512, 512))

PROFILE = '''<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry">
 <item oor:path="/org.openoffice.Office.Common/Security/Scripting">
  <prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>
  <prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop>
  <prop oor:name="SecureURL" oor:op="fuse"><value/></prop>
 </item>
 <item oor:path="/org.openoffice.Office.Writer/Content/Update">
  <prop oor:name="Link" oor:op="fuse"><value>2</value></prop>
 </item>
</oor:items>'''


class Images(HTMLParser):
    def __init__(self):
        super().__init__()
        self.references = []

    def handle_starttag(self, tag, attributes):
        if tag.lower() == 'img':
            self.references.append(dict(attributes).get('src', ''))


def fingerprint(path):
    digest = hashlib.sha256()
    size = 0
    with path.open('rb') as source:
        while chunk := source.read(256 * 1024):
            size += len(chunk)
            if size > 1024 * 1024 * 1024:
                raise ValueError('the DOC source exceeds 1 GiB')
            digest.update(chunk)
    return digest.hexdigest(), size


def export(source, root, mode, conversion_filter):
    profile = root / ('profile-' + mode)
    user = profile / 'user'
    user.mkdir(parents=True, mode=0o700)
    (user / 'registrymodifications.xcu').write_text(PROFILE, encoding='utf-8')
    output = root / mode
    output.mkdir(mode=0o700)
    environment = dict(os.environ, SAL_USE_VCLPLUGIN='svp', HOME=str(root / 'home'), TMPDIR=str(root / 'tmp'))
    command = ['/usr/bin/libreoffice', '-env:UserInstallation=' + profile.as_uri(),
               '--headless', '--nologo', '--nodefault', '--norestore', '--nolockcheck',
               '--convert-to', conversion_filter, '--outdir', str(output), str(source)]
    log = root / (mode + '.log')
    with log.open('wb') as captured:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=captured,
                                stderr=captured, env=environment, timeout=25)
    settings = ET.parse(user / 'registrymodifications.xcu').getroot()
    namespace = '{http://openoffice.org/2001/registry}'
    required = {
        ('/org.openoffice.Office.Common/Security/Scripting', 'MacroSecurityLevel'): '3',
        ('/org.openoffice.Office.Common/Security/Scripting', 'DisableMacrosExecution'): 'true',
        ('/org.openoffice.Office.Writer/Content/Update', 'Link'): '2',
    }
    observed = {}
    for item in settings.findall('item'):
        for property_node in item.findall('prop'):
            value = property_node.find('value')
            observed[(item.get(namespace + 'path'), property_node.get(namespace + 'name'))] = value.text if value is not None else None
    if any(observed.get(key) != value for key, value in required.items()):
        raise ValueError('LibreOffice did not retain the required macro/link security profile')
    suffix = '.html' if mode == 'html' else '.txt'
    files = list(output.glob('*' + suffix))
    if result.returncode or len(files) != 1 or not files[0].is_file():
        with log.open('rb') as captured:
            captured.seek(max(0, log.stat().st_size - 4096))
            detail = captured.read(4096).decode('utf-8', errors='replace')
        raise ValueError('LibreOffice ' + mode + ' export failed: ' + detail)
    size = 0
    resources = []
    for path in output.rglob('*'):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise ValueError('LibreOffice produced an unsafe resource type')
        if stat.S_ISREG(info.st_mode):
            size += info.st_size
            resources.append(path)
    if size > 512 * 1024 * 1024 or len(resources) > 4096:
        raise ValueError('LibreOffice output exceeds the resource budget')
    return files[0], resources


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    root = Path.cwd()
    for name in ['home', 'tmp']:
        (root / name).mkdir(mode=0o700)
    original = fingerprint(args.source)
    html, resources = export(args.source, root, 'html', 'html:HTML (StarWriter)')
    if original != fingerprint(args.source):
        raise ValueError('the verified DOC snapshot changed after HTML export')
    text, _ = export(args.source, root, 'text', 'txt:Text (encoded):UTF8')
    if original != fingerprint(args.source):
        raise ValueError('the verified DOC snapshot changed between export runs')
    html_bytes = html.read_bytes()
    charset = re.search(br'charset\s*=\s*["\']?([a-zA-Z0-9_-]+)', html_bytes[:4096], re.IGNORECASE)
    encoding = charset.group(1).decode('ascii') if charset else 'utf-8'
    content = html_bytes.decode(encoding)
    html.write_text(content, encoding='utf-8')
    reference = text.read_text(encoding='utf-8-sig')
    (root / 'reference.txt').write_text(reference, encoding='utf-8')
    images = Images()
    images.feed(content)
    print(json.dumps({'htmlFile': str(html.relative_to(root)), 'referenceFile': 'reference.txt',
                      'sourceSHA256': original[0], 'sourceByteCount': original[1],
                      'imageReferenceCount': len(images.references),
                      'imageResourceCount': sum(p.suffix.lower() in ['.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.svg', '.wmf', '.emf'] for p in resources)}))


if __name__ == '__main__':
    try:
        main()
    except FileNotFoundError as error:
        print(str(error)[:2048], file=sys.stderr)
        sys.exit(69 if error.filename == '/usr/bin/libreoffice' else 65)
    except subprocess.TimeoutExpired:
        print('The local LibreOffice DOC export exceeded its time limit.', file=sys.stderr)
        sys.exit(124)
    except OSError as error:
        print(str(error)[:2048], file=sys.stderr)
        sys.exit(74 if error.errno in (errno.ENOSPC, errno.EDQUOT, errno.EIO, errno.EROFS, errno.EACCES) else 65)
    except Exception as error:
        print(str(error)[:2048], file=sys.stderr)
        sys.exit(65)

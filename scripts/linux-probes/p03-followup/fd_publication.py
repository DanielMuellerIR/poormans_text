#!/usr/bin/env python3
"""Isolierter Linux-Prototyp, kein Produktadapter."""
import concurrent.futures, ctypes, errno, hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile, threading
P = pathlib.Path
if not os.environ.get('PMT_PROBE_OUTPUT'):
    raise SystemExit('PMT_PROBE_OUTPUT muss einen eigenen bestehenden Belegordner angeben')
OUTPUT = P(os.environ['PMT_PROBE_OUTPUT'])
if not OUTPUT.is_dir():
    raise SystemExit('Belegordner fehlt')
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC

def basename(name):
    if not isinstance(name, str) or not name or name in ('.', '..') or ('/' in name) or ('\x00' in name):
        raise ValueError('invalid basename')
    return os.fsencode(name)

def walk(path):
    path = P(path)
    if not path.is_absolute():
        raise ValueError('absolute anchor required')
    fd = os.open('/', FLAGS)
    try:
        for component in path.parts[1:]:
            basename(component)
            nxt = os.open(component, FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise

def identity(fd):
    s = os.fstat(fd)
    return (s.st_dev, s.st_ino)

def unchanged(path, fd):
    try:
        current = walk(path)
        try:
            return identity(current) == identity(fd)
        finally:
            os.close(current)
    except OSError:
        return False

def publish(srcfd, source, dstfd, target, anchor, before_rename=lambda: None, after_rename=lambda: None):
    source = basename(source)
    target = basename(target)
    if not unchanged(anchor, dstfd):
        raise OSError(errno.ESTALE, 'anchor changed before publication')
    before_rename()
    if renameat2(srcfd, source, dstfd, target, 1) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    after_rename()
    if not unchanged(anchor, dstfd):
        raise OSError(errno.ESTALE, 'anchor changed after publication; complete result retained at held parent')

def write_stage(root, name, payload):
    stage = root / name
    stage.mkdir()
    (stage / 'payload').write_bytes(payload)

def suite(base, label):
    base = P(tempfile.mkdtemp(prefix='fd-probe-', dir=base))
    report = {'filesystem': label, 'checks': {}}
    try:
        for invalid in ['', '.', '..', 'x/y', 'x\x00y']:
            try:
                basename(invalid)
            except ValueError:
                pass
            else:
                raise AssertionError('invalid basename accepted')
        report['checks']['basenameValidation'] = True
        anchor = base / 'anchor'
        anchor.mkdir()
        fd = walk(anchor)
        try:
            for n in range(64):
                write_stage(anchor, 'stage' + str(n), str(n).encode())
            barrier = threading.Barrier(64)

            def contender(n):
                barrier.wait()
                try:
                    publish(fd, 'stage' + str(n), fd, 'winner', anchor)
                    return 0
                except OSError as error:
                    return error.errno
            with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
                codes = list(pool.map(contender, range(64)))
            assert codes.count(0) == 1 and codes.count(errno.EEXIST) == 63, codes
            assert (anchor / 'winner/payload').read_text() in list(map(str, range(64)))
            report['checks']['race64'] = {'success': 1, 'EEXIST': 63}
            foreign = base / 'foreign'
            foreign.mkdir()
            (foreign / 'sentinel').write_bytes(b'FOREIGN')
            for kind in ['file', 'directory', 'symlink']:
                target = anchor / kind
                if kind == 'file':
                    target.write_bytes(b'OLD')
                elif kind == 'directory':
                    target.mkdir()
                    (target / 'sentinel').write_bytes(b'OLD')
                else:
                    target.symlink_to(foreign, target_is_directory=True)
                write_stage(anchor, 'new-' + kind, b'NEW')
                try:
                    publish(fd, 'new-' + kind, fd, kind, anchor)
                except OSError as error:
                    assert error.errno == errno.EEXIST
                else:
                    raise AssertionError('overwrite')
                assert target.read_bytes() == b'OLD' if kind == 'file' else (target / 'sentinel').read_bytes() == (b'OLD' if kind == 'directory' else b'FOREIGN')
                if kind == 'symlink':
                    assert target.is_symlink()
            report['checks']['existingFileDirectorySymlinkPreserved'] = True
        finally:
            os.close(fd)
        for phase in ['before-bind', 'before-precheck', 'between-check-and-rename', 'after-rename']:
            parent = base / phase
            parent.mkdir()
            foreign = base / ('foreign-' + phase)
            foreign.mkdir()
            (foreign / 'sentinel').write_bytes(b'FOREIGN')
            write_stage(parent, 'stage', b'COMPLETE')
            held = base / (phase + '-held')

            def swap():
                parent.rename(held)
                parent.symlink_to(foreign, target_is_directory=True)
            if phase == 'before-bind':
                swap()
                try:
                    walk(parent)
                except OSError as error:
                    assert error.errno in (errno.ENOTDIR, errno.ELOOP)
                else:
                    raise AssertionError('followed symlink anchor')
            else:
                fd = walk(parent)
                try:
                    if phase == 'before-precheck':
                        swap()
                    try:
                        publish(fd, 'stage', fd, 'result', parent, before_rename=swap if phase == 'between-check-and-rename' else lambda: None, after_rename=swap if phase == 'after-rename' else lambda: None)
                    except OSError as error:
                        assert error.errno == errno.ESTALE, (phase, error)
                    else:
                        raise AssertionError('stale anchor reported success')
                    if phase in ('between-check-and-rename', 'after-rename'):
                        assert (held / 'result/payload').read_bytes() == b'COMPLETE'
                    else:
                        assert (held / 'stage/payload').read_bytes() == b'COMPLETE'
                finally:
                    os.close(fd)
            assert sorted((x.name for x in foreign.iterdir())) == ['sentinel']
            assert (foreign / 'sentinel').read_bytes() == b'FOREIGN'
            report['checks'][phase] = {'foreignUnchanged': True, 'successReported': False}
        inner = base / 'inner'
        inner.mkdir()
        (inner / 'link').symlink_to(base / 'foreign', target_is_directory=True)
        try:
            walk(inner / 'link' / 'nested')
        except OSError as error:
            assert error.errno in (errno.ENOTDIR, errno.ELOOP)
        else:
            raise AssertionError('followed intermediate symlink')
        report['checks']['intermediateSymlinkRejected'] = True
        report['pass'] = True
        return report
    finally:
        shutil.rmtree(base)

def digest(path):
    return hashlib.sha256(P(path).read_bytes()).hexdigest()

def prepare_copy(root):
    root.mkdir()
    (root / 'source').write_bytes(b'ORIGINAL-SOURCE' + b'X' * (1024 * 1024))
    (root / 'old-target').mkdir()
    (root / 'old-target/sentinel').write_bytes(b'OLD-TARGET')
    (root / 'stage').mkdir()
    (root / 'stage/partial').touch()

def copy_and_publish(root):
    errors = []
    published = False
    rootfd = walk(root)
    stagefd = os.open('stage', FLAGS, dir_fd=rootfd)
    fd = os.open('partial', os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=stagefd)
    try:
        data = (root / 'source').read_bytes()
        offset = 0
        try:
            while offset < len(data):
                count = os.write(fd, data[offset:])
                if count <= 0:
                    raise OSError(errno.EIO, 'write made no progress')
                offset += count
        except OSError as error:
            errors.append({'operation': 'write', 'errno': error.errno})
        try:
            os.fsync(fd)
        except OSError as error:
            errors.append({'operation': 'fsync', 'errno': error.errno})
        if not errors:
            try:
                os.fsync(stagefd)
                publish(rootfd, 'stage', rootfd, 'new-result', root)
                published = True
            except OSError as error:
                errors.append({'operation': 'publish', 'errno': error.errno})
        if not published:
            os.unlink('partial', dir_fd=stagefd)
            os.rmdir('stage', dir_fd=rootfd)
    finally:
        os.close(fd)
        os.close(stagefd)
        os.close(rootfd)
    return {'errors': errors, 'newResultPublished': published, 'bytesWritten': offset, 'ownPartialRemoved': not (root / 'stage').exists()}

def full_before(mount):
    control = P(mount) / 'space-control'
    prepare_copy(control)
    outcome = copy_and_publish(control)
    assert outcome['newResultPublished'] and (not outcome['errors'])
    assert digest(control / 'new-result/partial') == digest(control / 'source')
    (OUTPUT / 'space-control.json').write_text(json.dumps(dict(outcome, outputHashMatchesSource=True), indent=2))
    root = P(mount) / 'enospc-case'
    prepare_copy(root)
    state = {'source': digest(root / 'source'), 'oldTarget': digest(root / 'old-target/sentinel')}
    (OUTPUT / 'full-state.json').write_text(json.dumps(state))

def full_after(mount):
    root = P(mount) / 'enospc-case'
    state = json.loads((OUTPUT / 'full-state.json').read_text())
    outcome = copy_and_publish(root)
    assert any((item['errno'] == errno.ENOSPC for item in outcome['errors'])), outcome
    assert not outcome['newResultPublished'] and (not (root / 'new-result').exists())
    assert digest(root / 'source') == state['source']
    assert digest(root / 'old-target/sentinel') == state['oldTarget']
    assert outcome['ownPartialRemoved']
    outcome.update(passResult=True, sourceHashUnchanged=True, oldTargetHashUnchanged=True)
    (OUTPUT / 'full-result.json').write_text(json.dumps(outcome, indent=2))
if __name__ == '__main__':
    mode = sys.argv[1]
    if mode == 'before-full':
        mount = sys.argv[2]
        (OUTPUT / 'ext4-fd-result.json').write_text(json.dumps(suite(mount, 'ext4'), indent=2))
        full_before(mount)
    elif mode == 'after-full':
        full_after(sys.argv[2])
    elif mode == 'btrfs':
        target = P(sys.argv[2])
        kind = subprocess.check_output(['findmnt', '-n', '-o', 'FSTYPE', '--target', str(target)], text=True).strip()
        assert kind == 'btrfs', kind
        (OUTPUT / 'btrfs-fd-result.json').write_text(json.dumps(suite(target, 'btrfs'), indent=2))
    else:
        raise ValueError(mode)

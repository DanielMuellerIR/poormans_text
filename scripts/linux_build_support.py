"""Gemeinsame Publikation der statischen lokalen Linux-Einstiege."""
import os
import stat


def publish_launcher(parent, name, old_content, target):
    # Vorhandene korrekte Wrapper brauchen kein Update: Ihr Laufzeitziel bleibt gleich.
    # Fehlende Namen werden atomar ohne Ersetzen mit dem versionierten Helfer verknüpft.
    try:
        descriptor = os.open(name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    except FileNotFoundError:
        os.symlink(target, name, dir_fd=parent)
        descriptor = os.open(name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    try:
        before = os.fstat(descriptor)
        def stamp(value):
            return (value.st_dev, value.st_ino, value.st_mode, value.st_size,
                    value.st_mtime_ns, value.st_ctime_ns)
        if stat.S_ISLNK(before.st_mode):
            recognized = os.readlink('', dir_fd=descriptor) == target
        elif stat.S_ISREG(before.st_mode):
            read = os.open(f'/proc/self/fd/{descriptor}', os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
            with os.fdopen(read, 'rb') as stream:
                recognized = bool(before.st_mode & 0o111) and stream.read(len(old_content) + 1) == old_content
        else:
            recognized = False
        current = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if not recognized or stamp(before) != stamp(os.fstat(descriptor)) or stamp(before) != stamp(current):
            raise RuntimeError('Launcher is unknown or changed; it was preserved: ' + name)
    finally:
        os.close(descriptor)

#!/usr/bin/env python3
"""P03: isolierte Linux-Systemaufrufprobe, ausdrücklich kein Produktadapter."""
import argparse
import concurrent.futures
import ctypes
import errno
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parent", type=Path, required=True,
                        help="Bestehender beschreibbarer Ordner auf dem zu prüfenden Dateisystem")
    parser.add_argument("--other-filesystem-parent", type=Path,
                        help="Optional: Ordner auf einem anderen Dateisystem für EXDEV")
    args = parser.parse_args()
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    results = {}

    def publish(source, destination):
        # RENAME_NOREPLACE prüft Kollision und Rename in EINEM Kernelaufruf.
        if rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1):
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code))

    with tempfile.TemporaryDirectory(prefix="pmt-p03-", dir=args.parent) as temporary:
        root = Path(temporary)
        source = root / "source"
        source.write_bytes(b"original\x00bytes")
        original = source.read_bytes()
        descriptor = os.open(source, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        try:
            source.rename(root / "original")
            source.write_bytes(b"replacement")
            results["held_source_after_path_exchange"] = os.read(descriptor, 100) == original
        finally:
            os.close(descriptor)

        for kind in ("symlink", "fifo"):
            path = root / kind
            if kind == "symlink":
                path.symlink_to(source)
            else:
                os.mkfifo(path)
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
            except OSError as error:
                results[kind + "_rejected"] = kind == "symlink" and error.errno == errno.ELOOP
            else:
                try:
                    results[kind + "_rejected"] = not stat.S_ISREG(os.fstat(fd).st_mode)
                finally:
                    os.close(fd)

        def contender(index):
            stage = root / ("stage-" + str(index))
            stage.mkdir(mode=0o700)
            (stage / "complete").write_text(str(index))
            try:
                publish(stage, root / "result")
                return "published"
            except OSError as error:
                return "collision" if error.errno == errno.EEXIST else str(error.errno)

        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            outcomes = list(pool.map(contender, range(64)))
        results["atomic_collision_64_contenders"] = (
            outcomes.count("published") == 1 and outcomes.count("collision") == 63
            and (root / "result" / "complete").read_text() in map(str, range(64)))
        stage = root / "symlink-stage"
        stage.mkdir()
        destination = root / "destination-link"
        destination.symlink_to(root / "result", target_is_directory=True)
        try:
            publish(stage, destination)
        except OSError as error:
            results["destination_symlink_preserved"] = error.errno == errno.EEXIST and destination.is_symlink()
        else:
            results["destination_symlink_preserved"] = False

        restricted = root / "restricted"
        restricted.mkdir(mode=0o500)
        try:
            try:
                fd = os.open(restricted / "output", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except OSError as error:
                results["permission_denied"] = error.errno == errno.EACCES
            else:
                os.close(fd)
                results["permission_denied"] = False
        finally:
            restricted.chmod(0o700)

        # /dev/full belegt den ENOSPC-Fehlerpfad, keine vollständig gefüllte Partition.
        with open("/dev/full", "wb", buffering=0) as full:
            results["enospc_device"] = False
            try:
                full.write(b"unfinished")
            except OSError as error:
                results["enospc_device"] = error.errno == errno.ENOSPC
        results["original_preserved"] = (root / "original").read_bytes() == original
        if args.other_filesystem_parent:
            with tempfile.TemporaryDirectory(prefix="pmt-p03-cross-", dir=args.other_filesystem_parent) as other:
                cross_stage = Path(other) / "stage"
                cross_stage.mkdir()
                (cross_stage / "complete").write_bytes(original)
                assert cross_stage.stat().st_dev != root.stat().st_dev, "Kein anderes Dateisystem"
                try:
                    publish(cross_stage, root / "cross-result")
                except OSError as error:
                    results["cross_device_fails_closed"] = (error.errno == errno.EXDEV
                        and not (root / "cross-result").exists()
                        and (cross_stage / "complete").read_bytes() == original)
                else:
                    results["cross_device_fails_closed"] = False

        # Als Subreaper können wir auch die im Versuch verwaisten Enkel ernten.
        if libc.prctl(36, 1, 0, 0, 0):
            raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
        helper = root / "child.py"
        helper.write_text("import os, signal, time\n"
                          "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                          "pid = os.fork()\n"
                          "if pid == 0:\n"
                          "    open('grandchild', 'w').write(str(os.getpid()))\n"
                          "while True: time.sleep(0.01)\n")
        for reason in ("timeout", "cancel"):
            marker = root / "grandchild"
            marker.unlink(missing_ok=True)
            capture = root / (reason + ".capture")
            process = None
            owned_group = None
            try:
                with capture.open("wb") as output:
                    process = subprocess.Popen([sys.executable, str(helper)], cwd=root,
                                               start_new_session=True, stdout=output, stderr=output)
                    results[reason + "_owns_group"] = os.getpgid(process.pid) == process.pid != os.getpgrp()
                    if not results[reason + "_owns_group"]:
                        raise RuntimeError("Keine eigene Prozessgruppe")
                    owned_group = process.pid
                    deadline = time.monotonic() + 3
                    while not marker.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    grandchild = int(marker.read_text())
                    os.killpg(process.pid, signal.SIGTERM)
                    time.sleep(0.05)
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
                    deadline = time.monotonic() + 3
                    reaped = False
                    while time.monotonic() < deadline:
                        pid, _ = os.waitpid(grandchild, os.WNOHANG)
                        if pid:
                            reaped = True
                            break
                        time.sleep(0.01)
                    results[reason + "_descendants_reaped"] = reaped
                    if reaped:
                        owned_group = None
            finally:
                if process is not None:
                    if owned_group is not None:
                        try:
                            os.killpg(owned_group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    elif process.poll() is None:
                        process.kill()
                    process.wait(timeout=3)

        # Metazeichen bleiben bei direktem argv-Transport unveränderte Daten.
        argument = "spaces;$(touch INJECTED) ' ä"
        completed = subprocess.run([sys.executable, "-c", "import sys; print(sys.argv[1])", argument],
                                   cwd=root, capture_output=True, timeout=3, check=True, text=True)
        results["literal_arguments"] = completed.stdout.rstrip("\n") == argument and not (root / "INJECTED").exists()

    print(json.dumps({"probe": "P03-kernel-primitives", "results": results,
                      "limits": ["Kein Produktadapter", "Kein Stromausfalltest", "ENOSPC nur /dev/full",
                                 "Kein Schutz vor setsid-Flucht oder Supervisorverlust belegt",
                                 "Kein ext4-/Netzlaufwerksnachweis ohne gesonderten Lauf"]}, indent=2))
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())

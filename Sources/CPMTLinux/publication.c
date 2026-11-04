#define _GNU_SOURCE
#include "PMTPublication.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

int pmt_renameat2_noreplace(int source_directory, const char *source, int target_directory, const char *target) {
    return syscall(SYS_renameat2, source_directory, source, target_directory, target, RENAME_NOREPLACE);
}

/* Ausschließlich relativ zum gehaltenen Eltern-FD; Symlinks werden entfernt,
   niemals verfolgt. Ein ausgetauschter Verzeichnisname verhindert das rmdir. */
static int remove_tree_at(int parent, const char *name, int expected) {
    struct stat original;
    if (fstatat(parent, name, &original, AT_SYMLINK_NOFOLLOW)) return errno == ENOENT ? 0 : -1;
    if (expected >= 0) {
        struct stat bound;
        if (fstat(expected, &bound)) return -1;
        if (bound.st_dev != original.st_dev || bound.st_ino != original.st_ino) { errno = ESTALE; return -1; }
    }
    if (!S_ISDIR(original.st_mode)) return unlinkat(parent, name, 0);
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat held;
    if (fstat(fd, &held) || held.st_dev != original.st_dev || held.st_ino != original.st_ino) {
        close(fd); errno = ESTALE; return -1;
    }
    DIR *directory = fdopendir(fd);
    if (!directory) { int saved = errno; close(fd); errno = saved; return -1; }
    struct dirent *entry;
    int result = 0;
    for (;;) {
        errno = 0;
        entry = readdir(directory);
        if (!entry) { if (errno) result = -1; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (remove_tree_at(fd, entry->d_name, -1)) { result = -1; break; }
    }
    int saved = errno;
    if (!result) {
        struct stat current;
        if (fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW)) { result = -1; saved = errno; }
        else if (current.st_dev != held.st_dev || current.st_ino != held.st_ino) { result = -1; saved = ESTALE; }
        else if (unlinkat(parent, name, AT_REMOVEDIR)) { result = -1; saved = errno; }
    }
    closedir(directory);
    errno = saved;
    return result;
}

int pmt_remove_staging_at(int parent, const char *name, int expected) {
    return remove_tree_at(parent, name, expected);
}

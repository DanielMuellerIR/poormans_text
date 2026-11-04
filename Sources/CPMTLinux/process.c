#define _GNU_SOURCE
#include "PMTProcess.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

int pmt_process_pidfd_open_owned(int pid, int ancestor) {
    int fd = (int)syscall(SYS_pidfd_open, pid, 0);
    if (fd < 0) return -1;
    int current = pid;
    for (int depth = 0; depth < 128 && current > 1; ++depth) {
        if (current == ancestor) return fd;
        char path[64], line[256];
        snprintf(path, sizeof(path), "/proc/%d/status", current);
        FILE *status = fopen(path, "re");
        int parent = -1;
        if (status) {
            while (fgets(line, sizeof(line), status))
                if (sscanf(line, "PPid: %d", &parent) == 1) break;
            fclose(status);
        }
        if (parent <= 0 || parent == current) break;
        current = parent;
    }
    close(fd);
    errno = ESRCH;
    return -1;
}

int pmt_process_pidfd_ready(int fd, int timeout_ms) {
    struct pollfd process = {.fd = fd, .events = POLLIN};
    int result;
    do { result = poll(&process, 1, timeout_ms); } while (result < 0 && errno == EINTR);
    if (result < 0 || (result > 0 && !(process.revents & POLLIN))) return -1;
    return result > 0;
}

/* Ein bereits beendeter Guard darf den aufrufenden Host nicht per SIGPIPE
   beenden. Die Signalsperre betrifft ausschließlich den schreibenden Thread. */
int pmt_process_write_control(int fd, unsigned char value) {
    sigset_t blocked, previous, pending;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    int result = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (result != 0) { errno = result; return -1; }
    sigpending(&pending);
    int already_pending = sigismember(&pending, SIGPIPE);
    ssize_t count;
    do { count = write(fd, &value, 1); } while (count < 0 && errno == EINTR);
    int saved = errno;
    if (count < 0 && saved == EPIPE && !already_pending) {
        struct timespec no_wait = {0, 0};
        while (sigtimedwait(&blocked, NULL, &no_wait) < 0 && errno == EINTR) {}
    }
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    errno = saved;
    return count == 1 ? 0 : -1;
}


int pmt_process_open_relative_directory(int root_fd, const char *relative) {
    int current = fcntl(root_fd, F_DUPFD_CLOEXEC, 3);
    if (current < 0) return -1;
    if (!*relative) return current;
    char *copy = strdup(relative);
    if (!copy) { close(current); return -1; }
    char *part = copy;
    for (;;) {
        char *next = strchr(part, '/');
        if (next) *next = 0;
        if (!*part || !strcmp(part, ".") || !strcmp(part, "..")) { errno = EINVAL; break; }
        int child = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (child < 0) break;
        close(current);
        current = child;
        if (!next) { free(copy); return current; }
        part = next + 1;
    }
    int saved = errno;
    free(copy);
    close(current);
    errno = saved;
    return -1;
}

int pmt_process_open_directory(const char *path) {
    if (path[0] != '/') { errno = EINVAL; return -1; }
    int root = -1;
    const char *relative = path + 1;
    if (!strncmp(path, "/proc/", 6)) {
        char *end;
        errno = 0;
        long owner = strtol(path + 6, &end, 10);
        if (errno || owner != getpid() || strncmp(end, "/fd/", 4)) { errno = EINVAL; return -1; }
        const char *number = end + 4;
        long descriptor = strtol(number, &end, 10);
        if (errno || end == number || descriptor < 0 || descriptor > INT_MAX || (*end && *end != '/')) { errno = EINVAL; return -1; }
        root = fcntl((int)descriptor, F_DUPFD_CLOEXEC, 3);
        relative = *end ? end + 1 : end;
    } else {
        root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }
    if (root < 0) return -1;
    struct stat metadata;
    if (fstat(root, &metadata) != 0 || !S_ISDIR(metadata.st_mode)) { close(root); errno = ENOTDIR; return -1; }
    int result = pmt_process_open_relative_directory(root, relative);
    int saved = errno;
    close(root);
    errno = saved;
    return result;
}

int pmt_process_unlink_owned_capture(int directory, const char *name, int descriptor) {
    struct stat held, named;
    if (strchr(name, '/') || !*name) { errno = EINVAL; return -1; }
    if (fstat(descriptor, &held) != 0 || fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    if (!S_ISREG(named.st_mode) || named.st_dev != held.st_dev || named.st_ino != held.st_ino) { errno = ESTALE; return -1; }
    return unlinkat(directory, name, 0);
}

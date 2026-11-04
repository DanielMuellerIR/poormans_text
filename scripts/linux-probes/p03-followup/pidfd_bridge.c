#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/pidfd.h>
#include <unistd.h>

/* Kernelidentität beobachten, ohne mit Foundations waitpid um das Reaping
   zu konkurrieren. Der Aufrufer schließt den Lebensdauerkanal vor waitUntilExit. */
int pmt_pidfd_open(int pid) {
    int fd = pidfd_open(pid, 0);
    if (fd < 0) return -1;
    char path[64], line[256];
    snprintf(path, sizeof(path), "/proc/%d/status", pid);
    FILE *status = fopen(path, "re");
    int parent = -1;
    if (status) {
        while (fgets(line, sizeof(line), status)) {
            if (sscanf(line, "PPid: %d", &parent) == 1) break;
        }
        fclose(status);
    }
    if (parent != getpid()) {
        close(fd);
        errno = ESRCH;
        return -1;
    }
    return fd;
}
int pmt_pidfd_wait(int fd) {
    struct pollfd process = { .fd = fd, .events = POLLIN };
    int result;
    do { result = poll(&process, 1, -1); } while (result < 0 && errno == EINTR);
    return result > 0 && (process.revents & POLLIN) ? 0 : -1;
}

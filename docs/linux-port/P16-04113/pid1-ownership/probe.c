#define _GNU_SOURCE
#include "PMTProcess.h"
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static int count_fds(void) {
    DIR *d = opendir("/proc/self/fd"); assert(d);
    int n = 0; struct dirent *e;
    while ((e = readdir(d))) if (e->d_name[0] != '.') ++n;
    closedir(d); return n;
}
int main(void) {
    assert(getpid() == 1);
    int initial = count_fds();
    int channel[2]; assert(pipe(channel) == 0);
    pid_t a = fork(); assert(a >= 0);
    if (a == 0) {
        close(channel[0]);
        pid_t g = fork(); assert(g >= 0);
        if (g == 0) { close(channel[1]); for (;;) pause(); }
        assert(write(channel[1], &g, sizeof(g)) == sizeof(g));
        close(channel[1]); for (;;) pause();
    }
    close(channel[1]); pid_t grandchild;
    assert(read(channel[0], &grandchild, sizeof(grandchild)) == sizeof(grandchild));
    close(channel[0]);
    pid_t b = fork(); assert(b >= 0);
    if (b == 0) for (;;) pause();
    int direct = pmt_process_pidfd_open_owned(a, getpid()); assert(direct >= 0);
    int deep = pmt_process_pidfd_open_owned(grandchild, getpid()); assert(deep >= 0);
    int parent = pmt_process_pidfd_open_owned(grandchild, a); assert(parent >= 0);
    int before = count_fds();
    for (int i = 0; i < 100; ++i) {
        int self = pmt_process_pidfd_open_owned(getpid(), getpid()); assert(self >= 0); close(self);
        errno = 0; int denied = pmt_process_pidfd_open_owned(a, b);
        assert(denied == -1 && errno == ESRCH);
        assert(kill(a, 0) == 0 && kill(b, 0) == 0 && kill(grandchild, 0) == 0);
    }
    assert(count_fds() == before);
    assert(pmt_process_pidfd_ready(direct, 0) == 0);
    assert(pmt_process_pidfd_ready(deep, 0) == 0);
    assert(kill(grandchild, SIGKILL) == 0);
    assert(kill(a, SIGKILL) == 0);
    assert(kill(b, SIGKILL) == 0);
    assert(pmt_process_pidfd_ready(direct, 5000) == 1);
    assert(pmt_process_pidfd_ready(deep, 5000) == 1);
    assert(pmt_process_pidfd_ready(parent, 5000) == 1);
    close(direct); close(deep); close(parent);
    int reaped = 0; int status;
    for (;;) {
        pid_t got = waitpid(-1, &status, 0);
        if (got > 0) { assert(WIFSIGNALED(status)); ++reaped; continue; }
        assert(got == -1 && errno == ECHILD); break;
    }
    assert(reaped == 3 && count_fds() == initial);
    printf("{\"actualPID\":%d,\"uid\":%d,\"directDescendantAccepted\":true,\"deepDescendantAccepted\":true,\"intermediateAncestorAccepted\":true,\"PID1SelfAccepted\":true,\"siblingDeniedESRCH\":true,\"negativeIterations\":100,\"targetsAliveAfterDenial\":true,\"fdBefore\":%d,\"fdAfter\":%d,\"pidfdsReadyBeforeClose\":true,\"childrenReaped\":%d}\n",getpid(),getuid(),initial,count_fds(),reaped);
    return 0;
}

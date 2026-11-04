#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <unistd.h>

/* Nur P03-Probe: PID 1 beendet mit seinem Exit den gesamten Namespace.
   stdin ist die Lebensdauer-Pipe, deren einziges Schreibende beim Runner liegt. */
int main(int argc, char **argv) {
    if (getpid() != 1 || argc < 2) {
        fputs("guard requires a private PID namespace and a command\n", stderr);
        return 125;
    }
    // Ein Werkzeug darf das Leseende nicht über /proc/1/fd/0 als neues
    // Schreibende öffnen oder den überwachenden Guard per ptrace verändern.
    if (prctl(PR_SET_DUMPABLE, 0) != 0) return 125;
    struct pollfd owner = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP };
    unsigned char start;
    ssize_t received;
    do { received = read(STDIN_FILENO, &start, 1); } while (received < 0 && errno == EINTR);
    if (received != 1 || start != 1) return 125;
    int ready = poll(&owner, 1, 0);
    if (ready < 0 || (ready > 0 && owner.revents)) return 125;
    pid_t child = fork();
    if (child < 0) return 125;
    if (child == 0) {
        int null = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (null < 0 || dup2(null, STDIN_FILENO) < 0) _exit(125);
        if (null != STDIN_FILENO) close(null);
        execvp(argv[1], argv + 1);
        _exit(127);
    }
    for (;;) {
        int status;
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) {
            if (WIFEXITED(status)) return WEXITSTATUS(status);
            return 128 + WTERMSIG(status);
        }
        if (result < 0 && errno != EINTR) return 125;
        ready = poll(&owner, 1, 10);
        if (ready > 0 && owner.revents) return 130;
        if (ready < 0 && errno != EINTR) return 125;
    }
}

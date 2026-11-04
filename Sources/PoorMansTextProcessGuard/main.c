#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long long milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) _exit(125);
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

/* ABI 1: argv = --pmt-process-guard-v1 stdout-path grace-ms -- command args.
   stdin bleibt ausschließlich beim Guard; EOF beendet den PID-Namespace.
   Byte 1 startet, Byte 2 beendet alle Werkzeuge mit der vereinbarten Frist. */
static int launch_sandbox(int argc, char **argv) {
    if (argc < 5) return 125;
    char *end;
    long count = strtol(argv[2], &end, 10);
    if (*end || count < 1 || count > 1024 || argc < count + 5 || strcmp(argv[3 + count], "--")) return 125;
    char **numbers = calloc((size_t)count, sizeof(char *));
    if (!numbers) return 125;
    for (long i = 0; i < count; ++i) {
        // Vor dem Usernamespacewechsel öffnen: fremdes Host-/proc ist danach
        // absichtlich nicht mehr zugänglich. Nur gehaltene FDs werden gebunden.
        int fd = open(argv[3 + i], O_PATH);
        struct stat metadata;
        if (fd < 0 || fstat(fd, &metadata) != 0 ||
            !(S_ISREG(metadata.st_mode) || S_ISDIR(metadata.st_mode)) ||
            (i == 0 && !S_ISDIR(metadata.st_mode))) {
            fputs("PMT sandbox input could not be bound by descriptor\n", stderr);
            return 125;
        }
        if (asprintf(&numbers[i], "%d", fd) < 0) return 125;
    }
    char **command = argv + count + 4;
    // Nur die Optionsliste wird ersetzt, niemals Argumente des Werkzeugs.
    for (int i = 1; command[i] && strcmp(command[i], "--"); ++i) {
        if ((!strcmp(command[i], "--bind-fd") || !strcmp(command[i], "--ro-bind-fd")) && command[i + 1]) {
            char *placeholder = command[++i];
            if (strncmp(placeholder, "pmt-fd:", 7)) return 125;
            long index = strtol(placeholder + 7, &end, 10);
            if (*end || index < 0 || index >= count) return 125;
            command[i] = numbers[index];
        }
    }
    execv(command[0], command);
    perror("PMT sandbox exec");
    return 125;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--pmt-sandbox-launch-v1")) return launch_sandbox(argc, argv);

    if (getpid() != 1 || argc < 6 ||
        strcmp(argv[1], "--pmt-process-guard-v1") || strcmp(argv[4], "--")) {
        fputs("PMT process guard requires ABI 1 and a private PID namespace\n", stderr);
        return 125;
    }
    char *end;
    errno = 0;
    long grace = strtol(argv[3], &end, 10);
    if (errno || *end || grace < 0 || grace > INT_MAX) return 125;
    if (prctl(PR_SET_DUMPABLE, 0) != 0) return 125;
    if (close_range(3, UINT_MAX, 0) != 0) return 125;
    unsigned char control;
    ssize_t received;
    do { received = read(STDIN_FILENO, &control, 1); } while (received < 0 && errno == EINTR);
    if (received != 1 || control != 1) return 125;
    struct pollfd owner = {.fd = STDIN_FILENO, .events = POLLIN | POLLHUP};
    int ready = poll(&owner, 1, 0);
    if (ready < 0 || (ready > 0 && owner.revents)) return 125;
    int output = open(argv[2], O_WRONLY | O_NOFOLLOW | O_CLOEXEC);
    if (output < 0) return 125;
    pid_t child = fork();
    if (child < 0) { close(output); return 125; }
    if (child == 0) {
        int null = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (null < 0 || dup2(null, STDIN_FILENO) < 0 || dup2(output, STDOUT_FILENO) < 0 ||
            fcntl(STDOUT_FILENO, F_SETFD, 0) < 0) _exit(125);
        if (null != STDIN_FILENO) close(null);
        if (output != STDOUT_FILENO) close(output);
        execv(argv[5], argv + 5);
        perror("PMT conversion tool exec");
        _exit(127);
    }
    close(output);
    int main_status = 125, main_ended = 0, stopping = 0;
    long long deadline = 0;
    for (;;) {
        int status;
        pid_t reaped;
        while ((reaped = waitpid(-1, &status, WNOHANG)) > 0) {
            if (reaped == child) {
                main_ended = 1;
                main_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
                if (!stopping) {
                    stopping = 1;
                    deadline = milliseconds() + grace;
                    kill(-1, SIGTERM);
                }
            }
        }
        if (reaped < 0 && errno == ECHILD) return main_ended ? main_status : 125;
        if (reaped < 0 && errno != EINTR) return 125;
        if (stopping && milliseconds() >= deadline) return main_ended ? main_status : 130;
        ready = poll(&owner, 1, 10);
        if (ready < 0 && errno != EINTR) return 125;
        if (ready > 0) {
            if (owner.revents & (POLLHUP | POLLERR | POLLNVAL)) return 130;
            do { received = read(STDIN_FILENO, &control, 1); } while (received < 0 && errno == EINTR);
            if (received != 1) return 130;
            if (control != 2) return 125;
            if (!stopping) {
                stopping = 1;
                deadline = milliseconds() + grace;
                kill(-1, SIGTERM);
            }
        }
    }
}

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/loop.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

/* Ausschließlich eigene 64-MiB-Testimages. LOOP_CONFIGURE setzt AUTOCLEAR
   atomar beim Attach; ein SIGKILL vor mount lässt keine Loopbindung zurück. */
int main(int argc, char **argv) {
    if (argc < 3 || argc > 4 || strncmp(argv[1], "/results/ext4-probe.", 20) != 0 ||
        strchr(argv[1] + 9, '/') || strcmp(argv[2], "/run/ext4") != 0) return 64;
    int image = open(argv[1], O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (image < 0 || fstat(image, &info) || !S_ISREG(info.st_mode) ||
        info.st_size != 67108864) return 65;
    int control = open("/dev/loop-control", O_RDWR | O_CLOEXEC);
    if (control < 0) return 69;
    for (int attempt = 0; attempt < 16; attempt++) {
        int number = ioctl(control, LOOP_CTL_GET_FREE);
        if (number < 0) return 69;
        char device[64];
        snprintf(device, sizeof(device), "/dev/loop%d", number);
        if (mknod(device, S_IFBLK | 0600, makedev(7, number)) && errno != EEXIST) return 69;
        int loop = open(device, O_RDWR | O_CLOEXEC);
        if (loop < 0) return 69;
        struct loop_config config = {0};
        config.fd = image;
        config.info.lo_flags = LO_FLAGS_AUTOCLEAR;
        if (ioctl(loop, LOOP_CONFIGURE, &config)) {
            int error = errno;
            close(loop);
            if (error == EBUSY) continue;
            errno = error;
            perror("LOOP_CONFIGURE");
            return 69;
        }
        if (argc == 4 && strcmp(argv[3], "kill-after-attach") == 0) kill(getpid(), SIGKILL);
        if (mount(device, argv[2], "ext4", MS_NODEV | MS_NOSUID | MS_NOEXEC, NULL)) {
            perror("mount ext4");
            close(loop);
            return 74;
        }
        if (argc == 4 && strcmp(argv[3], "kill-after-mount") == 0) kill(getpid(), SIGKILL);
        struct loop_info64 state;
        if (ioctl(loop, LOOP_GET_STATUS64, &state) || !(state.lo_flags & LO_FLAGS_AUTOCLEAR)) return 70;
        printf("%s\n", device);
        close(loop);
        close(control);
        close(image);
        return 0;
    }
    return 75;
}

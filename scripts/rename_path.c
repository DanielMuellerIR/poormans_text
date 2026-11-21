#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char *argv[]) {
    if (argc != 4 || (strcmp(argv[1], "move") != 0 && strcmp(argv[1], "swap") != 0)) {
        fputs("Aufruf: rename-path <move|swap> <Quelle> <Ziel>\n", stderr);
        return 64;
    }

    // Jeder vorhandene Eintrag am exakten Ziel blockiert RENAME_EXCL, auch ein toter Symlink.
    unsigned int flags = strcmp(argv[1], "move") == 0 ? RENAME_EXCL : RENAME_SWAP;
    if (renameatx_np(AT_FDCWD, argv[2], AT_FDCWD, argv[3], flags) == -1) {
        fprintf(stderr, "%s → %s: %s\n", argv[2], argv[3], strerror(errno));
        return 1;
    }
    return 0;
}

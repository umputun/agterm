// Reports what the trampoline handed it, then holds the pty open until the parent acknowledges.
// A child that exits with unread output loses it: the exit-time close of the slave drains for about a
// second and then flushes, so a reader stalled past that window reads nothing. C rather than Swift:
// CoreFoundation, loaded by the Swift runtime, adds __CF_USER_TEXT_ENCODING to the environment. The
// report reads main's envp, not environ: a coverage build's profile runtime setenvs its own marker
// before main, and setenv copies into a new environ array, leaving the execve array untouched.

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static const char marker[] = "--pty-probe-end--\n";

static _Noreturn void fail(const char *what) {
    fprintf(stderr, "pty-probe: %s: %s\n", what, strerror(errno));
    exit(2);
}

static void write_all(const char *text) {
    size_t length = strlen(text), written = 0;
    while (written < length) {
        ssize_t step = write(STDOUT_FILENO, text + written, length - written);
        if (step < 0 && errno == EINTR) continue;
        if (step <= 0) fail("write");
        written += (size_t)step;
    }
}

static void report(int argc, char **argv, char **envp) {
    char line[64];
    if (argc == 2 && strcmp(argv[1], "env") == 0) {
        for (char **entry = envp; *entry; entry++) {
            write_all(*entry);
            write_all("\n");
        }
    } else if (argc >= 2 && strcmp(argv[1], "args") == 0) {
        char *cwd = getcwd(NULL, 0);
        if (!cwd) fail("getcwd");
        write_all(cwd);
        free(cwd);
        snprintf(line, sizeof(line), "\n%d\n", argc - 2);
        write_all(line);
        for (int i = 2; i < argc; i++) {
            write_all(argv[i]);
            write_all("\n");
        }
    } else if (argc == 2 && strcmp(argv[1], "size") == 0) {
        struct winsize size;
        if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) < 0) fail("TIOCGWINSZ");
        snprintf(line, sizeof(line), "%d %d\n", size.ws_row, size.ws_col);
        write_all(line);
    } else if (argc == 3 && strcmp(argv[1], "fd") == 0) {
        write_all(fcntl(atoi(argv[2]), F_GETFD) < 0 ? "closed\n" : "open\n");
    } else {
        errno = EINVAL;
        fail("usage: session-host-pty-probe env|args [ARG...]|size|fd N");
    }
}

int main(int argc, char **argv, char **envp) {
    // the acknowledgement would otherwise echo back into the output the parent is still reading
    struct termios attributes;
    if (tcgetattr(STDIN_FILENO, &attributes) < 0) fail("tcgetattr");
    attributes.c_lflag &= ~(tcflag_t)ECHO;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &attributes) < 0) fail("tcsetattr");

    report(argc, argv, envp);
    write_all(marker);

    char ack;
    for (;;) {
        ssize_t count = read(STDIN_FILENO, &ack, 1);
        if (count == 1) return 0;
        if (count < 0 && errno == EINTR) continue;
        if (count == 0) errno = EPIPE;
        fail("acknowledgement");
    }
}

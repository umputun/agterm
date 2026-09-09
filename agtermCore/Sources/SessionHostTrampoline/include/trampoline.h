#ifndef AGTERM_SESSION_HOST_TRAMPOLINE_H
#define AGTERM_SESSION_HOST_TRAMPOLINE_H

#include <sys/types.h>
#include <sys/ioctl.h>

/* argv/envp must be prepared, NULL-terminated buffers; argv[0] is the executable path.
 * Returns a child PID, or -1 with errno and both output descriptors set to -1.
 * The caller owns/reaps the child and closes master and exec_error; both are FD_CLOEXEC.
 * exec_error yields one native int errno on child setup/exec failure. EOF only means no
 * error was reported, not that the daemon is ready. Poll it rather than blocking for exec.
 * All other host-private descriptors (locks, listeners, connections, logs) MUST already
 * be FD_CLOEXEC. Only the PTY-backed standard descriptors intentionally survive exec.
 * No child path returns to the caller or invokes Swift/Foundation. */
pid_t sh_forkpty_exec(char *const argv[], char *const envp[], const char *cwd,
                     const struct winsize *size, int *master, int *exec_error);

#endif

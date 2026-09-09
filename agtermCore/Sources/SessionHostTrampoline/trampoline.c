#include "trampoline.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

/* Serialize descriptor setup with fork so another call cannot inherit unfinished descriptors. */
static pthread_mutex_t spawn_lock = PTHREAD_MUTEX_INITIALIZER;

static int make_error_pipe(int output[2]) {
    /* Keep the error pipe clear of the standard descriptors forkpty replaces. */
    int raw[2];
    if (pipe(raw) < 0) return -1;
    output[0] = fcntl(raw[0], F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    int saved = errno;
    if (output[0] >= 0) {
        output[1] = fcntl(raw[1], F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
        saved = errno;
    }
    close(raw[0]);
    close(raw[1]);
    errno = saved;
    return output[0] >= 0 && output[1] >= 0 ? 0 : -1;
}

static _Noreturn void child_failed(int fd, int error) {
    ssize_t result;
    do { result = write(fd, &error, sizeof(error)); } while (result < 0 && errno == EINTR);
    _exit(127);
}

pid_t sh_forkpty_exec(char *const argv[], char *const envp[], const char *cwd,
                     const struct winsize *size, int *master, int *exec_error) {
    if (master) *master = -1;
    if (exec_error) *exec_error = -1;
    if (!master || !exec_error || !argv || !argv[0] || !envp || !cwd || !size) {
        errno = EINVAL;
        return -1;
    }
    int locked = pthread_mutex_lock(&spawn_lock);
    if (locked != 0) { errno = locked; return -1; }

    int error_pipe[2] = {-1, -1};
    int master_fd = -1;
    struct winsize initial_size = *size;
    if (make_error_pipe(error_pipe) < 0) goto failed;
    pid_t child = forkpty(&master_fd, NULL, NULL, &initial_size);
    if (child < 0) goto failed;
    if (child == 0) {
        close(error_pipe[0]);
        if (chdir(cwd) < 0) child_failed(error_pipe[1], errno);
        execve(argv[0], argv, envp);
        child_failed(error_pipe[1], errno);
    }

    close(error_pipe[1]);
    error_pipe[1] = -1;
    int flags = fcntl(master_fd, F_GETFD);
    if (flags < 0 || fcntl(master_fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
        int saved = errno;
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        errno = saved;
        goto failed;
    }
    *master = master_fd;
    *exec_error = error_pipe[0];
    pthread_mutex_unlock(&spawn_lock);
    return child;

failed: {
        int saved = errno;
        if (master_fd >= 0) close(master_fd);
        if (error_pipe[0] >= 0) close(error_pipe[0]);
        if (error_pipe[1] >= 0) close(error_pipe[1]);
        pthread_mutex_unlock(&spawn_lock);
        errno = saved;
        return -1;
    }
}

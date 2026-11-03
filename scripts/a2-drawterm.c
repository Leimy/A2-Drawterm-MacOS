/* Launch the native A2 image and drawterm over their private 9P socket. */
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static pid_t a2_pid = -1, drawterm_pid = -1;

static void stop(int signal_number) {
    (void)signal_number;
    stopping = 1;
    if (a2_pid > 0) kill(a2_pid, SIGTERM);
    if (drawterm_pid > 0) kill(drawterm_pid, SIGTERM);
}

static void path(char *result, size_t capacity, const char *dir, const char *name) {
    int length = snprintf(result, capacity, "%s/%s", dir, name);
    if (length < 0 || (size_t)length >= capacity) {
        fprintf(stderr, "A2 resource path is too long\n");
        exit(2);
    }
}

static void reap(pid_t child) {
    int status;
    if (child <= 0) return;
    for (int i = 0; i < 20; ++i) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) return;
        if (result < 0 && errno != EINTR) break;
        usleep(100000);
    }
    kill(child, SIGKILL);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
}

int main(int argc, char **argv) {
    char executable[PATH_MAX], directory[PATH_MAX], working_directory[PATH_MAX];
    char loader[PATH_MAX], core[PATH_MAX], drawterm[PATH_MAX], data[PATH_MAX];
    char descriptor[32];
    uint32_t length = sizeof(executable);
    int sockets[2], status;
    pid_t finished;
    const char *old_path;
    char *search_path;

    if (argc > 1) {
        fprintf(stderr, "Usage: %s\n", argv[0]);
        return argc == 2 && strcmp(argv[1], "--help") == 0 ? 0 : 2;
    }
    if (_NSGetExecutablePath(executable, &length) != 0 ||
        realpath(executable, directory) == NULL) {
        perror("locate A2 launcher");
        return 2;
    }
    char *slash = strrchr(directory, '/');
    if (slash == NULL) return 2;
    *slash = '\0';
    path(loader, sizeof(loader), directory, "OberonLoader");
    path(core, sizeof(core), directory, "DarwinAosDrawtermDesktopAa");
    path(drawterm, sizeof(drawterm), directory, "drawterm");
    path(data, sizeof(data), directory, "data");
    if (getcwd(working_directory, sizeof(working_directory)) == NULL) {
        perror("locate A2 working directory");
        return 2;
    }
    if (access(loader, X_OK) || access(drawterm, X_OK) || access(core, R_OK)) {
        fprintf(stderr, "A2 bundle is incomplete: expected OberonLoader, drawterm, and DarwinAosDrawtermDesktopAa beside %s\n", argv[0]);
        return 2;
    }
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) {
        perror("socketpair");
        return 2;
    }
    old_path = getenv("AOSPATH");
    search_path = malloc(strlen(directory) + strlen(data) + strlen(working_directory) +
                         (old_path ? strlen(old_path) : 0) + 5);
    if (search_path == NULL) return 2;
    sprintf(search_path, "%s:%s:%s%s%s", directory, working_directory, data,
            old_path && *old_path ? ":" : "", old_path ? old_path : "");
    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    signal(SIGHUP, stop);

    drawterm_pid = fork();
    if (drawterm_pid == 0) {
        setpgid(0, 0);
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        close(sockets[0]);
        if (dup2(sockets[1], STDIN_FILENO) < 0 ||
            dup2(sockets[1], STDOUT_FILENO) < 0) _exit(127);
        if (sockets[1] > STDERR_FILENO) close(sockets[1]);
        execl(drawterm, drawterm, "-D", (char *)NULL);
        perror("exec drawterm");
        _exit(127);
    }
    if (drawterm_pid < 0) {
        perror("fork drawterm");
        close(sockets[0]); close(sockets[1]);
        return 2;
    }
    a2_pid = fork();
    if (a2_pid == 0) {
        setpgid(0, 0);
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        close(sockets[1]);
        snprintf(descriptor, sizeof(descriptor), "%d", sockets[0]);
        setenv("OBERON_CORE", core, 1);
        setenv("A2_DRAWTERM_FD", descriptor, 1);
        setenv("AOSPATH", search_path, 1);
        execl(loader, loader, (char *)NULL);
        perror("exec OberonLoader");
        _exit(127);
    }
    close(sockets[0]); close(sockets[1]);
    if (a2_pid < 0) {
        perror("fork OberonLoader");
        stop(SIGTERM);
        reap(drawterm_pid);
        return 2;
    }
    do { finished = waitpid(-1, &status, 0); }
    while (finished < 0 && errno == EINTR && !stopping);
    int result = 0;
    if (!stopping && finished == a2_pid) {
        result = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        if (result != 0) fprintf(stderr, "A2 loader exited with status %d\n", result);
        kill(drawterm_pid, SIGTERM);
        reap(drawterm_pid);
    } else if (!stopping && finished == drawterm_pid) {
        result = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        if (result != 0) fprintf(stderr, "drawterm exited with status %d (is another A2 drawterm window open?)\n", result);
        kill(a2_pid, SIGTERM);
        reap(a2_pid);
    } else {
        stop(SIGTERM);
        reap(a2_pid);
        reap(drawterm_pid);
    }
    free(search_path);
    return result;
}

/*
 * icekast-launch: tiny supervisor run by launchd (see com.macinmind.icekast.server.plist).
 *
 * - launchd plists can't expand "~", so this resolves the per-user config path itself.
 * - It runs icecast and, next to it, icekast-feeder (which streams backup audio at normal
 *   speed). If the feeder dies it is restarted; if icecast dies the whole job ends so launchd
 *   restarts everything (KeepAlive).
 * - SIGHUP (config reload) is forwarded to icecast; SIGTERM/SIGINT stop both children.
 */
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t terminating = 0;
static volatile pid_t ice_pid = 0, feeder_pid = 0;

static void on_signal(int sig) {
    if (sig == SIGHUP) { if (ice_pid > 0) kill(ice_pid, SIGHUP); return; }
    terminating = 1;
    if (ice_pid > 0) kill(ice_pid, sig);
    if (feeder_pid > 0) kill(feeder_pid, sig);
}

static pid_t spawn(const char *path, char *const argv[]) {
    pid_t pid = fork();
    if (pid == 0) {
        execv(path, argv);
        perror("icekast-launch: exec");
        _exit(127);
    }
    return pid;
}

int main(void) {
    char self[PATH_MAX]; uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0) { fputs("icekast-launch: path too long\n", stderr); return 1; }
    char *slash = strrchr(self, '/');
    if (!slash) return 1;
    *slash = '\0';

    char icecast[PATH_MAX], feeder[PATH_MAX];
    snprintf(icecast, sizeof(icecast), "%s/icecast", self);
    snprintf(feeder, sizeof(feeder), "%s/icekast-feeder", self);

    const char *home = getenv("HOME");
    if (!home || !*home) { struct passwd *pw = getpwuid(getuid()); home = pw ? pw->pw_dir : NULL; }
    if (!home) { fputs("icekast-launch: no home directory\n", stderr); return 1; }

    char support[PATH_MAX], config[PATH_MAX];
    snprintf(support, sizeof(support), "%s/Library/Application Support/iceKast", home);
    snprintf(config, sizeof(config), "%s/icecast.xml", support);
    if (chdir(support) != 0) { perror("icekast-launch: chdir"); return 1; }

    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    char *ice_args[] = { "icecast", "-c", config, NULL };
    ice_pid = spawn(icecast, ice_args);
    if (ice_pid < 0) { perror("icekast-launch: fork"); return 1; }

    char *feeder_args[] = { "icekast-feeder", NULL };
    int have_feeder = access(feeder, X_OK) == 0;
    if (have_feeder) feeder_pid = spawn(feeder, feeder_args);

    for (;;) {
        int st = 0;
        pid_t p = waitpid(-1, &st, 0);
        if (p < 0) { if (errno == EINTR) continue; break; }
        if (p == ice_pid) {
            ice_pid = 0;
            if (feeder_pid > 0) { kill(feeder_pid, SIGTERM); waitpid(feeder_pid, NULL, 0); feeder_pid = 0; }
            if (terminating) return 0;
            return WIFEXITED(st) ? WEXITSTATUS(st) : 1;       // a crash is a failure: launchd restarts us
        }
        if (p == feeder_pid) {
            feeder_pid = 0;
            if (!terminating && have_feeder && ice_pid > 0) {
                usleep(1000000);                                // don't spin if it keeps failing
                if (!terminating && ice_pid > 0) feeder_pid = spawn(feeder, feeder_args);
            }
        }
    }
    return 0;
}

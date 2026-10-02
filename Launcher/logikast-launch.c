/*
 * logikast-launch: tiny supervisor run by launchd (see com.macinmind.logikast.server.plist).
 *
 * - launchd plists can't expand "~", so this resolves the per-user config path itself.
 * - It runs icecast and, next to it, logikast-feeder (which streams backup audio at normal
 *   speed). If the feeder dies it is restarted; if icecast dies the whole job ends so launchd
 *   restarts everything (KeepAlive).
 * - SIGHUP (config reload) is forwarded to icecast; SIGTERM/SIGINT stop both children.
 * - Before starting, any icecast or feeder left over from an earlier run (same config) is stopped, because a
 *   leftover icecast still holds the port and the new one could not listen.
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
        perror("logikast-launch: exec");
        _exit(127);
    }
    return pid;
}

/* Runs /usr/bin/pkill; with full_command_line=0 it matches only orphaned processes by name (never a live server's
 * own feeder). Returns true if it signalled something. */
static int pkill_matching(const char *signal_name, const char *pattern, int full_command_line) {
    pid_t pid = fork();
    if (pid == 0) {
        if (full_command_line) execl("/usr/bin/pkill", "pkill", signal_name, "-f", pattern, (char *)NULL);
        else execl("/usr/bin/pkill", "pkill", signal_name, "-P", "1", "-x", pattern, (char *)NULL);   /* only orphans (parent launchd) */
        _exit(127);
    }
    if (pid < 0) return 0;
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) && WEXITSTATUS(st) == 0;
}

static void stop_leftovers(const char *config) {
    char pattern[PATH_MAX + 32];
    snprintf(pattern, sizeof(pattern), "icecast -c %s", config);
    int found = pkill_matching("-TERM", pattern, 1);
    found |= pkill_matching("-TERM", "logikast-feeder", 0);
    if (!found) return;
    usleep(1500000);                                  /* give them time to close their sockets */
    pkill_matching("-KILL", pattern, 1);
    pkill_matching("-KILL", "logikast-feeder", 0);
    usleep(300000);
}

int main(void) {
    char self[PATH_MAX]; uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0) { fputs("logikast-launch: path too long\n", stderr); return 1; }
    char *slash = strrchr(self, '/');
    if (!slash) return 1;
    *slash = '\0';

    char icecast[PATH_MAX], feeder[PATH_MAX];
    snprintf(icecast, sizeof(icecast), "%s/icecast", self);
    snprintf(feeder, sizeof(feeder), "%s/logikast-feeder", self);

    const char *home = getenv("HOME");
    if (!home || !*home) { struct passwd *pw = getpwuid(getuid()); home = pw ? pw->pw_dir : NULL; }
    if (!home) { fputs("logikast-launch: no home directory\n", stderr); return 1; }

    char support[PATH_MAX], config[PATH_MAX];
    snprintf(support, sizeof(support), "%s/Library/Application Support/LogiKast", home);
    snprintf(config, sizeof(config), "%s/icecast.xml", support);
    if (chdir(support) != 0) { perror("logikast-launch: chdir"); return 1; }

    stop_leftovers(config);

    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    char *ice_args[] = { "icecast", "-c", config, NULL };
    ice_pid = spawn(icecast, ice_args);
    if (ice_pid < 0) { perror("logikast-launch: fork"); return 1; }

    char *feeder_args[] = { "logikast-feeder", NULL };
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

/*
 * icekast-launch: tiny launcher run by launchd (see com.macinmind.icekast.server.plist).
 * launchd plists can't expand "~", so this resolves the per-user config path and then
 * exec()s the bundled icecast next to it. exec keeps launchd supervising icecast itself.
 */
#include <mach-o/dyld.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    char self[PATH_MAX]; uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0) { fputs("icekast-launch: path too long\n", stderr); return 1; }
    char *slash = strrchr(self, '/');
    if (!slash) return 1;
    *slash = '\0';

    char icecast[PATH_MAX];
    snprintf(icecast, sizeof(icecast), "%s/icecast", self);

    const char *home = getenv("HOME");
    if (!home || !*home) { struct passwd *pw = getpwuid(getuid()); home = pw ? pw->pw_dir : NULL; }
    if (!home) { fputs("icekast-launch: no home directory\n", stderr); return 1; }

    char support[PATH_MAX], config[PATH_MAX];
    snprintf(support, sizeof(support), "%s/Library/Application Support/iceKast", home);
    snprintf(config, sizeof(config), "%s/icecast.xml", support);
    if (chdir(support) != 0) { perror("icekast-launch: chdir"); return 1; }

    char *args[] = { "icecast", "-c", config, NULL };
    execv(icecast, args);
    perror("icekast-launch: exec icecast");
    return 1;
}

#include <ctype.h>
#include <dirent.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Limit on the descendants listed for one shell, guards against a fork bomb */
#define MAX_DESCENDANTS 1000

struct proc_stat {
    long pid, session, tty, tpgid;
};

/* Reads /proc/<pid>/stat into buf, returns 0 if the process doesn't exist */
static int read_stat(long pid, char *buf, size_t size, struct proc_stat *stat) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%ld/stat", pid);
    FILE *fp = fopen(path, "r");
    if (fp == NULL) return 0;
    size_t len = fread(buf, 1, size - 2, fp);
    fclose(fp);
    if (len == 0) return 0;
    buf[len] = 0;
    if (buf[len - 1] != '\n') {
        buf[len] = '\n';
        buf[len + 1] = 0;
    }
    /* The name is in parentheses and may contain anything, fields follow the last ')' */
    char *rpar = strrchr(buf, ')');
    if (rpar == NULL) return 0;
    char state;
    long ppid, pgrp;
    if (sscanf(rpar + 1, " %c %ld %ld %ld %ld %ld", &state, &ppid, &pgrp,
               &stat->session, &stat->tty, &stat->tpgid) != 6) return 0;
    stat->pid = pid;
    return 1;
}

/* Appends the children of every thread of pid to children, returns -1 if the
   kernel doesn't provide the children files */
static int add_children(long pid, long *children, int *count, int max) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%ld/task", pid);
    DIR *tasks = opendir(path);
    if (tasks == NULL) return 0; /* exited */
    struct dirent *task;
    int supported = 1;
    while ((task = readdir(tasks)) != NULL) {
        if (!isdigit((unsigned char)task->d_name[0])) continue;
        char file[320];
        snprintf(file, sizeof(file), "/proc/%ld/task/%s/children", pid, task->d_name);
        FILE *fp = fopen(file, "r");
        if (fp == NULL) {
            if (access(file, F_OK) != 0 && access(path, F_OK) == 0) supported = 0;
            continue;
        }
        long child;
        while (*count < max && fscanf(fp, "%ld", &child) == 1) children[(*count)++] = child;
        fclose(fp);
    }
    closedir(tasks);
    return supported ? 0 : -1;
}

/* Prints the stat of every process in session except the shell, used without the children files */
static void list_session(long shell, long session) {
    DIR *proc = opendir("/proc");
    if (proc == NULL) return;
    struct dirent *entry;
    char buf[4096];
    struct proc_stat stat;
    while ((entry = readdir(proc)) != NULL) {
        if (!isdigit((unsigned char)entry->d_name[0])) continue;
        long pid = strtol(entry->d_name, NULL, 10);
        if (pid == shell) continue;
        if (read_stat(pid, buf, sizeof(buf), &stat) && stat.session == session) fputs(buf, stdout);
    }
    closedir(proc);
}

/* Prints the stat line of each shell and its descendants in the shell's session,
   one per line. This is the host side of the Flatpak process monitor and mirrors
   ProcFsSource.snapshot in source/gx/tilix/terminal/activeprocess.d. */
static int list_sessions(int count, char **shells) {
    static long queue[MAX_DESCENDANTS + 1];
    static long children[MAX_DESCENDANTS * 4];
    char buf[4096];
    for (int i = 0; i < count; i++) {
        long shell = strtol(shells[i], NULL, 10);
        struct proc_stat stat;
        if (shell <= 0 || !read_stat(shell, buf, sizeof(buf), &stat)) continue;
        fputs(buf, stdout);
        /* Without a terminal nothing in the session is in the foreground */
        if (stat.tty == 0 || stat.tpgid <= 0) continue;
        long session = stat.session;
        int head = 0, tail = 0, listed = 0, fallback = 0;
        queue[tail++] = shell;
        while (head < tail && listed < MAX_DESCENDANTS) {
            int n = 0;
            if (add_children(queue[head++], children, &n, MAX_DESCENDANTS * 4) < 0) {
                fallback = 1;
                break;
            }
            for (int c = 0; c < n && listed < MAX_DESCENDANTS; c++) {
                int seen = 0;
                for (int q = 0; q < tail; q++) if (queue[q] == children[c]) seen = 1;
                if (seen) continue;
                /* Children that exited or started their own session aren't part of this terminal */
                if (!read_stat(children[c], buf, sizeof(buf), &stat) || stat.session != session) continue;
                fputs(buf, stdout);
                queue[tail++] = children[c];
                listed++;
            }
        }
        if (fallback) list_session(shell, session);
    }
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "list-sessions") == 0) {
        return list_sessions(argc - 2, argv + 2);
    }

    if (argc != 3) {
        fprintf(stderr, "usage: tilix-flatpak-toolbox <command> <arg>\n"
                        "       tilix-flatpak-toolbox list-sessions <pid>...\n");
        return 1;
    }

    if (strcmp(argv[1], "get-passwd") == 0) {
        execlp("getent", "getent", "passwd", argv[2], NULL);
        perror("error calling execlp");
        return 1;
    } else if (strcmp(argv[1], "get-child-pid") == 0) {
        // Caller should have saved terminal to fd 3.
        pid_t pid = tcgetpgrp(3);
        if (pid == -1) {
            perror("error calling tcgetpgrp");
            return 1;
        }

        printf("%ld\n", (long)pid);
    } else if (strcmp(argv[1], "get-proc-stat") == 0) {
        long value = strtol(argv[2], NULL, 10);
        char path[32];
        snprintf(path, sizeof(path), "/proc/%lu/stat", value);

        FILE *fp = fopen(path, "r");
        if (fp == NULL) {
            perror("error opening /proc/<pid>/stat");
            return 1;
        }

        for (;;) {
            char buf[1024];
            int sz = fread(buf, 1, sizeof(buf)-1, fp);
            buf[sz] = 0;

            printf("%s", buf);

            if (sz < sizeof(buf)) {
                if (feof(fp)) {
                    break;
                } else if (ferror(fp)) {
                    perror("error reading from /proc/<pid>/stat");
                    fclose(fp);
                    return 1;
                }
            }
        }

        fclose(fp);
        fflush(stdout);
    } else {
        fprintf(stderr, "Invalid command: %s\n", argv[1]);
        return 1;
    }

    return 0;
}

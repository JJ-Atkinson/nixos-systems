/*
 * keycount-daemon — count key presses only (no keylogging).
 * Reads evdev keyboards (prefers "keyd virtual keyboard"), writes:
 *   $XDG_DATA_HOME/keycount/stats.json
 *
 * Buckets:
 *   keys    — typing (shift ok)
 *   spaces  — space while typing
 *   chords  — key while ctrl/alt/super held
 *   mods    — bare modifier presses
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MAX_DEVS 64
#define MAX_DAYS 400
#define RESCAN_MS 5000
#define SAVE_MS 3000

struct day {
    char date[16];
    uint64_t keys, spaces, chords, mods;
};

struct state {
    struct day days[MAX_DAYS];
    int ndays;
    char today[16];
    int today_idx;
    bool dirty;
};

static struct state g;
static volatile sig_atomic_t g_run = 1;

static void on_signal(int sig) {
    (void)sig;
    g_run = 0;
}

static void today_str(char out[16]) {
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(out, 16, "%Y-%m-%d", &tm);
}

static int find_day(const char *date) {
    for (int i = 0; i < g.ndays; i++) {
        if (strcmp(g.days[i].date, date) == 0)
            return i;
    }
    return -1;
}

static int ensure_today(void) {
    char now[16];
    today_str(now);
    if (g.today_idx >= 0 && strcmp(g.today, now) == 0)
        return g.today_idx;

    strncpy(g.today, now, sizeof(g.today));
    int idx = find_day(now);
    if (idx < 0) {
        if (g.ndays >= MAX_DAYS) {
            /* drop oldest */
            memmove(&g.days[0], &g.days[1], sizeof(g.days[0]) * (MAX_DAYS - 1));
            g.ndays = MAX_DAYS - 1;
        }
        idx = g.ndays++;
        memset(&g.days[idx], 0, sizeof(g.days[idx]));
        strncpy(g.days[idx].date, now, sizeof(g.days[idx].date));
    }
    g.today_idx = idx;
    return idx;
}

static void data_paths(char *dir, size_t dlen, char *file, size_t flen) {
    const char *xdg = getenv("XDG_DATA_HOME");
    const char *home = getenv("HOME");
    if (xdg && xdg[0])
        snprintf(dir, dlen, "%s/keycount", xdg);
    else if (home && home[0])
        snprintf(dir, dlen, "%s/.local/share/keycount", home);
    else
        snprintf(dir, dlen, "/tmp/keycount");
    snprintf(file, flen, "%s/stats.json", dir);
}

static void load_stats(void) {
    char dir[PATH_MAX], path[PATH_MAX];
    data_paths(dir, sizeof(dir), path, sizeof(path));
    FILE *f = fopen(path, "r");
    if (!f)
        return;
    char buf[1 << 16];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;

    /* crude scan: "YYYY-MM-DD" ... "keys": N ... */
    for (char *p = buf; *p; p++) {
        if (p[0] == '"' && p[5] == '-' && p[8] == '-' && p[11] == '"') {
            char date[16];
            if (sscanf(p, "\"%10[0-9-]\"", date) != 1)
                continue;
            if (strlen(date) != 10)
                continue;
            char *block = strchr(p, '{');
            if (!block)
                continue;
            char *end = strchr(block, '}');
            if (!end)
                continue;
            uint64_t keys = 0, spaces = 0, chords = 0, mods = 0;
            char tmp = *end;
            *end = 0;
            char *k;
            if ((k = strstr(block, "\"keys\"")))
                sscanf(k, "\"keys\"%*[^0-9]%lu", &keys);
            if ((k = strstr(block, "\"spaces\"")))
                sscanf(k, "\"spaces\"%*[^0-9]%lu", &spaces);
            if ((k = strstr(block, "\"chords\"")))
                sscanf(k, "\"chords\"%*[^0-9]%lu", &chords);
            if ((k = strstr(block, "\"mods\"")))
                sscanf(k, "\"mods\"%*[^0-9]%lu", &mods);
            *end = tmp;

            if (find_day(date) >= 0)
                continue;
            if (g.ndays >= MAX_DAYS)
                continue;
            int idx = g.ndays++;
            strncpy(g.days[idx].date, date, sizeof(g.days[idx].date));
            g.days[idx].keys = keys;
            g.days[idx].spaces = spaces;
            g.days[idx].chords = chords;
            g.days[idx].mods = mods;
            p = end;
        }
    }
    g.today_idx = -1;
    ensure_today();
}

static int cmp_day(const void *a, const void *b) {
    return strcmp(((const struct day *)a)->date, ((const struct day *)b)->date);
}

static void save_stats(void) {
    if (!g.dirty)
        return;
    char dir[PATH_MAX], path[PATH_MAX], tmp[PATH_MAX + 8];
    data_paths(dir, sizeof(dir), path, sizeof(path));
    mkdir(dir, 0755);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);

    qsort(g.days, g.ndays, sizeof(g.days[0]), cmp_day);

    FILE *f = fopen(tmp, "w");
    if (!f)
        return;
    fputs("{\n", f);
    for (int i = 0; i < g.ndays; i++) {
        fprintf(f,
                "  \"%s\": {\"keys\": %lu, \"spaces\": %lu, \"chords\": %lu, \"mods\": %lu}%s\n",
                g.days[i].date, (unsigned long)g.days[i].keys,
                (unsigned long)g.days[i].spaces, (unsigned long)g.days[i].chords,
                (unsigned long)g.days[i].mods, i + 1 < g.ndays ? "," : "");
    }
    fputs("}\n", f);
    fclose(f);
    if (rename(tmp, path) == 0)
        g.dirty = false;
}

static bool is_keyboard(int fd) {
    unsigned long ev_bits[(EV_MAX + 1 + (sizeof(long) * 8) - 1) / (sizeof(long) * 8)];
    unsigned long key_bits[(KEY_MAX + 1 + (sizeof(long) * 8) - 1) / (sizeof(long) * 8)];
    memset(ev_bits, 0, sizeof(ev_bits));
    memset(key_bits, 0, sizeof(key_bits));
    if (ioctl(fd, EVIOCGBIT(0, sizeof(ev_bits)), ev_bits) < 0)
        return false;
    if (!(ev_bits[EV_KEY / (sizeof(long) * 8)] & (1UL << (EV_KEY % (sizeof(long) * 8)))))
        return false;
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key_bits)), key_bits) < 0)
        return false;
    /* Prefer real letter keys — filters pure power buttons etc. */
    int has_a = key_bits[KEY_A / (sizeof(long) * 8)] & (1UL << (KEY_A % (sizeof(long) * 8)));
    int has_enter = key_bits[KEY_ENTER / (sizeof(long) * 8)] & (1UL << (KEY_ENTER % (sizeof(long) * 8)));
    return has_a || has_enter;
}

static bool name_is_keyd(int fd) {
    char name[256];
    memset(name, 0, sizeof(name));
    if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0)
        return false;
    return strstr(name, "keyd virtual keyboard") != NULL;
}

struct dev {
    int fd;
    char path[PATH_MAX];
};

static int open_keyboards(struct dev *devs, int max, bool *used_keyd) {
    *used_keyd = false;
    struct dev keyd_only[MAX_DEVS];
    int n_keyd = 0, n_all = 0;
    struct dev all[MAX_DEVS];

    DIR *d = opendir("/dev/input");
    if (!d)
        return 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strncmp(ent->d_name, "event", 5) != 0)
            continue;
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0)
            continue;
        if (!is_keyboard(fd)) {
            close(fd);
            continue;
        }
        /* Don't grab — observe only */
        if (name_is_keyd(fd)) {
            if (n_keyd < max) {
                keyd_only[n_keyd].fd = fd;
                strncpy(keyd_only[n_keyd].path, path, sizeof(keyd_only[n_keyd].path));
                n_keyd++;
            } else {
                close(fd);
            }
        } else {
            if (n_all < max) {
                all[n_all].fd = fd;
                strncpy(all[n_all].path, path, sizeof(all[n_all].path));
                n_all++;
            } else {
                close(fd);
            }
        }
    }
    closedir(d);

    /* Prefer keyd virtual keyboard only (avoids double-count + keyd-grabbed ghosts). */
    if (n_keyd > 0) {
        for (int i = 0; i < n_all; i++)
            close(all[i].fd);
        int n = n_keyd < max ? n_keyd : max;
        memcpy(devs, keyd_only, sizeof(devs[0]) * n);
        for (int i = n; i < n_keyd; i++)
            close(keyd_only[i].fd);
        *used_keyd = true;
        return n;
    }

    int n = n_all < max ? n_all : max;
    memcpy(devs, all, sizeof(devs[0]) * n);
    for (int i = n; i < n_all; i++)
        close(all[i].fd);
    return n;
}

static void close_devs(struct dev *devs, int n) {
    for (int i = 0; i < n; i++) {
        if (devs[i].fd >= 0)
            close(devs[i].fd);
        devs[i].fd = -1;
    }
}

/* Modifier state */
static bool ctrl_down, alt_down, super_down, shift_down;

static bool is_mod_code(uint16_t code) {
    switch (code) {
    case KEY_LEFTCTRL:
    case KEY_RIGHTCTRL:
    case KEY_LEFTALT:
    case KEY_RIGHTALT:
    case KEY_LEFTMETA:
    case KEY_RIGHTMETA:
    case KEY_LEFTSHIFT:
    case KEY_RIGHTSHIFT:
    case KEY_CAPSLOCK:
    case KEY_NUMLOCK:
    case KEY_SCROLLLOCK:
        return true;
    default:
        return false;
    }
}

static void set_mod(uint16_t code, bool down) {
    switch (code) {
    case KEY_LEFTCTRL:
    case KEY_RIGHTCTRL:
        ctrl_down = down;
        break;
    case KEY_LEFTALT:
    case KEY_RIGHTALT:
        alt_down = down;
        break;
    case KEY_LEFTMETA:
    case KEY_RIGHTMETA:
        super_down = down;
        break;
    case KEY_LEFTSHIFT:
    case KEY_RIGHTSHIFT:
        shift_down = down;
        break;
    default:
        break;
    }
}

static void handle_key(uint16_t code, int32_t value) {
    /* value: 0 release, 1 press, 2 repeat */
    if (value == 2)
        return;

    if (is_mod_code(code)) {
        if (value == 1) {
            int idx = ensure_today();
            g.days[idx].mods++;
            g.dirty = true;
        }
        set_mod(code, value == 1);
        return;
    }

    if (value != 1)
        return;

    int idx = ensure_today();
    bool chord = ctrl_down || alt_down || super_down;
    if (chord) {
        g.days[idx].chords++;
    } else {
        g.days[idx].keys++;
        if (code == KEY_SPACE)
            g.days[idx].spaces++;
    }
    g.dirty = true;
    (void)shift_down;
}

int main(void) {
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    memset(&g, 0, sizeof(g));
    g.today_idx = -1;
    load_stats();
    ensure_today();

    struct dev devs[MAX_DEVS];
    int ndevs = 0;
    bool used_keyd = false;
    long last_scan = 0, last_save = 0;

    fprintf(stderr, "keycount-daemon: starting (stats in XDG_DATA_HOME/keycount)\n");

    while (g_run) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        long now_ms = ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;

        if (ndevs == 0 || now_ms - last_scan >= RESCAN_MS) {
            close_devs(devs, ndevs);
            ndevs = open_keyboards(devs, MAX_DEVS, &used_keyd);
            last_scan = now_ms;
            fprintf(stderr, "keycount-daemon: watching %d keyboard device(s)%s\n",
                    ndevs, used_keyd ? " [keyd]" : "");
        }

        if (ndevs == 0) {
            usleep(500000);
            continue;
        }

        struct pollfd pfds[MAX_DEVS];
        for (int i = 0; i < ndevs; i++) {
            pfds[i].fd = devs[i].fd;
            pfds[i].events = POLLIN;
            pfds[i].revents = 0;
        }

        int pr = poll(pfds, ndevs, 200);
        if (pr < 0) {
            if (errno == EINTR)
                continue;
            break;
        }

        for (int i = 0; i < ndevs; i++) {
            if (!(pfds[i].revents & POLLIN)) {
                if (pfds[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
                    close(devs[i].fd);
                    devs[i].fd = -1;
                }
                continue;
            }
            for (;;) {
                struct input_event ev;
                ssize_t r = read(devs[i].fd, &ev, sizeof(ev));
                if (r < 0) {
                    if (errno == EAGAIN || errno == EWOULDBLOCK)
                        break;
                    close(devs[i].fd);
                    devs[i].fd = -1;
                    break;
                }
                if (r != (ssize_t)sizeof(ev))
                    break;
                if (ev.type == EV_KEY)
                    handle_key(ev.code, ev.value);
            }
        }

        /* compact closed fds on next rescan */
        clock_gettime(CLOCK_MONOTONIC, &ts);
        now_ms = ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
        if (g.dirty && now_ms - last_save >= SAVE_MS) {
            save_stats();
            last_save = now_ms;
        }
    }

    save_stats();
    close_devs(devs, ndevs);
    fprintf(stderr, "keycount-daemon: exit\n");
    return 0;
}

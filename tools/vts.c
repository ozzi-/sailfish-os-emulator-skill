/* vts - Virtual Touch Screen + Mouse daemon for Sailfish OS SDK emulator
 *
 * Why this exists:
 *   The SDK image runs `lipstick -plugin VBoxTouch`. That plugin only accepts:
 *     a) /dev/vboxguest (host->guest channel, needs VirtualBox COM mouse inject)
 *     b) the evdev mouse at /dev/input/by-path/platform-i8042-serio-1-event-mouse
 *        AND it requires ABSOLUTE coordinates (the built-in i8042 mouse is
 *        RELATIVE, so the plugin rejects it: "need absolute coordinates").
 *   This daemon creates uinput devices so path (b) works:
 *     - "vts-touch" : ABS_MT protocol B touchscreen (for tklock swipe etc.)
 *     - "vts-mouse" : ABS_X/ABS_Y + BTN_LEFT mouse (what vboxtouch plugin wants)
 *   You must then point the by-path symlink at the mouse device and hide
 *   /dev/vboxguest so the plugin falls back to the evdev path (see setup).
 *
 *   Commands (one per line in /tmp/vts.cmd, file is consumed):
 *     tap X Y                     touch tap (UI coords 0..1023 x 0..767)
 *     swipe X0 Y0 X1 Y1 [STEPS]   touch swipe (default 25 steps)
 *     click X Y                   mouse click (FB coords 0..2047 x 0..1535)
 *     mmove X Y                   mouse move only
 *     down / up / move X Y        raw touch primitives
 *     quit                        destroy devices, exit
 *
 *   Status log: /tmp/vts.log
 *
 * Must run as root (needs /dev/uinput).
 *
 * BUILD (host, 32-bit guest target):
 *   gcc -m32 -march=i686 -O2 -o vts vts.c
 *   python3 patch_isa_note.py vts     # zeroes 'x86 ISA needed' note, see below
 *
 * NOTE on patch_isa_note.py: host multilib CRT objects inject a
 * .note.gnu.property demanding up to x86-64-v4; the guest 32-bit kernel
 * refuses to exec such binaries ("CPU ISA level is lower than required").
 * Zeroing the property makes the kernel's check pass (code needs only SSE2).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <linux/input.h>
#include <linux/uinput.h>

#ifndef UI_ABS_SETUP
#define UI_ABS_SETUP 0x40045540
#endif

/* Touch device coordinate space (matches 1024x768 screenshot space). */
static int g_xmax = 1023;
static int g_ymax = 767;
/* Mouse device coordinate space (VMSVGA framebuffer 2048x1536). */
static int g_mxmax = 2047;
static int g_mymax = 1535;

static int g_tfd = -1;  /* touch device fd (kept open for device lifetime) */
static int g_mfd = -1;  /* mouse device fd */
static int g_lastx = 512, g_lasty = 384;

static void logmsg(const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    FILE *f = fopen("/tmp/vts.log", "a");
    if (f) { fputs(buf, f); fclose(f); }
    fprintf(stderr, "%s", buf);
}

static int ev(int fd, unsigned type, unsigned code, int value) {
    struct input_event e;
    memset(&e, 0, sizeof e);
    e.type = type;
    e.code = code;
    e.value = value;
    if (write(fd, &e, sizeof e) != sizeof e) { logmsg("ev write failed: %s\n", strerror(errno)); return -1; }
    return 0;
}

static int set_abs(int fd, int code, int min, int max) {
    if (ioctl(fd, UI_SET_ABSBIT, code) < 0) return -1;
    struct uinput_abs_setup ua;
    memset(&ua, 0, sizeof ua);
    ua.code = code;
    ua.absinfo.minimum = min;
    ua.absinfo.maximum = max;
    ua.absinfo.fuzz = 0;
    ua.absinfo.flat = 0;
    if (ioctl(fd, UI_ABS_SETUP, &ua) < 0) return -1;
    return 0;
}

/* uinput destroys a device when the creating fd's refcount hits zero,
 * so the returned fd must stay open for the daemon's whole lifetime. */
static int create_device(const char *name, int touch) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) { logmsg("open /dev/uinput: %s\n", strerror(errno)); return -1; }

    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) goto fail;
    if (ioctl(fd, UI_SET_EVBIT, EV_ABS) < 0) goto fail;
    if (ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0) goto fail;

    if (touch) {
        if (ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH) < 0) goto fail;
        if (ioctl(fd, UI_SET_KEYBIT, BTN_0) < 0) goto fail;
        if (set_abs(fd, ABS_MT_TRACKING_ID, 0, 255) < 0) goto fail;
        if (set_abs(fd, ABS_MT_POSITION_X, 0, g_xmax) < 0) goto fail;
        if (set_abs(fd, ABS_MT_POSITION_Y, 0, g_ymax) < 0) goto fail;
        if (set_abs(fd, ABS_MT_PRESSURE, 0, 255) < 0) goto fail;
        if (set_abs(fd, ABS_X, 0, g_xmax) < 0) goto fail;
        if (set_abs(fd, ABS_Y, 0, g_ymax) < 0) goto fail;
    } else {
        if (ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0) goto fail;
        if (set_abs(fd, ABS_X, 0, g_mxmax) < 0) goto fail;
        if (set_abs(fd, ABS_Y, 0, g_mymax) < 0) goto fail;
    }

    {
        struct uinput_setup us;
        memset(&us, 0, sizeof us);
        strncpy(us.name, name, sizeof us.name - 1);
        if (ioctl(fd, UI_DEV_SETUP, &us) < 0) logmsg("UI_DEV_SETUP failed (non-fatal)\n");
    }
    if (ioctl(fd, UI_DEV_CREATE) < 0) { logmsg("UI_DEV_CREATE: %s\n", strerror(errno)); goto fail; }
    logmsg("created %s (fd %d)\n", name, fd);
    return fd;

fail:
    close(fd);
    return -1;
}

/* ---- touch (touchscreen) ---- */

static void touch_down(int x, int y) {
    ev(g_tfd, EV_KEY, BTN_TOUCH, 1);
    ev(g_tfd, EV_ABS, ABS_MT_TRACKING_ID, 1);
    ev(g_tfd, EV_ABS, ABS_MT_POSITION_X, x);
    ev(g_tfd, EV_ABS, ABS_MT_POSITION_Y, y);
    ev(g_tfd, EV_ABS, ABS_MT_PRESSURE, 120);
    ev(g_tfd, EV_ABS, ABS_X, x);
    ev(g_tfd, EV_ABS, ABS_Y, y);
    ev(g_tfd, EV_SYN, SYN_REPORT, 0);
}

static void touch_up(void) {
    ev(g_tfd, EV_ABS, ABS_MT_PRESSURE, 0);
    ev(g_tfd, EV_ABS, ABS_MT_TRACKING_ID, -1);
    ev(g_tfd, EV_KEY, BTN_TOUCH, 0);
    ev(g_tfd, EV_SYN, SYN_REPORT, 0);
}

static void do_tap(int x, int y) {
    touch_down(x, y);
    usleep(80000);
    touch_up();
    logmsg("tap %d %d\n", x, y);
}

static void do_swipe(int x0, int y0, int x1, int y1, int steps) {
    if (steps < 2) steps = 25;
    touch_down(x0, y0);
    for (int i = 1; i <= steps; i++) {
        int x = x0 + (x1 - x0) * i / steps;
        int y = y0 + (y1 - y0) * i / steps;
        ev(g_tfd, EV_ABS, ABS_MT_POSITION_X, x);
        ev(g_tfd, EV_ABS, ABS_MT_POSITION_Y, y);
        ev(g_tfd, EV_ABS, ABS_X, x);
        ev(g_tfd, EV_ABS, ABS_Y, y);
        ev(g_tfd, EV_SYN, SYN_REPORT, 0);
        usleep(15000);
    }
    usleep(40000);
    touch_up();
    logmsg("swipe %d %d -> %d %d (%d steps)\n", x0, y0, x1, y1, steps);
}

/* ---- mouse (absolute, what vboxtouch plugin reads) ---- */

static void mmove(int x, int y) {
    ev(g_mfd, EV_ABS, ABS_X, x);
    ev(g_mfd, EV_ABS, ABS_Y, y);
    ev(g_mfd, EV_SYN, SYN_REPORT, 0);
    logmsg("mmove %d %d\n", x, y);
}

static void do_click(int x, int y) {
    mmove(x, y);
    ev(g_mfd, EV_KEY, BTN_LEFT, 1);
    ev(g_mfd, EV_SYN, SYN_REPORT, 0);
    usleep(100000);
    ev(g_mfd, EV_KEY, BTN_LEFT, 0);
    ev(g_mfd, EV_SYN, SYN_REPORT, 0);
    logmsg("click %d %d\n", x, y);
}

/* Mouse press/release as separate commands so the caller can hold the
 * button DOWN across an external "kick" (the vboxtouch plugin only reports
 * a touch if BTN_LEFT is down at the moment it polls for the position).
 *   press   -> BTN_LEFT down, held (stays down until 'release')
 *   release -> BTN_LEFT up
 */
static void mpress(void) {
    ev(g_mfd, EV_KEY, BTN_LEFT, 1);
    ev(g_mfd, EV_SYN, SYN_REPORT, 0);
    logmsg("press (held)\n");
}
static void mrelease(void) {
    ev(g_mfd, EV_KEY, BTN_LEFT, 0);
    ev(g_mfd, EV_SYN, SYN_REPORT, 0);
    logmsg("release\n");
}

int main(int argc, char **argv) {
    if (argc > 1 && atoi(argv[1]) > 0) g_xmax = atoi(argv[1]) - 1;
    if (argc > 2 && atoi(argv[2]) > 0) g_ymax = atoi(argv[2]) - 1;
    if (argc > 3 && atoi(argv[3]) > 0) g_mxmax = atoi(argv[3]) - 1;
    if (argc > 4 && atoi(argv[4]) > 0) g_mymax = atoi(argv[4]) - 1;

    g_tfd = create_device("vts-touch", 1);
    if (g_tfd < 0) return 1;
    g_mfd = create_device("vts-mouse", 0);
    if (g_mfd < 0) return 1;

    /* command-file loop. NOTE: must read /tmp/vts.cmd by path.
     * mkstemp+rename does NOT work: the fd stays bound to the old empty inode. */
    for (;;) {
        int cfd = open("/tmp/vts.cmd", O_RDONLY);
        if (cfd >= 0) {
            /* SECURITY (see SECURITY.md §4): vts runs as root and injects UI
             * events, so only ROOT may command it. /tmp is world-writable;
             * without this check any guest process could inject taps/swipes
             * (e.g. punch a PIN) or 'quit' the daemon. Reject + delete. */
            {
                struct stat cst;
                if (fstat(cfd, &cst) == 0 && cst.st_uid != 0) {
                    close(cfd);
                    unlink("/tmp/vts.cmd");
                    logmsg("REJECTED /tmp/vts.cmd (uid=%d, must be root)\n", (int)cst.st_uid);
                    usleep(200000);
                    continue;
                }
            }
            char line[256] = {0};
            int n = read(cfd, line, sizeof line - 1);
            close(cfd);
            unlink("/tmp/vts.cmd");
            if (n > 0) {
                line[strcspn(line, "\r\n")] = 0;
                char cmd[16] = {0};
                int a = 0, b = 0, c = 0, d = 0;
                int steps = 25;
                if (sscanf(line, "%15s %d %d %d %d %d", cmd, &a, &b, &c, &d, &steps) >= 1) {
                    if (!strcmp(cmd, "tap") && b) {
                        do_tap(a, b);
                    } else if (!strcmp(cmd, "swipe") && d) {
                        do_swipe(a, b, c, d, steps);
                    } else if (!strcmp(cmd, "click") && b) {
                        do_click(a, b);
                    } else if (!strcmp(cmd, "mmove") && b) {
                        mmove(a, b);
                    } else if (!strcmp(cmd, "press") && b) {
                        mmove(a, b);
                        mpress();
                    } else if (!strcmp(cmd, "release") && b) {
                        mrelease();
                    } else if (!strcmp(cmd, "move") && b) {
                        g_lastx = a; g_lasty = b;
                        ev(g_tfd, EV_ABS, ABS_X, a); ev(g_tfd, EV_ABS, ABS_Y, b);
                        ev(g_tfd, EV_SYN, SYN_REPORT, 0);
                        logmsg("move %d %d\n", a, b);
                    } else if (!strcmp(cmd, "down")) {
                        touch_down(g_lastx, g_lasty);
                        logmsg("down\n");
                    } else if (!strcmp(cmd, "up")) {
                        touch_up();
                        logmsg("up\n");
                    } else if (!strcmp(cmd, "quit")) {
                        logmsg("quit\n");
                        if (g_tfd >= 0) ioctl(g_tfd, UI_DEV_DESTROY);
                        if (g_mfd >= 0) ioctl(g_mfd, UI_DEV_DESTROY);
                        return 0;
                    } else {
                        logmsg("unknown cmd: %s\n", cmd);
                    }
                }
            } else {
                logmsg("empty cmd\n");
            }
            continue; /* fast re-poll after processing a command */
        }
        usleep(200000); /* 200ms poll */
    }
    return 0;
}

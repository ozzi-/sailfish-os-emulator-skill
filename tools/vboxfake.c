/* libvboxfake.so — LD_PRELOAD shim: programmatic input position for the
 * Sailfish OS vboxtouch Qt plugin.
 *
 * WHY THIS EXISTS
 * ---------------
 * lipstick runs `-plugin VBoxTouch` (libvboxtouchplugin.so). The plugin:
 *   1. opens a vboxguest device (default /dev/vboxguest, overridable via env
 *      VIRTUALBOX_TOUCH_GUEST_DEVICE or plugin spec "vboxguest=<path>")
 *      with open(path, O_RDONLY | O_NONBLOCK)
 *   2. set_pointer_shape_ioctl(fd)   -> ioctl(fd, _IOC(RW,'V',3,size>36))
 *   3. ioctl(fd, _IOWR('V',15,28))   -> set mouse status (features)
 *   4. QSocketNotifier(fd, Read)     -> select()/poll() on the fd
 * on readiness:
 *   5. read(fd, &c, 1)               -> exactly 1 byte (EAGAIN tolerated)
 *   6. ioctl(fd, _IOWR('V',3,36))    -> GET mouse status -> x, y, features
 *      (requires features & VBOXMOUSE_IS_ABSOLUTE (0x2), else rejected)
 *   7. if a touch button is down (from the evdev mouse device, event7 =
 *      vts-mouse) it reports a touch at (m_x, m_y)
 *
 * The real /dev/vboxguest is a kernel misc device fed by VirtualBox's
 * host->guest channel, which we cannot feed programmatically (COM mouse
 * injection does not reach it in this setup). So this shim:
 *   - creates a FIFO at $VBOXFAKE_PATH (default /tmp/vboxfake)
 *   - keeps its read end open for the process lifetime
 *   - when the plugin open()s the fake path, hands it a dup of that read end
 *   - intercepts ioctl() on those fds:
 *       GET mouse status  0xC0245603 (_IOWR('V',3,36))
 *           -> fills the 36-byte struct from $VBOXFAKE_PATH.pos ("x y")
 *           -> features = 0x2 (VBOXMOUSE_IS_ABSOLUTE), rc = 0
 *       any other type-'V' ioctl (set shape, set mouse status) -> 0 (OK)
 *   - intercepts write() on those fds -> discarded (plugin opens O_RDONLY;
 *     safety net so a stray write can never block on a full FIFO buffer)
 *   - tracks dup()/close() of the fds it hands out
 *
 * TAP SEQUENCE (see tap.sh on the host):
 *   1. printf "%d %d" DX DY >  /tmp/vboxfake.pos    (DX,DY in 0..65535)
 *   2. printf x            > /tmp/vboxfake          (1-byte kick -> POLLIN
 *                                                    -> plugin step 5+6 above)
 *   3. sleep ~0.15                                                (event loop)
 *   4. echo "click 1 1"     > /tmp/vts.cmd            (vts daemon: BTN_LEFT
 *      down/up on event7 -> plugin reports Pressed then Released at (DX,DY))
 *
 * BUILD (host)
 * ------------
 *   standalone test (any arch):  gcc -O2 -o vfake_test vfake_test.c
 *                                 LD_PRELOAD=./libvboxfake.so ./vfake_test
 *   guest binary (i686):         gcc -m32 -march=i686 -shared -fPIC \
 *                                 -O2 -o libvboxfake.so vboxfake.c -ldl
 *                                 python3 patch_isa_note.py libvboxfake.so
 *
 * INSTALL (guest)
 * ---------------
 *   /usr/local/lib/libvboxfake.so
 *   lipstick env (systemd user unit drop-in, see KNOWHOW.md):
 *     VIRTUALBOX_TOUCH_GUEST_DEVICE=/tmp/vboxfake
 *     LD_PRELOAD=/usr/local/lib/libvboxfake.so
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <errno.h>

/* ioctl number layout (VERIFIED by disassembling the guest's
 * libvboxtouchplugin.so: "push 0xc0245603" before "call ioctl@plt"):
 *   bits 31-30: dir (3 = read/write)
 *   bits 29-16: size
 *   bits  15-8: type ('V' = 0x56)
 *   bits   7-0: nr
 * So GET mouse status  = _IOWR('V', 3,  struct36) = 0xC0245603
 *    set mouse status  = _IOWR('V', 15, struct28) = 0xC01C560F
 *    set pointer shape = _IOC(RW, 'V', 3,  size>36)  (variable size)
 * NOTE: this host's <asm-generic/ioctl.h> puts type/nr in these positions
 * (non-standard vs mainline), and the guest plugin agrees with it. We
 * hardcode the constants instead of trusting the cross-compile headers. */
#define VBOX_IOC_GET_MOUSE 0xC0245603UL
#define VBOX_COORD_MAX     65535
#define VBOXMOUSE_IS_ABSOLUTE 0x2u

static const char *g_dev = NULL;    /* fake device path (FIFO) */
static const char *g_pos = NULL;    /* position file path */
static int g_rfd = -1;              /* read end of the FIFO, held by us */
static int g_wfd = -1;              /* write end held open: keeps FIFO from
                                      ever seeing EOF (a real vboxguest char
                                      device never returns EOF; a sticky EOF
                                      makes the plugin's notifier spin forever) */
static int g_fds[128];              /* fds we have handed to the app */
static int g_nfds = 0;
static FILE *g_dbg = NULL;          /* debug log (file if VBOXFAKE_DEBUG) */

static void dbg(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    if (g_dbg) vfprintf(g_dbg, fmt, ap);
    else       vfprintf(stderr, fmt, ap);
    if (g_dbg) fflush(g_dbg);
    va_end(ap);
}

static int is_fake(int fd) {
    for (int i = 0; i < g_nfds; i++) if (g_fds[i] == fd) return 1;
    return 0;
}
static void track(int fd) { if (g_nfds < 128) g_fds[g_nfds++] = fd; }
static void untrack(int fd) {
    for (int i = 0; i < g_nfds; i++)
        if (g_fds[i] == fd) { g_fds[i] = g_fds[--g_nfds]; return; }
}

__attribute__((constructor))
static void vfake_init(void) {
    const char *p = getenv("VBOXFAKE_PATH");
    g_dev = p ? p : "/tmp/vboxfake";
    char buf[256];
    snprintf(buf, sizeof buf, "%s.pos", g_dev);
    g_pos = strdup(buf);
    mkfifo(g_dev, 0666);              /* EEXIST is fine */
    /* MUST bypass our own open() interposer: g_rfd is not valid yet, and
     * fake_open_hit() would dup(-1) and fail. */
    int (*real_open)(const char *, int, ...) = dlsym(RTLD_NEXT, "open");
    g_rfd = real_open(g_dev, O_RDONLY | O_NONBLOCK);
    if (g_rfd < 0) { g_dev = NULL; free((void *)g_pos); g_pos = NULL; }
    g_wfd = real_open(g_dev, O_WRONLY | O_NONBLOCK);   /* keep-alive writer */
    if (getenv("VBOXFAKE_DEBUG")) {
        const char *df = getenv("VBOXFAKE_DEBUG_FILE");
        if (!df) { snprintf(buf, sizeof buf, "%s.dbg", g_dev); df = buf; }
        int dfd = real_open(df, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (dfd >= 0) g_dbg = fdopen(dfd, "a");
    }
}

static int fake_open_hit(const char *path, int flags) {
    if (!g_dev || g_rfd < 0) return -1;   /* disabled -> real open() fallback */
    if (path && strcmp(path, g_dev) == 0) {
        /* Only the plugin's read-only opener gets our shared read end.
         * Writers (the 1-byte "kick") must reach the real FIFO. */
        if ((flags & O_ACCMODE) == O_RDONLY) {
            int fd = dup(g_rfd);
            if (fd >= 0) track(fd);
            return fd;
        }
    }
    return -1;
}

/* ---------- open family ---------- */
typedef int (*fn_open_t)(const char *, int, ...);
static fn_open_t R_open(void) { static fn_open_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "open"); return f; }

int open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    int fd = fake_open_hit(path, flags);
    if (fd >= 0) { dbg("[vboxfake] OPEN hit path=%s -> fake fd=%d\n", path, fd); return fd; }
    return R_open()(path, flags, mode);
}
int open64(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    int fd = fake_open_hit(path, flags);
    if (fd >= 0) return fd;
    static fn_open_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "open64");
    return f(path, flags, mode);
}

typedef int (*fn_openat_t)(int, const char *, int, ...);
int openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    if (path && (path[0] == '/' || dirfd == AT_FDCWD)) {
        int fd = fake_open_hit(path, flags);
        if (fd >= 0) return fd;
    }
    static fn_openat_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "openat");
    return f(dirfd, path, flags, mode);
}
int openat64(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    if (path && (path[0] == '/' || dirfd == AT_FDCWD)) {
        int fd = fake_open_hit(path, flags);
        if (fd >= 0) return fd;
    }
    static fn_openat_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "openat64");
    return f(dirfd, path, flags, mode);
}

/* ---------- ioctl ---------- */
typedef int (*fn_ioctl_t)(int, unsigned long, ...);
static fn_ioctl_t R_ioctl(void) { static fn_ioctl_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "ioctl"); return f; }

int ioctl(int fd, unsigned long req, ...) {
    void *arg = NULL;
    va_list ap; va_start(ap, req); arg = va_arg(ap, void *); va_end(ap);

    int fake = is_fake(fd);
    if (g_dbg && fake)
        dbg("[vboxfake] ioctl fd=%d req=0x%lx arg=%p\n",
            fd, (unsigned long)req, arg);

    if (fake) {
        unsigned char ioc_type = (unsigned char)((req >> 8) & 0xFF); /* 'V' slot */
        if (ioc_type == 'V') {
            if (req == VBOX_IOC_GET_MOUSE && arg) {
                /* struct vbox_mouse_status_request (36 bytes) */
                struct {
                    uint32_t size, version, type;
                    int32_t rc;
                    uint32_t reserved1, reserved2;
                    uint32_t features;
                    int32_t x, y;
                } *r = (typeof(r))arg;
                long x = VBOX_COORD_MAX / 2, y = VBOX_COORD_MAX / 2;
                FILE *pf = fopen(g_pos, "r");
                if (pf) {
                    /* SECURITY (SECURITY.md §4.1): only accept a ROOT-owned
                     * position file. /tmp is world-writable, so a non-root
                     * guest process (any app, uid defaultuser) could plant
                     * .pos to bias touch coordinates. The legitimate flow
                     * (tap.sh/swipe.sh) always writes .pos as root via SSH.
                     * Mirrors the vts.cmd root-only check in vts.c. */
                    struct stat pst;
                    int posok = (fstat(fileno(pf), &pst) == 0 && pst.st_uid == 0);
                    long a, b;
                    if (posok && fscanf(pf, "%ld %ld", &a, &b) == 2) { x = a; y = b; }
                    fclose(pf);
                }
                if (g_dbg) dbg("[vboxfake] GET -> x=%ld y=%ld\n", x, y);
                if (x < 0) x = 0;
                if (x > VBOX_COORD_MAX) x = VBOX_COORD_MAX;
                if (y < 0) y = 0;
                if (y > VBOX_COORD_MAX) y = VBOX_COORD_MAX;
                r->size = 36;
                r->version = 0x10001;
                r->type = 1;          /* type: get mouse status */
                r->rc = 0;
                r->reserved1 = 0;
                r->reserved2 = 0;
                r->features = VBOXMOUSE_IS_ABSOLUTE;
                r->x = (int32_t)x;
                r->y = (int32_t)y;
            }
            /* set pointer shape (V,3,size>36), set mouse status (V,15): succeed */
            return 0;
        }
    }
    return R_ioctl()(fd, req, arg);
}

/* ---------- write (safety: discard, never let it block on a full FIFO) ---------- */
typedef ssize_t (*fn_write_t)(int, const void *, size_t);
ssize_t write(int fd, const void *buf, size_t n) {
    if (is_fake(fd)) return (ssize_t)n;
    static fn_write_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "write");
    return f(fd, buf, n);
}

/* ---------- read (EOF guard + evdev visibility) ---------- */
typedef ssize_t (*fn_read_t)(int, void *, size_t);

/* Lazily classify fds: are they /dev/input/event* ? (cache result) */
#define FDCLS_MAX 512
enum { FDCLS_UNKNOWN = 0, FDCLS_NOEVDEV = 1, FDCLS_EVDEV = 2 };
static unsigned char fdcls[FDCLS_MAX];
static void classify_fd(int fd) {
    if (fdcls[fd]) return;
    char pth[64];
    snprintf(pth, sizeof pth, "/proc/self/fd/%d", fd);
    char link[256];
    ssize_t l = readlink(pth, link, sizeof link - 1);
    if (l <= 0 || strncmp(link, "/dev/input/event", 16) != 0)
        fdcls[fd] = FDCLS_NOEVDEV;
    else
        fdcls[fd] = FDCLS_EVDEV;
}

ssize_t read(int fd, void *buf, size_t n) {
    static fn_read_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "read");
    if (fd >= 0 && (unsigned)fd < FDCLS_MAX && !fdcls[fd]) classify_fd(fd);
    ssize_t r = f(fd, buf, n);
    if (is_fake(fd) && r == 0) { errno = EAGAIN; return -1; }  /* no EOF ever */
    if (g_dbg && (unsigned)fd < FDCLS_MAX && fdcls[fd] == FDCLS_EVDEV && r > 0)
        dbg("[vboxfake] READ evdev fd=%d ret=%ld\n", fd, (long)r);
    return r;
}

/* ---------- close / dup bookkeeping ---------- */
typedef int (*fn_close_t)(int);
int close(int fd) {
    static fn_close_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "close");
    int r = f(fd);
    untrack(fd);
    return r;
}

typedef int (*fn_dup_t)(int);
typedef int (*fn_dup2_t)(int, int);
typedef int (*fn_dup3_t)(int, int, int);
int dup(int oldfd) {
    static fn_dup_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "dup");
    int n = f(oldfd);
    if (n >= 0 && is_fake(oldfd)) track(n);
    return n;
}
int dup2(int oldfd, int newfd) {
    static fn_dup2_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "dup2");
    untrack(newfd);
    int n = f(oldfd, newfd);
    if (n >= 0 && is_fake(oldfd)) track(n);
    return n;
}
int dup3(int oldfd, int newfd, int flags) {
    static fn_dup3_t f = NULL; if (!f) f = dlsym(RTLD_NEXT, "dup3");
    untrack(newfd);
    int n = f(oldfd, newfd, flags);
    if (n >= 0 && is_fake(oldfd)) track(n);
    return n;
}

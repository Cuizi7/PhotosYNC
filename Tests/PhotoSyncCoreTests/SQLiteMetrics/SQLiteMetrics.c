// Test-host-only wrapper derived from work/backend-validation-20261006/idle-io/vfs.c.
// Every operation forwards its original result; only the named fixture and its
// SQLite sidecars contribute counters. This wrapper is linked only into the XCTest host, never the App.
#include "SQLiteMetrics.h"
#include <sqlite3.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static sqlite3_vfs *parent;
static sqlite3_vfs observer;
static char *target_path;
static int enabled;
static _Atomic uint64_t counters[8];
typedef struct {
    sqlite3_file base;
    sqlite3_io_methods methods;
    int tracked;
} ObservedFile;

static sqlite3_file *real(sqlite3_file *file) {
    return (sqlite3_file *)((char *)file + sizeof(ObservedFile));
}
static void count_io(sqlite3_file *file, int index, int bytes) {
    if (((ObservedFile *)file)->tracked) {
        atomic_fetch_add(&counters[index], 1);
        atomic_fetch_add(&counters[index + 1], (uint64_t)bytes);
    }
}
static int close_file(sqlite3_file *f) { return real(f)->pMethods->xClose(real(f)); }
static int read_file(sqlite3_file *f, void *b, int n, sqlite3_int64 off) {
    count_io(f, 0, n); return real(f)->pMethods->xRead(real(f), b, n, off);
}
static int write_file(sqlite3_file *f, const void *b, int n, sqlite3_int64 off) {
    count_io(f, 2, n); return real(f)->pMethods->xWrite(real(f), b, n, off);
}
static int fetch_file(sqlite3_file *f, sqlite3_int64 off, int n, void **p) {
    count_io(f, 4, n);
    int result = real(f)->pMethods->xFetch(real(f), off, n, p);
    if (result == SQLITE_OK && *p) count_io(f, 6, n);
    return result;
}
static int unfetch_file(sqlite3_file *f, sqlite3_int64 off, void *p) { return real(f)->pMethods->xUnfetch(real(f), off, p); }
static int truncate_file(sqlite3_file *f, sqlite3_int64 n) { return real(f)->pMethods->xTruncate(real(f), n); }
static int sync_file(sqlite3_file *f, int n) { return real(f)->pMethods->xSync(real(f), n); }
static int size_file(sqlite3_file *f, sqlite3_int64 *n) { return real(f)->pMethods->xFileSize(real(f), n); }
static int lock_file(sqlite3_file *f, int n) { return real(f)->pMethods->xLock(real(f), n); }
static int unlock_file(sqlite3_file *f, int n) { return real(f)->pMethods->xUnlock(real(f), n); }
static int reserved_file(sqlite3_file *f, int *n) { return real(f)->pMethods->xCheckReservedLock(real(f), n); }
static int control_file(sqlite3_file *f, int n, void *p) { return real(f)->pMethods->xFileControl(real(f), n, p); }
static int sector_file(sqlite3_file *f) { return real(f)->pMethods->xSectorSize(real(f)); }
static int device_file(sqlite3_file *f) { return real(f)->pMethods->xDeviceCharacteristics(real(f)); }
static int shm_map(sqlite3_file *f, int i, int n, int e, void volatile **p) { return real(f)->pMethods->xShmMap(real(f), i, n, e, p); }
static int shm_lock(sqlite3_file *f, int i, int n, int flags) { return real(f)->pMethods->xShmLock(real(f), i, n, flags); }
static void shm_barrier(sqlite3_file *f) { real(f)->pMethods->xShmBarrier(real(f)); }
static int shm_unmap(sqlite3_file *f, int n) { return real(f)->pMethods->xShmUnmap(real(f), n); }
static const sqlite3_io_methods methods = {
    3, close_file, read_file, write_file, truncate_file, sync_file, size_file,
    lock_file, unlock_file, reserved_file, control_file, sector_file, device_file,
    shm_map, shm_lock, shm_barrier, shm_unmap, fetch_file, unfetch_file
};
static int tracked(const char *name) {
    if (!name || !target_path) return 0;
    size_t n = strlen(target_path);
    if (strncmp(name, target_path, n) != 0) return 0;
    return name[n] == '\0' || strcmp(name + n, "-wal") == 0 ||
        strcmp(name + n, "-shm") == 0 || strcmp(name + n, "-journal") == 0;
}
static int open_file(sqlite3_vfs *v, const char *name, sqlite3_file *f, int flags, int *out) {
    (void)v;
    memset(f, 0, sizeof(ObservedFile) + parent->szOsFile);
    ObservedFile *observed = (ObservedFile *)f;
    observed->tracked = tracked(name);
    int result = parent->xOpen(parent, name, real(f), flags, out);
    if (real(f)->pMethods) {
        observed->methods = methods;
        observed->methods.iVersion = real(f)->pMethods->iVersion;
        // Preserve optional capability absence, including builds without mmap.
        if (real(f)->pMethods->iVersion < 3 || !real(f)->pMethods->xFetch) observed->methods.xFetch = NULL;
        if (real(f)->pMethods->iVersion < 3 || !real(f)->pMethods->xUnfetch) observed->methods.xUnfetch = NULL;
        f->pMethods = &observed->methods;
    }
    return result;
}
// Forward the VFS object itself too, so parent implementations receive their
// original identity and pAppData rather than assuming a cloned wrapper layout.
static int delete_path(sqlite3_vfs *v, const char *p, int sync) { (void)v; return parent->xDelete(parent, p, sync); }
static int access_path(sqlite3_vfs *v, const char *p, int flags, int *out) { (void)v; return parent->xAccess(parent, p, flags, out); }
static int full_path(sqlite3_vfs *v, const char *p, int n, char *out) { (void)v; return parent->xFullPathname(parent, p, n, out); }
static void *dl_open(sqlite3_vfs *v, const char *p) { (void)v; return parent->xDlOpen(parent, p); }
static void dl_error(sqlite3_vfs *v, int n, char *out) { (void)v; parent->xDlError(parent, n, out); }
static void (*dl_symbol(sqlite3_vfs *v, void *h, const char *p))(void) { (void)v; return parent->xDlSym(parent, h, p); }
static void dl_close(sqlite3_vfs *v, void *h) { (void)v; parent->xDlClose(parent, h); }
static int randomness(sqlite3_vfs *v, int n, char *out) { (void)v; return parent->xRandomness(parent, n, out); }
static int sleep_for(sqlite3_vfs *v, int n) { (void)v; return parent->xSleep(parent, n); }
static int current_time(sqlite3_vfs *v, double *out) { (void)v; return parent->xCurrentTime(parent, out); }
static int last_error(sqlite3_vfs *v, int n, char *out) { (void)v; return parent->xGetLastError(parent, n, out); }
static int time_int64(sqlite3_vfs *v, sqlite3_int64 *out) { (void)v; return parent->xCurrentTimeInt64(parent, out); }
static int set_call(sqlite3_vfs *v, const char *n, sqlite3_syscall_ptr p) { (void)v; return parent->xSetSystemCall(parent, n, p); }
static sqlite3_syscall_ptr get_call(sqlite3_vfs *v, const char *n) { (void)v; return parent->xGetSystemCall(parent, n); }
static const char *next_call(sqlite3_vfs *v, const char *n) { (void)v; return parent->xNextSystemCall(parent, n); }

int p11_metrics_start(const char *path) {
    if (enabled || !path) return SQLITE_MISUSE;
    parent = sqlite3_vfs_find(NULL);
    if (!parent) return SQLITE_ERROR;
    free(target_path); target_path = malloc((size_t)parent->mxPathname + 1);
    if (!target_path) return SQLITE_NOMEM;
    int canonical = parent->xFullPathname(parent, path, parent->mxPathname + 1, target_path);
    if (canonical != SQLITE_OK && canonical != SQLITE_OK_SYMLINK) return canonical;
    observer = *parent;
    observer.zName = "photosync-test-metrics";
    observer.szOsFile = sizeof(ObservedFile) + parent->szOsFile;
    observer.xOpen = open_file; observer.xDelete = delete_path; observer.xAccess = access_path;
    observer.xFullPathname = full_path; observer.xDlOpen = dl_open; observer.xDlError = dl_error;
    observer.xDlSym = dl_symbol; observer.xDlClose = dl_close; observer.xRandomness = randomness;
    observer.xSleep = sleep_for; observer.xCurrentTime = current_time;
    if (parent->xGetLastError) observer.xGetLastError = last_error;
    if (parent->iVersion >= 2 && parent->xCurrentTimeInt64) observer.xCurrentTimeInt64 = time_int64;
    if (parent->iVersion >= 3) {
        if (parent->xSetSystemCall) observer.xSetSystemCall = set_call;
        if (parent->xGetSystemCall) observer.xGetSystemCall = get_call;
        if (parent->xNextSystemCall) observer.xNextSystemCall = next_call;
    }
    for (int i = 0; i < 8; i++) atomic_store(&counters[i], 0);
    int result = sqlite3_vfs_register(&observer, 1);
    enabled = result == SQLITE_OK;
    return result;
}
void p11_metrics_stop(void) {
    if (enabled) {
        sqlite3_vfs_register(parent, 1);
        sqlite3_vfs_unregister(&observer);
        enabled = 0;
    }
}
uint64_t p11_metrics_counter(int index) {
    return index >= 0 && index < 8 ? atomic_load(&counters[index]) : 0;
}

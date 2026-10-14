#include "CoolingSMC.h"
#include <IOKit/IOKitLib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <signal.h>
#include <poll.h>

// AppleSMC user-client ABI, selector 2. No general-purpose key-write API is exported.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct {
    uint32_t key; Version version; Limits limits; KeyInfo info;
    uint8_t result, status, command; uint32_t index; uint8_t bytes[32];
} Message;
_Static_assert(sizeof(Message) == 80, "SMC ABI mismatch");
static uint32_t fourcc(const char *s) {
    return (uint32_t)(uint8_t)s[0]<<24 | (uint32_t)(uint8_t)s[1]<<16 |
           (uint32_t)(uint8_t)s[2]<<8 | (uint8_t)s[3];
}
static int call(uint32_t c, Message *in, Message *out) {
    size_t size = sizeof(*out); memset(out, 0, size);
    return IOConnectCallStructMethod(c, 2, in, sizeof(*in), out, &size) == KERN_SUCCESS
        && size == sizeof(*out) && out->result == 0;
}
static int read_key(uint32_t c, const char *key, KeyInfo *info, uint8_t bytes[32]) {
    Message in = {0}, out; in.key = fourcc(key); in.command = 9;
    if (!call(c, &in, &out) || !out.info.size || out.info.size > 32) return 0;
    *info = out.info; in.info.size = info->size; in.command = 5;
    if (!call(c, &in, &out)) return 0;
    memcpy(bytes, out.bytes, 32); return 1;
}
static double value(uint32_t c, const char *key) {
    KeyInfo info; uint8_t bytes[32];
    if (!read_key(c, key, &info, bytes)) return NAN;
    if (info.type == fourcc("flt ") && info.size == 4) { float f; memcpy(&f, bytes, 4); return f; }
    if (info.type == fourcc("ui8 ") && info.size == 1) return bytes[0];
    if (info.type == fourcc("ui16") && info.size == 2) return (bytes[0]<<8) | bytes[1];
    if (info.type == fourcc("fpe2") && info.size == 2) return ((bytes[0]<<8) | bytes[1])/4.0;
    return NAN;
}
static int write_value(uint32_t c, const char *key, double v) {
    KeyInfo info; uint8_t bytes[32];
    if (!isfinite(v) || !read_key(c, key, &info, bytes)) return 0;
    Message in = {0}, out; in.key = fourcc(key); in.command = 6; in.info.size = info.size;
    if (info.type == fourcc("flt ") && info.size == 4) { float f = v; memcpy(in.bytes, &f, 4); }
    else if (info.type == fourcc("ui8 ") && info.size == 1 && v >= 0 && v <= 1) in.bytes[0] = (uint8_t)v;
    else return 0;
    for (int attempt = 0; attempt < 10; attempt++) {
        if (call(c, &in, &out)) return 1;
        usleep(50000);
    }
    dprintf(STDERR_FILENO, "[Portico cooling] Cannot write %s = %.0f (SMC result 0x%02x)\n", key, v, out.result);
    return 0;
}
uint32_t pfc_open(void) {
#if !defined(__arm64__)
    return 0;
#endif
    // Initial hardware scope: M4, whose CPU/GPU sensor families are known below.
    char chip[128] = {0}; size_t size = sizeof(chip);
    if (sysctlbyname("machdep.cpu.brand_string", chip, &size, NULL, 0) || !strstr(chip, "Apple M4")) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t c = 0; kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &c);
    IOObjectRelease(service); return result == KERN_SUCCESS ? c : 0;
}
void pfc_close(uint32_t c) { if (c) IOServiceClose(c); }
int pfc_fan_count(uint32_t c) {
    double count = value(c, "FNum");
    return isfinite(count) && count >= 1 && count <= 4 && floor(count) == count ? (int)count : 0;
}
int pfc_read_fan(uint32_t c, int index, PFCFan *fan) {
    if (index < 0 || index >= pfc_fan_count(c)) return 0;
    char key[5]; const char *suffix[] = {"Ac", "Mn", "Mx", "Tg", "Md"}; double v[5];
    for (int i = 0; i < 5; i++) { snprintf(key, sizeof(key), "F%d%s", index, suffix[i]); v[i] = value(c, key); if (!isfinite(v[i])) { dprintf(STDERR_FILENO, "[Portico cooling] Cannot read %s\n", key); return 0; } }
    if (v[0] < 0 || v[1] < 0 || v[2] <= v[1] || v[2] > 20000 || v[3] < 0 || v[3] > v[2] + 1 || (v[4] != 0 && v[4] != 1 && v[4] != 3)) return 0;
    *fan = (PFCFan){v[0], v[1], v[2], v[3], (int)v[4]}; return 1;
}
static double hottest(uint32_t c, const char **keys, int count) {
    // Individual cores may be power-gated. Require a valid CPU group AND GPU group,
    // rather than requiring every previously awake core to remain readable.
    double maximum = NAN;
    for (int i = 0; i < count; i++) {
        double t = value(c, keys[i]);
        if (isfinite(t) && t > 0 && t <= 125) {
            maximum = isnan(maximum) ? t : fmax(maximum, t);
        }
    }
    return maximum;
}
int pfc_temperatures(uint32_t c, double *cpu, double *gpu) {
    const char *cpuKeys[] = {"Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"};
    const char *gpuKeys[] = {"Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"};
    *cpu = hottest(c, cpuKeys, sizeof(cpuKeys)/sizeof(cpuKeys[0]));
    *gpu = hottest(c, gpuKeys, sizeof(gpuKeys)/sizeof(gpuKeys[0]));
    if (!isfinite(*cpu) || !isfinite(*gpu)) dprintf(STDERR_FILENO, "[Portico cooling] Temperature CPU %.1f GPU %.1f unavailable\n", *cpu, *gpu);
    return isfinite(*cpu) && isfinite(*gpu);
}
int pfc_is_automatic(uint32_t c) {
    if (value(c, "Ftst") != 0) return 0;
    int count = pfc_fan_count(c); if (!count) return 0;
    for (int i = 0; i < count; i++) { PFCFan fan; if (!pfc_read_fan(c, i, &fan) || fan.mode == 1) return 0; }
    return 1;
}
int pfc_begin_manual(uint32_t c) {
    // Caller arms the recovery process BEFORE this first possible write.
    if (!pfc_is_automatic(c) || !write_value(c, "Ftst", 1)) return 0;
    usleep(3000000); // Let thermalmonitord yield before requesting individual fan modes.
    int count = pfc_fan_count(c); if (!count) return 0;
    for (int i = 0; i < count; i++) {
        char key[5]; snprintf(key, sizeof(key), "F%dMd", i);
        if (!write_value(c, key, 1)) return 0;
    }
    // Writes can succeed before the SMC reports the new mode on M4.
    // Wait for both fans to acknowledge manual ownership before sending targets.
    struct timespec started; clock_gettime(CLOCK_MONOTONIC, &started);
    for (;;) {
        int ready = 1;
        for (int i = 0; i < count; i++) {
            char key[5]; snprintf(key, sizeof(key), "F%dMd", i);
            if (value(c, key) != 1) ready = 0;
        }
        if (ready) return 1;
        struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - started.tv_sec >= 15) return 0;
        usleep(100000);
    }
}
int pfc_set_speed(uint32_t c, int index, double rpm) {
    PFCFan fan;
    if (!pfc_read_fan(c, index, &fan)) { dprintf(STDERR_FILENO, "[Portico cooling] Fan %d snapshot invalid\n", index); return 0; }
    if (fan.mode != 1 || !isfinite(rpm)) { dprintf(STDERR_FILENO, "[Portico cooling] Fan %d mode is %d, expected manual (1)\n", index, fan.mode); return 0; }
    rpm = fmin(fan.maximum, fmax(fan.minimum, rpm));
    char key[5]; snprintf(key, sizeof(key), "F%dTg", index);
    for (int attempt = 0; attempt < 3; attempt++) {
        if (!write_value(c, key, rpm)) return 0;
        for (int sample = 0; sample < 10; sample++) {
            if (fabs(value(c, key) - rpm) <= 2) return 1;
            usleep(50000);
        }
    }
    dprintf(STDERR_FILENO, "[Portico cooling] %s requested %.0f RPM, read back %.0f RPM\n", key, rpm, value(c, key));
    return 0;
}
int pfc_restore(uint32_t c) {
    // Reset each manual mode AND its target before releasing the global override.
    // Ftst=0 alone can leave F0Md/F1Md=1 with the previous manual target on M4.
    int count = pfc_fan_count(c), success = count > 0;
    for (int i = 0; i < count; i++) {
        char mode[5], target[5]; snprintf(mode, sizeof(mode), "F%dMd", i); snprintf(target, sizeof(target), "F%dTg", i);
        if (value(c, mode) == 1) {
            if (!write_value(c, mode, 0)) success = 0;
            if (!write_value(c, target, 0)) success = 0;
        }
    }
    if (!write_value(c, "Ftst", 0)) success = 0;
    for (int i = 0; i < 30; i++) { if (pfc_is_automatic(c)) return 1; usleep(100000); }
    (void)success;
    return 0;
}
static pid_t guard_pid = -1;
int pfc_guard_start(const char *lease, uint32_t owner, int parent, int status_fd) {
    int fds[2]; if (pipe(fds)) return -1;
    pid_t child = fork();
    if (child < 0) { close(fds[0]); close(fds[1]); return -1; }
    if (child == 0) {
        close(fds[1]); signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN);
        // No Foundation work in this child. EOF also arrives if the worker is killed.
        pid_t worker = getppid();
        struct pollfd event = {fds[0], POLLIN | POLLHUP, 0};
        for (;;) {
            int result = poll(&event, 1, 1000);
            if (result > 0) break;
            if (result < 0 && errno != EINTR) break;
            struct stat heartbeat;
            double workerAge = fstat(status_fd, &heartbeat) == 0
                ? difftime(time(NULL), heartbeat.st_mtime) : 100;
            char phase[16] = {0};
            pread(status_fd, phase, sizeof(phase) - 1, 0);
            double deadline = !strncmp(phase, "starting\n", 9) ? 30 : 8;
            if (!pfc_lease_valid(lease, owner, parent) || workerAge < 0 || workerAge > deadline) {
                // Stop further writes before restoring; only our own worker is killed.
                kill(worker, SIGKILL);
                break;
            }
        }
        close(fds[0]); int restored = 0;
        for (int attempt = 0; attempt < 10 && !restored; attempt++) {
            uint32_t c = pfc_open(); if (c) { restored = pfc_restore(c); pfc_close(c); }
            if (!restored) sleep(1);
        }
        const char *status = restored ? "restored\n" : "restore-failed\n";
        ftruncate(status_fd, 0); pwrite(status_fd, status, strlen(status), 0);
        if (!restored) dprintf(STDERR_FILENO, "PORTICO_COOLING_RESTORE_FAILED\n");
        _exit(restored ? 0 : 1);
    }
    close(fds[0]); guard_pid = child; return fds[1];
}
int pfc_guard_finish(int descriptor) {
    close(descriptor); int status = 0; pid_t result;
    do { result = waitpid(guard_pid, &status, 0); } while (result < 0 && errno == EINTR);
    return result > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
int pfc_lease_valid(const char *path, uint32_t owner, int parent) {
    if (parent <= 1 || kill(parent, 0)) return 0;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK); if (fd < 0) return 0;
    struct stat st; char content[16] = {0}; int valid = 0;
    if (!fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == owner && (st.st_mode & 0777) == 0600 && st.st_size == 7) {
        double age = difftime(time(NULL), st.st_mtime);
        valid = age >= 0 && age <= 8 && read(fd, content, sizeof(content)) == 7 && !memcmp(content, "active\n", 7);
    }
    close(fd); return valid;
}

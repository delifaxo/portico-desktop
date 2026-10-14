// Process-level fault injection. ALL hardware entry points are replaced below.
// This executable never opens AppleSMC or writes physical fan registers.
#include <IOKit/IOKitLib.h>
#include <sys/sysctl.h>
#include <sys/mman.h>
#include <assert.h>
#include <stdlib.h>
static io_service_t fake_service(mach_port_t port, CFDictionaryRef matching);
static kern_return_t fake_open(io_service_t service, task_port_t task, uint32_t type, io_connect_t *connection);
static kern_return_t fake_close(io_connect_t connection);
static kern_return_t fake_release(io_object_t object);
static kern_return_t fake_call(mach_port_t connection, uint32_t selector, const void *input, size_t inputSize, void *output, size_t *outputSize);
static int fake_sysctl(const char *name, void *value, size_t *size, const void *newValue, size_t newSize);
#define IOServiceGetMatchingService fake_service
#define IOServiceOpen fake_open
#define IOServiceClose fake_close
#define IOObjectRelease fake_release
#define IOConnectCallStructMethod fake_call
#define sysctlbyname fake_sysctl
#include "../../Sources/CoolingSMC/CoolingSMC.c"

typedef struct { int manual, modes[2], modeReadDelay[2], delayModeWrites, failTarget, writes, gatedCore, missingGPU; double rpm[2]; } Hardware;
static Hardware *hardware;
static io_service_t fake_service(mach_port_t port, CFDictionaryRef matching) { if (matching) CFRelease(matching); return 1; }
static kern_return_t fake_open(io_service_t s, task_port_t t, uint32_t type, io_connect_t *c) { *c = 1; return 0; }
static kern_return_t fake_close(io_connect_t c) { return 0; }
static kern_return_t fake_release(io_object_t o) { return 0; }
static int fake_sysctl(const char *n, void *v, size_t *s, const void *x, size_t z) { strcpy(v, "Apple M4 Max"); return 0; }
static kern_return_t fake_call(mach_port_t c, uint32_t selector, const void *input, size_t inputSize, void *output, size_t *outputSize) {
    assert(selector == 2 && inputSize == 80 && *outputSize == 80);
    const Message *in = input; Message *out = output; memset(out, 0, sizeof(*out));
    char key[5] = {(char)(in->key>>24), (char)(in->key>>16), (char)(in->key>>8), (char)in->key, 0};
    int index = key[1] == '1' ? 1 : 0, byte = 0; double val = NAN;
    if (!strcmp(key, "FNum")) { val = 2; byte = 1; }
    else if (!strcmp(key, "Ftst")) { val = hardware->manual; byte = 1; }
    else if (!strcmp(key+2, "Md")) {
        val = hardware->modes[index]; byte = 1;
        if (in->command == 5 && hardware->modeReadDelay[index] > 0) { hardware->modeReadDelay[index]--; val = 0; }
    }
    else if (key[0] == 'F' && !strcmp(key+2, "Ac")) val = hardware->rpm[index];
    else if (key[0] == 'F' && !strcmp(key+2, "Tg")) val = hardware->rpm[index];
    else if (key[0] == 'F' && !strcmp(key+2, "Mn")) val = 1000;
    else if (key[0] == 'F' && !strcmp(key+2, "Mx")) val = 5000;
    else if (!strcmp(key, "Tp01")) val = 60;
    else if (!strcmp(key, "Tp05")) val = hardware->gatedCore ? 0 : 65;
    else if (!strcmp(key, "Tg1U")) val = hardware->missingGPU ? NAN : 60;
    if (isnan(val)) { out->result = 0x84; return 0; }
    if (in->command == 9) { out->info.size = byte ? 1 : 4; out->info.type = fourcc(byte ? "ui8 " : "flt "); }
    else if (in->command == 5) { if (byte) out->bytes[0] = val; else { float f = val; memcpy(out->bytes, &f, 4); } }
    else if (in->command == 6) {
        hardware->writes++;
        if (!strcmp(key, "Ftst")) hardware->manual = in->bytes[0];
        else if (!strcmp(key+2, "Md")) {
            hardware->modes[index] = in->bytes[0];
            if (in->bytes[0] == 1 && hardware->delayModeWrites) hardware->modeReadDelay[index] = 5;
        }
        else if (!strcmp(key+2, "Tg")) {
            if (hardware->failTarget) { out->result = 0x84; return 0; }
            float f; memcpy(&f, in->bytes, 4); hardware->rpm[index] = f;
        } else assert(0);
    } else assert(0);
    return 0;
}
static char lease[1024];
static int statusFD;
static void fresh_lease(void) {
    int fd = open(lease, O_CREAT | O_TRUNC | O_WRONLY, 0600); assert(fd >= 0);
    assert(write(fd, "active\n", 7) == 7); close(fd);
}
static void expect_recovered(void) {
    for (int i = 0; i < 100 && hardware->manual; i++) usleep(100000);
    assert(hardware->manual == 0);
    assert(hardware->modes[0] == 0 && hardware->modes[1] == 0);
    char status[32] = {0}; assert(pread(statusFD, status, sizeof(status), 0) > 0);
    assert(!strcmp(status, "restored\n"));
}
int main(void) {
    hardware = mmap(NULL, sizeof(*hardware), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    assert(hardware != MAP_FAILED);
    char folder[] = "/tmp/portico-recovery-tests-XXXXXX"; assert(mkdtemp(folder));
    snprintf(lease, sizeof(lease), "%s/lease", folder);
    char statusPath[1024]; snprintf(statusPath, sizeof(statusPath), "%s/status", folder);
    statusFD = open(statusPath, O_CREAT | O_RDWR, 0600); assert(statusFD >= 0);
    fresh_lease(); uint32_t c = pfc_open(); assert(c);
    double cpu, gpu;
    assert(pfc_temperatures(c, &cpu, &gpu)); assert(cpu == 65);
    hardware->gatedCore = 1;
    assert(pfc_temperatures(c, &cpu, &gpu)); assert(cpu == 60);
    hardware->missingGPU = 1; assert(!pfc_temperatures(c, &cpu, &gpu)); hardware->missingGPU = 0;
    int guard = pfc_guard_start(lease, getuid(), getpid(), statusFD); assert(guard >= 0);
    hardware->delayModeWrites = 1;
    assert(pfc_begin_manual(c));
    assert(!pfc_set_speed(c, 0, NAN));
    assert(pfc_set_speed(c, 0, 100000)); assert(hardware->rpm[0] == 5000);
    assert(pfc_set_speed(c, 1, 3600));
    hardware->failTarget = 1;
    assert(!pfc_set_speed(c, 0, 3000)); // Firmware result must be checked even when IOKit says success.
    assert(pfc_guard_finish(guard)); expect_recovered(); hardware->failTarget = 0;
    int writes = hardware->writes; hardware->manual = 1;
    assert(!pfc_begin_manual(c)); assert(hardware->writes == writes); hardware->manual = 0;
    for (int revoke = 0; revoke <= 2; revoke++) {
        fresh_lease(); int ready[2]; assert(pipe(ready) == 0);
        pid_t worker = fork(); assert(worker >= 0);
        if (worker == 0) {
            close(ready[0]);
            assert(futimens(statusFD, NULL) == 0);
            int recovery = pfc_guard_start(lease, getuid(), getppid(), statusFD); assert(recovery >= 0);
            assert(pfc_begin_manual(c)); assert(write(ready[1], "1", 1) == 1); close(ready[1]);
            for (;;) pause();
        }
        close(ready[1]); char byte; assert(read(ready[0], &byte, 1) == 1); close(ready[0]);
        if (revoke == 1) assert(unlink(lease) == 0);
        else if (revoke == 0) assert(kill(worker, SIGKILL) == 0);
        int result;
        if (revoke == 2) {
            // Keep the app lease alive while the worker hangs: its own heartbeat must expire.
            pid_t ended = 0;
            for (int seconds = 0; seconds < 20 && !ended; seconds++) {
                fresh_lease(); sleep(1); ended = waitpid(worker, &result, WNOHANG);
            }
            assert(ended == worker);
        } else assert(waitpid(worker, &result, 0) == worker);
        expect_recovered();
    }
    close(statusFD); unlink(lease); unlink(statusPath); rmdir(folder);
    puts("PASS: delayed mode acknowledgement, power-gated cores, missing GPU, capped RPM, rejected writes, external ownership, normal recovery, worker crash, lease revocation and hung worker (mock hardware)");
}

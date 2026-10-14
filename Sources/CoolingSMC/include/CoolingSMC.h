#ifndef PORTICO_COOLING_SMC_H
#define PORTICO_COOLING_SMC_H
#include <stdint.h>
typedef struct { double actual, minimum, maximum, target; int mode; } PFCFan;
uint32_t pfc_open(void);
void pfc_close(uint32_t connection);
int pfc_fan_count(uint32_t connection);
int pfc_read_fan(uint32_t connection, int index, PFCFan *fan);
int pfc_temperatures(uint32_t connection, double *cpu, double *gpu);
int pfc_is_automatic(uint32_t connection);
int pfc_begin_manual(uint32_t connection);
int pfc_set_speed(uint32_t connection, int index, double rpm);
int pfc_restore(uint32_t connection);
// Independent child restores automatic control when the worker exits/crashes.
int pfc_guard_start(const char *lease, uint32_t owner, int parent, int status_fd);
int pfc_guard_finish(int descriptor);
int pfc_lease_valid(const char *path, uint32_t owner, int parent);
#endif

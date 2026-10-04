#pragma once
// Returns a finite numeric SMC sensor value, or -1 when unavailable.
double mv_smc_read(const char *key);
void mv_smc_close(void);

int mv_smc_dump(void);
#include <stdint.h>
typedef struct { char name[32]; char address[64]; uint32_t index; uint64_t received, sent; } MVNetwork;
typedef struct { int32_t pid; char name[256]; uint64_t cpu_ns, resident, started; } MVProcess;
int mv_network(MVNetwork *out, int capacity);
int mv_processes(MVProcess *out, int capacity);
int mv_smc_key_count(void);
int mv_smc_key_at(int index, char *key);

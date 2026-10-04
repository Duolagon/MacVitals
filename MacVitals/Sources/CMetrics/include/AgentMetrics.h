#pragma once
#include <stdint.h>
typedef struct {
    int32_t pid, parent;
    uint64_t started, cpu_ns, resident, read_bytes, written_bytes;
    int32_t readable, task_readable, uid, status, threads, running_threads, priority;
    uint64_t virtual_bytes, footprint, user_ns, system_ns;
    uint32_t faults, pageins, switches;
    char name[128], executable[1024], entrypoint[1024];
} MVAgentProcess;
// Current user's processes only. Entry point excludes prompts and environment.
int mv_agent_processes(MVAgentProcess *out, int capacity);

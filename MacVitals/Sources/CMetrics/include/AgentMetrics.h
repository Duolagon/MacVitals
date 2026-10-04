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

// Cheap discovery: no executable paths, arguments, task info or resource usage.
typedef struct {
    int32_t pid, parent, uid, status;
    uint64_t started;
    char name[128];
} MVAgentIdentity;
int mv_agent_identities(MVAgentIdentity *out, int capacity);
// Return 0 when the process exited, changed identity or belongs to another user.
int mv_agent_metadata(int32_t pid, uint64_t started, MVAgentProcess *out);
int mv_agent_resources(int32_t pid, uint64_t started, MVAgentProcess *out);

// TERM/KILL only; recheck owner and start time immediately before signaling. Returns an errno code.
int mv_agent_signal(int32_t pid, uint64_t started, int signal_number);

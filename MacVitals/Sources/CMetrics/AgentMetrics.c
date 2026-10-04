#include "AgentMetrics.h"
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static void entrypoint(pid_t pid, char *out, size_t capacity) {
    char buffer[16384]; size_t size = sizeof(buffer);
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    if (sysctl(mib, 3, buffer, &size, NULL, 0) || size <= sizeof(int)) return;
    int argc = 0; memcpy(&argc, buffer, sizeof(argc));
    if (argc < 2) return;
    char *end = buffer + size, *p = buffer + sizeof(int);
    size_t n = strnlen(p, end-p); if (p+n >= end) return;
    p += n+1; while (p < end && *p == 0) p++;
    // argv[0], then only the script/module token; no prompts are retained.
    if (p >= end) return;
    n = strnlen(p, end-p); if (p+n >= end) return; p += n+1;
    if (p >= end) return;
    n = strnlen(p, end-p); if (p+n >= end) return;
    if (strcmp(p, "-m") == 0 && argc >= 3) {
        p += n+1; if (p >= end) return;
        n = strnlen(p, end-p); if (p+n >= end) return;
    } else if (*p == '-') return;
    snprintf(out, capacity, "%.*s", (int)n, p);
}
int mv_agent_processes(MVAgentProcess *out, int capacity) {
    if (!out || capacity <= 0) return -1;
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) return -1;
    int count = proc_listallpids(NULL, 0); if (count <= 0) return -1;
    int bytes = (count + 512) * sizeof(pid_t);
    pid_t *pids = malloc(bytes); if (!pids) return -1;
    count = proc_listallpids(pids, bytes); if (count < 0) { free(pids); return -1; }
    int used = 0;
    for (int i = 0; i < count; i++) {
        struct proc_bsdinfo info = {0};
        if (pids[i] <= 0 || proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_uid != getuid()) continue;
        if (used >= capacity) { free(pids); return -2; }
        MVAgentProcess *p = &out[used++]; memset(p, 0, sizeof(*p));
        p->pid = pids[i]; p->parent = info.pbi_ppid;
        p->uid = info.pbi_uid; p->status = info.pbi_status;
        struct proc_taskinfo task = {0};
        if (proc_pidinfo(p->pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
            p->task_readable = 1; p->threads = task.pti_threadnum; p->running_threads = task.pti_numrunning; p->priority = task.pti_priority;
            p->virtual_bytes = task.pti_virtual_size; p->faults = (uint32_t)task.pti_faults; p->pageins = (uint32_t)task.pti_pageins; p->switches = (uint32_t)task.pti_csw;
        }
        p->started = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
        proc_name(p->pid, p->name, sizeof(p->name));
        proc_pidpath(p->pid, p->executable, sizeof(p->executable));
        const char *name = strrchr(p->executable, '/'); name = name ? name+1 : p->executable;
        if (strcmp(name, "node") == 0 || strcmp(name, "nodejs") == 0 || strncmp(name, "python", 6) == 0) entrypoint(p->pid, p->entrypoint, sizeof(p->entrypoint));
        struct rusage_info_v2 usage = {0};
        if (proc_pid_rusage(p->pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) == 0) {
            p->readable = 1;
            p->cpu_ns = (uint64_t)(((__uint128_t)usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom);
            p->resident = usage.ri_resident_size; p->footprint = usage.ri_phys_footprint;
            p->user_ns = (uint64_t)((__uint128_t)usage.ri_user_time * timebase.numer / timebase.denom);
            p->system_ns = (uint64_t)((__uint128_t)usage.ri_system_time * timebase.numer / timebase.denom);
            p->read_bytes = usage.ri_diskio_bytesread; p->written_bytes = usage.ri_diskio_byteswritten;
        }
    }
    free(pids); return used;
}

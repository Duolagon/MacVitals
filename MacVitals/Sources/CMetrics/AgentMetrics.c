#include "AgentMetrics.h"
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <signal.h>
#include <errno.h>
#include <sys/proc.h>

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
static void resources(MVAgentProcess *p, int detailed) {
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) return;
    struct proc_taskinfo task = {0};
    if (detailed && proc_pidinfo(p->pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
        p->task_readable = 1; p->threads = task.pti_threadnum; p->running_threads = task.pti_numrunning; p->priority = task.pti_priority;
        p->virtual_bytes = task.pti_virtual_size; p->faults = (uint32_t)task.pti_faults; p->pageins = (uint32_t)task.pti_pageins; p->switches = (uint32_t)task.pti_csw;
    }
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

int mv_agent_processes(MVAgentProcess *out, int capacity) {
    if (!out || capacity <= 0) return -1;
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
        p->started = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
        proc_name(p->pid, p->name, sizeof(p->name));
        proc_pidpath(p->pid, p->executable, sizeof(p->executable));
        const char *name = strrchr(p->executable, '/'); name = name ? name+1 : p->executable;
        if (strcmp(name, "node") == 0 || strcmp(name, "nodejs") == 0 || strncmp(name, "python", 6) == 0) entrypoint(p->pid, p->entrypoint, sizeof(p->entrypoint));
        resources(p, 1);
    }
    free(pids); return used;
}

int mv_agent_identities(MVAgentIdentity *out, int capacity) {
    if (!out || capacity <= 0) return -1;
    int count = proc_listallpids(NULL, 0); if (count <= 0) return -1;
    int bytes = (count + 512) * sizeof(pid_t);
    pid_t *pids = malloc(bytes); if (!pids) return -1;
    count = proc_listallpids(pids, bytes); if (count < 0) { free(pids); return -1; }
    int used = 0;
    for (int i = 0; i < count; i++) {
        struct proc_bsdinfo info = {0};
        if (pids[i] <= 0 || proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_uid != getuid()) continue;
        if (used >= capacity) { free(pids); return -2; }
        MVAgentIdentity *p = &out[used++]; memset(p, 0, sizeof(*p));
        p->pid = pids[i]; p->parent = info.pbi_ppid; p->uid = info.pbi_uid; p->status = info.pbi_status;
        p->started = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
        snprintf(p->name, sizeof(p->name), "%s", info.pbi_name[0] ? info.pbi_name : info.pbi_comm);
    }
    free(pids); return used;
}

static int identity(int32_t pid, uint64_t started, MVAgentProcess *out) {
    if (!out || pid <= 0) return 0;
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_uid != getuid() ||
        info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec != started) return 0;
    memset(out, 0, sizeof(*out));
    out->pid = pid; out->parent = info.pbi_ppid; out->started = started;
    out->uid = info.pbi_uid; out->status = info.pbi_status;
    snprintf(out->name, sizeof(out->name), "%s", info.pbi_name[0] ? info.pbi_name : info.pbi_comm);
    return 1;
}

int mv_agent_metadata(int32_t pid, uint64_t started, MVAgentProcess *out) {
    if (!identity(pid, started, out)) return 0;
    proc_name(pid, out->name, sizeof(out->name));
    if (proc_pidpath(pid, out->executable, sizeof(out->executable)) <= 0) return 0;
    const char *name = strrchr(out->executable, '/'); name = name ? name+1 : out->executable;
    if (strcmp(name, "node") == 0 || strcmp(name, "nodejs") == 0 || strncmp(name, "python", 6) == 0) entrypoint(pid, out->entrypoint, sizeof(out->entrypoint));
    return 1;
}

int mv_agent_resources(int32_t pid, uint64_t started, MVAgentProcess *out) {
    if (!identity(pid, started, out)) return 0;
    resources(out, 1);
    return 1;
}

int mv_agent_summary(int32_t pid, uint64_t started, MVAgentProcess *out) {
    if (!identity(pid, started, out)) return 0;
    resources(out, 0);
    return 1;
}

int mv_agent_signal(int32_t pid, uint64_t started, int signal_number) {
    if (pid <= 1 || pid == getpid() || !started || (signal_number != SIGTERM && signal_number != SIGKILL)) return EINVAL;
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return ESRCH;
    if (info.pbi_uid != getuid()) return EPERM;
    if (info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec != started) return ESTALE;
    if (info.pbi_status == SZOMB) return ESRCH;
    return kill(pid, signal_number) == 0 ? 0 : errno;
}

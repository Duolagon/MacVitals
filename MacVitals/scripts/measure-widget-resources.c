// Read cumulative CPU and process memory; do not infer CPU usage from a single ps snapshot.
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static double seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: measure-widget-resources seconds pid [pid...]\n"); return 1; }
    int duration = atoi(argv[1]), count = argc - 2;
    if (duration < 1 || duration > 60 || count > 16) return 1;
    struct rusage_info_v2 start[16] = {0}, last[16] = {0};
    unsigned long long rss[16] = {0}, footprint[16] = {0};
    int pids[16], valid[16];
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) return 1;
    for (int i = 0; i < count; i++) {
        pids[i] = atoi(argv[i + 2]);
        valid[i] = proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&start[i]) == 0;
        rss[i] = start[i].ri_resident_size; footprint[i] = start[i].ri_phys_footprint;
    }
    double begin = seconds();
    for (int tick = 0; tick < duration; tick++) {
        sleep(1);
        for (int i = 0; i < count; i++) {
            if (!valid[i] || proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&last[i]) != 0 || start[i].ri_proc_start_abstime != last[i].ri_proc_start_abstime) { valid[i] = 0; continue; }
            if (last[i].ri_resident_size > rss[i]) rss[i] = last[i].ri_resident_size;
            if (last[i].ri_phys_footprint > footprint[i]) footprint[i] = last[i].ri_phys_footprint;
        }
    }
    double elapsed = seconds() - begin;
    for (int i = 0; i < count; i++) {
        char name[128] = {0}; proc_name(pids[i], name, sizeof(name));
        if (!valid[i]) { printf("{\"pid\":%d,\"unavailable\":true}\n", pids[i]); continue; }
        unsigned long long ticks = (last[i].ri_user_time - start[i].ri_user_time) + (last[i].ri_system_time - start[i].ri_system_time);
        double cpu = ticks * (double)timebase.numer / timebase.denom / 1e9 / elapsed * 100;
        double wakeups = (last[i].ri_interrupt_wkups - start[i].ri_interrupt_wkups) / elapsed;
        double idle_wakeups = (last[i].ri_pkg_idle_wkups - start[i].ri_pkg_idle_wkups) / elapsed;
        printf("{\"pid\":%d,\"name\":\"%s\",\"duration_s\":%.3f,\"cpu_percent_one_core\":%.3f,\"peak_rss_mib\":%.3f,\"peak_footprint_mib\":%.3f,\"interrupt_wakeups_per_s\":%.3f,\"package_idle_wakeups_per_s\":%.3f}\n", pids[i], name, elapsed, cpu, rss[i]/1048576.0, footprint[i]/1048576.0, wakeups, idle_wakeups);
    }
}

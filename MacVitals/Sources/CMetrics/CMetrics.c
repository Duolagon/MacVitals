#include "CMetrics.h"
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <pthread.h>
#include <mach/mach_time.h>
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } PLimit;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct { uint32_t key; Version version; PLimit limit; KeyInfo info; uint8_t result, status, command; uint32_t data32; uint8_t bytes[32]; } Packet;
static io_connect_t connection = 0;
static pthread_mutex_t smc_mutex = PTHREAD_MUTEX_INITIALIZER;
static int open_connection(void);
static void close_connection(void) { if (connection) IOServiceClose(connection); connection = 0; }
static uint32_t code(const char *s) { return ((uint32_t)s[0]<<24)|((uint32_t)s[1]<<16)|((uint32_t)s[2]<<8)|(uint32_t)s[3]; }
static int call(Packet *in, Packet *out) {
    size_t size = sizeof(*out);
    kern_return_t result = IOConnectCallStructMethod(connection, 2, in, sizeof(*in), out, &size);
    if (result != KERN_SUCCESS) {
        close_connection();
        if (!open_connection()) return 0;
        memset(out, 0, sizeof(*out)); size = sizeof(*out);
        result = IOConnectCallStructMethod(connection, 2, in, sizeof(*in), out, &size);
        if (result != KERN_SUCCESS) close_connection();
    }
    return result == KERN_SUCCESS && size == sizeof(*out) && out->result == 0;
}
static int open_connection(void) {
    if (!connection) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (!service) return 0;
        kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
        IOObjectRelease(service);
        if (result != KERN_SUCCESS) { connection = 0; return 0; }
    }
    return 1;
}
static double read_unlocked(const char *key) {
    if (!key || strlen(key) != 4) return -1;
    if (!open_connection()) return -1;
    Packet in = {0}, out = {0}; in.key = code(key); in.command = 9;
    if (!call(&in, &out) || out.info.size == 0 || out.info.size > 32) return -1;
    uint32_t type = out.info.type; in.info.size = out.info.size; in.command = 5;
    memset(&out, 0, sizeof(out)); if (!call(&in, &out)) return -1;
    double value = -1;
    if (type == code("fpe2")) value = ((out.bytes[0]<<8)|out.bytes[1])/4.0;
    else if (type == code("sp78")) value = (int16_t)((out.bytes[0]<<8)|out.bytes[1])/256.0;
    else if (type == code("flt ")) { float f; memcpy(&f, out.bytes, sizeof(f)); value = f; }
    else if (type == code("ui8 ")) value = out.bytes[0];
    else if (type == code("ui16")) value = (out.bytes[0]<<8)|out.bytes[1];
    else if (type == code("ui32")) value = ((uint32_t)out.bytes[0]<<24)|((uint32_t)out.bytes[1]<<16)|((uint32_t)out.bytes[2]<<8)|out.bytes[3];
    return isfinite(value) ? value : -1;
}
double mv_smc_read(const char *key) {
    pthread_mutex_lock(&smc_mutex); double value = read_unlocked(key); pthread_mutex_unlock(&smc_mutex); return value;
}
void mv_smc_close(void) { pthread_mutex_lock(&smc_mutex); close_connection(); pthread_mutex_unlock(&smc_mutex); }

static void name(uint32_t n, char out[5]) {
    for (int i=0; i<4; i++) { unsigned char ch = (n >> (24-i*8)) & 255; out[i] = ch >= 32 && ch <= 126 ? ch : '?'; }
    out[4] = 0;
}
static int dump_unlocked(void) {
    if (!open_connection()) { fprintf(stderr, "AppleSMC connection unavailable\n"); return 1; }
    double n = read_unlocked("#KEY");
    if (n < 1 || n > 65536) { fprintf(stderr, "Invalid SMC key count: %.0f\n", n); return 1; }
    printf("# SMC keys: %.0f; values read only for T* temperature candidates\nkey\ttype\tsize\tvalue\n", n);
    int failures = 0;
    for (uint32_t i=0; i<(uint32_t)n; i++) {
        Packet in = {0}, out = {0}; in.command = 8; in.data32 = i;
        if (!call(&in, &out)) { failures++; continue; }
        char key[5], type[5]; name(out.key, key);
        memset(&in, 0, sizeof(in)); in.key = out.key; in.command = 9;
        memset(&out, 0, sizeof(out));
        if (!call(&in, &out)) { printf("%s\t?\t?\tunreadable metadata\n", key); continue; }
        name(out.info.type, type);
        printf("%s\t%s\t%u\t", key, type, out.info.size);
        if (key[0] == 'T') { double value = read_unlocked(key); if (value >= 0) printf("%.4f", value); else printf("unavailable"); }
        else printf("not sampled");
        printf("\n");
    }
    fprintf(stderr, "Enumerated %.0f indices; failed indices: %d\n", n, failures);
    close_connection();
    return failures ? 2 : 0;
}
int mv_smc_dump(void) { pthread_mutex_lock(&smc_mutex); int result = dump_unlocked(); pthread_mutex_unlock(&smc_mutex); return result; }
#include <ifaddrs.h>
#include <net/route.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <libproc.h>
#include <sys/resource.h>
#include <stdlib.h>
int mv_smc_key_count(void) { double count = mv_smc_read("#KEY"); return count > 0 && count <= 65536 ? (int)count : 0; }
static int key_at_unlocked(int index, char *key) {
    if (!open_connection() || index < 0) return 0;
    Packet in = {0}, out = {0}; in.command = 8; in.data32 = index;
    if (!call(&in, &out)) return 0; name(out.key, key); return 1;
}
int mv_smc_key_at(int index, char *key) { pthread_mutex_lock(&smc_mutex); int result = key_at_unlocked(index, key); pthread_mutex_unlock(&smc_mutex); return result; }
int mv_network(MVNetwork *out, int capacity) {
    struct ifaddrs *list = NULL; if (getifaddrs(&list) != 0) return -1;
    int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0}; size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0) { freeifaddrs(list); return -1; }
    char *route = malloc(length);
    if (!route || sysctl(mib, 6, route, &length, NULL, 0) != 0) { free(route); freeifaddrs(list); return -1; }
    int count = 0;
    for (struct ifaddrs *p = list; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK || !p->ifa_data || !(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
        if (count >= capacity) break;
        MVNetwork *n = &out[count++]; memset(n, 0, sizeof(*n)); snprintf(n->name, sizeof(n->name), "%s", p->ifa_name);
        n->index = ((struct sockaddr_dl *)p->ifa_addr)->sdl_index;
        int found = 0;
        for (size_t offset=0; offset + sizeof(struct rt_msghdr) <= length;) {
            struct rt_msghdr *header = (struct rt_msghdr *)(route+offset);
            if (header->rtm_msglen == 0 || offset + header->rtm_msglen > length) break;
            if (header->rtm_type == RTM_IFINFO2 && header->rtm_msglen >= sizeof(struct if_msghdr2)) {
                struct if_msghdr2 *data = (struct if_msghdr2 *)header;
                if (data->ifm_index == n->index) { n->received = data->ifm_data.ifi_ibytes; n->sent = data->ifm_data.ifi_obytes; found = 1; break; }
            }
            offset += header->rtm_msglen;
        }
        if (!found) { count--; continue; }
        for (struct ifaddrs *a = list; a; a = a->ifa_next) {
            if (strcmp(a->ifa_name, p->ifa_name) == 0 && a->ifa_addr && a->ifa_addr->sa_family == AF_INET) {
                inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, n->address, sizeof(n->address)); break;
            }
        }
    }
    free(route); freeifaddrs(list); return count;
}
int mv_processes(MVProcess *out, int capacity) {
    mach_timebase_info_data_t timebase; if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) return -1;
    int size = proc_listallpids(NULL, 0); if (size <= 0) return -1;
    int bytes = (size + 256) * sizeof(pid_t); pid_t *pids = malloc(bytes); if (!pids) return -1;
    int count = proc_listallpids(pids, bytes), used = 0;
    for (int i=0; i<count && used<capacity; i++) {
        struct rusage_info_v2 usage = {0};
        if (pids[i] <= 0 || proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) continue;
        MVProcess *p = &out[used++]; memset(p, 0, sizeof(*p)); p->pid = pids[i];
        proc_name(pids[i], p->name, sizeof(p->name)); p->cpu_ns = (uint64_t)(((__uint128_t)usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom); p->started = usage.ri_proc_start_abstime; p->resident = usage.ri_resident_size;
    }
    free(pids); return used;
}

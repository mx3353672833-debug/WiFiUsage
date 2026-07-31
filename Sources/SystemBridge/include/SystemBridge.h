#ifndef SYSTEM_BRIDGE_H
#define SYSTEM_BRIDGE_H

#include <stddef.h>
#include <stdint.h>
#include <net/if.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WUInterfaceCounter {
    char name[IFNAMSIZ];
    uint32_t index;
    uint64_t ibytes;
    uint64_t obytes;
} WUInterfaceCounter;

/// Reads cumulative interface counters through NET_RT_IFLIST2/RTM_IFINFO2.
/// `out_count` receives the total number available. Up to `capacity` records are copied.
/// Call once with a NULL buffer to size, then call again with allocated storage.
/// Returns 0 or a POSIX errno value.
int WUCopyInterfaceCounters(
    WUInterfaceCounter *buffer,
    size_t capacity,
    size_t *out_count
);

/// Returns a process's parent PID and start time using the public libproc API.
/// The start time makes PID reuse detectable. Returns 0 or a POSIX errno value.
int WUCopyProcessIdentity(
    int32_t process_identifier,
    int32_t *out_parent_identifier,
    int64_t *out_start_seconds,
    int32_t *out_start_microseconds
);

#ifdef __cplusplus
}
#endif

#endif

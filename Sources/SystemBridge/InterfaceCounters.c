#include "SystemBridge.h"

#include <errno.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <net/route.h>

int WUCopyInterfaceCounters(
    WUInterfaceCounter *buffer,
    size_t capacity,
    size_t *out_count
) {
    if (out_count == NULL || (capacity > 0 && buffer == NULL)) {
        return EINVAL;
    }

    int mib[6] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    void *snapshot = NULL;
    size_t snapshot_size = 0;

    for (int attempt = 0; attempt < 3; attempt++) {
        if (sysctl(mib, 6, NULL, &snapshot_size, NULL, 0) != 0) {
            return errno;
        }
        snapshot = malloc(snapshot_size);
        if (snapshot == NULL) {
            return ENOMEM;
        }
        if (sysctl(mib, 6, snapshot, &snapshot_size, NULL, 0) == 0) {
            break;
        }
        int error = errno;
        free(snapshot);
        snapshot = NULL;
        if (error != ENOMEM) {
            return error;
        }
    }

    if (snapshot == NULL) {
        return ENOMEM;
    }

    size_t count = 0;
    const uint8_t *cursor = snapshot;
    const uint8_t *end = cursor + snapshot_size;

    while (cursor + sizeof(struct if_msghdr) <= end) {
        const struct if_msghdr *header = (const struct if_msghdr *)cursor;
        if (header->ifm_msglen == 0 || cursor + header->ifm_msglen > end) {
            free(snapshot);
            return EPROTO;
        }

        if (header->ifm_type == RTM_IFINFO2 &&
            header->ifm_msglen >= sizeof(struct if_msghdr2)) {
            const struct if_msghdr2 *message = (const struct if_msghdr2 *)cursor;
            if (count < capacity) {
                WUInterfaceCounter *destination = &buffer[count];
                memset(destination, 0, sizeof(*destination));
                destination->index = message->ifm_index;
                destination->ibytes = message->ifm_data.ifi_ibytes;
                destination->obytes = message->ifm_data.ifi_obytes;
                if_indextoname(message->ifm_index, destination->name);
            }
            count++;
        }
        cursor += header->ifm_msglen;
    }

    free(snapshot);
    *out_count = count;
    return 0;
}

int WUCopyProcessIdentity(
    int32_t process_identifier,
    int32_t *out_parent_identifier,
    int64_t *out_start_seconds,
    int32_t *out_start_microseconds
) {
    if (process_identifier <= 0 ||
        out_parent_identifier == NULL ||
        out_start_seconds == NULL ||
        out_start_microseconds == NULL) {
        return EINVAL;
    }

    struct proc_bsdinfo info;
    memset(&info, 0, sizeof(info));
    int copied = proc_pidinfo(
        process_identifier,
        PROC_PIDTBSDINFO,
        0,
        &info,
        sizeof(info)
    );
    if (copied != sizeof(info)) {
        return errno == 0 ? ESRCH : errno;
    }

    *out_parent_identifier = (int32_t)info.pbi_ppid;
    *out_start_seconds = (int64_t)info.pbi_start_tvsec;
    *out_start_microseconds = (int32_t)info.pbi_start_tvusec;
    return 0;
}

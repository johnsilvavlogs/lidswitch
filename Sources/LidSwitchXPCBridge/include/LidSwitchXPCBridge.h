#ifndef LIDSWITCH_XPC_BRIDGE_H
#define LIDSWITCH_XPC_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "LidSwitchReleaseIdentity.generated.h"

#ifdef __cplusplus
extern "C" {
#endif

#define LS_XPC_MAX_LOGICAL_BYTES 1024u
#define LS_XPC_MAX_IDENTIFIER_BYTES 128u
#define LS_XPC_MAX_CDHASH_BYTES 64u

typedef enum {
    LS_IDENTITY_MANUAL_EXACT = 1,
    LS_IDENTITY_DEVELOPER_ID_EXACT = 2,
} ls_identity_profile_t;

typedef enum {
    LS_OPERATION_BEGIN = 1,
    LS_OPERATION_RENEW = 2,
    LS_OPERATION_END = 3,
    LS_OPERATION_SNAPSHOT = 4,
    LS_OPERATION_RESTORE = 5,
    /* Rebinds an interrupted transport to the same process-bound lease. It
       never extends the lease; only RENEW may do that after a reconnect. */
    LS_OPERATION_RECONNECT = 6,
} ls_operation_t;

/* Transport classes are intentionally distinct from authenticated protocol
   failures. Only the two indeterminate cases may trigger a same-process
   RECONNECT; malformed/authentication replies are fail-closed. */
typedef enum {
    LS_XPC_STATUS_OK = 0,
    LS_XPC_STATUS_INVALID_ARGUMENT = 22,
    LS_XPC_STATUS_ALLOCATION_FAILURE = 12,
    LS_XPC_STATUS_INDETERMINATE_TIMEOUT = 60,
    LS_XPC_STATUS_INDETERMINATE_INTERRUPTED = 57,
    LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE = 80,
} ls_xpc_status_t;

bool ls_xpc_status_is_indeterminate(int status);

/* Deterministic, transport-free ownership harness for the request state
   machine. It exercises callback-wins, timeout-wins, cancellation, wrapper
   release, and every pre-callback allocation failure without live XPC. */
bool ls_xpc_request_lifecycle_harness(void);

/* Captured from documented XPC and libproc APIs after SecCode validation and
   before request decoding. The bridge passes this value synchronously; Swift
   must copy it and must not retain the callback pointer. */
typedef struct {
    int32_t pid;
    uint32_t euid;
    uint32_t asid;
    uint64_t start_tvsec;
    uint64_t start_tvusec;
} ls_peer_identity_t;

typedef struct ls_identity_policy ls_identity_policy_t;
typedef struct ls_xpc_client ls_xpc_client_t;
typedef struct ls_xpc_reply ls_xpc_reply_t;

typedef void (*ls_server_handler_t)(
    void *context,
    uint64_t connection_id,
    const ls_peer_identity_t *peer,
    uint32_t operation,
    const char *request_id,
    const char *session_id,
    void *reply_writer
);

/* Exact PID/start recheck used by the helper before granting or retaining a
   reconnectable lease. It intentionally has no audit-token/path dependency. */
bool ls_peer_identity_is_live(const ls_peer_identity_t *peer);
bool ls_peer_identity_for_current_process(ls_peer_identity_t *peer);

typedef void (*ls_server_connection_event_t)(
    void *context,
    uint64_t connection_id,
    bool invalidated
);

ls_identity_policy_t *ls_identity_policy_create(
    const char *identifier,
    const uint8_t *cdhash,
    size_t cdhash_length,
    uid_t expected_euid,
    ls_identity_profile_t profile,
    const char *team_identifier
);
void ls_identity_policy_release(ls_identity_policy_t *policy);

int ls_xpc_server_run(
    const char *mach_service,
    const ls_identity_policy_t *client_policy,
    ls_server_handler_t handler,
    ls_server_connection_event_t connection_event,
    void *context
);

void ls_reply_writer_set(
    void *reply_writer,
    int32_t result,
    const char *reason,
    const char *session_id,
    double expiry_monotonic,
    uint32_t state,
    uint32_t power_source,
    bool sleep_disabled,
    int32_t ac_sleep_minutes
);

ls_xpc_client_t *ls_xpc_client_create(
    const char *mach_service,
    const ls_identity_policy_t *helper_policy
);
void ls_xpc_client_cancel(ls_xpc_client_t *client);
void ls_xpc_client_release(ls_xpc_client_t *client);
int ls_xpc_client_send(
    ls_xpc_client_t *client,
    uint32_t operation,
    const char *request_id,
    const char *session_id,
    double timeout_seconds,
    ls_xpc_reply_t **reply
);

int32_t ls_xpc_reply_result(const ls_xpc_reply_t *reply);
const char *ls_xpc_reply_reason(const ls_xpc_reply_t *reply);
const char *ls_xpc_reply_session_id(const ls_xpc_reply_t *reply);
double ls_xpc_reply_expiry_monotonic(const ls_xpc_reply_t *reply);
uint32_t ls_xpc_reply_state(const ls_xpc_reply_t *reply);
uint32_t ls_xpc_reply_power_source(const ls_xpc_reply_t *reply);
bool ls_xpc_reply_sleep_disabled(const ls_xpc_reply_t *reply);
int32_t ls_xpc_reply_ac_sleep_minutes(const ls_xpc_reply_t *reply);
void ls_xpc_reply_release(ls_xpc_reply_t *reply);

typedef struct ls_code_identity ls_code_identity_t;
ls_code_identity_t *ls_copy_current_code_identity(void);
ls_code_identity_t *ls_copy_static_code_identity(const char *path);
const char *ls_code_identity_identifier(const ls_code_identity_t *identity);
const uint8_t *ls_code_identity_cdhash(const ls_code_identity_t *identity);
size_t ls_code_identity_cdhash_length(const ls_code_identity_t *identity);
const char *ls_code_identity_team_identifier(const ls_code_identity_t *identity);
void ls_code_identity_release(ls_code_identity_t *identity);
uint64_t ls_xpc_last_identity_duration_ns(void);

#ifdef __cplusplus
}
#endif
#endif

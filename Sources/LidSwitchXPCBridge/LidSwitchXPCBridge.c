#include "LidSwitchXPCBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <ctype.h>
#include <limits.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include <libproc.h>
#include <bsm/audit.h>
#include <sys/proc_info.h>
#include <xpc/xpc.h>

static const char *kSchema = "schema";
static const char *kOperation = "operation";
static const char *kRequestID = "request_id";
static const char *kSessionID = "session_id";
static const char *kResult = "result";
static const char *kReason = "reason";
static const char *kExpiry = "expiry_monotonic";
static const char *kState = "state";
static const char *kPower = "power_source";
static const char *kSleepDisabled = "sleep_disabled";
static const char *kACSleep = "ac_sleep_minutes";

enum { LS_AC_SLEEP_MINUTES_MAX = 1440 };

enum {
    LS_REQUEST_LOGICAL_MAX = 4 * 32 + 2 * 16,
    LS_REPLY_LOGICAL_MAX = 10 * 32 + 96 + 16,
};
_Static_assert(LS_REQUEST_LOGICAL_MAX <= LS_XPC_MAX_LOGICAL_BYTES, "request exceeds protocol bound");
_Static_assert(LS_REPLY_LOGICAL_MAX <= LS_XPC_MAX_LOGICAL_BYTES, "reply exceeds protocol bound");

struct ls_identity_policy {
    char identifier[LS_XPC_MAX_IDENTIFIER_BYTES + 1];
    uint8_t cdhash[LS_XPC_MAX_CDHASH_BYTES];
    size_t cdhash_length;
    uid_t expected_euid;
    ls_identity_profile_t profile;
    char team_identifier[65];
};

struct ls_code_identity {
    char identifier[LS_XPC_MAX_IDENTIFIER_BYTES + 1];
    uint8_t cdhash[LS_XPC_MAX_CDHASH_BYTES];
    size_t cdhash_length;
    char team_identifier[65];
};

struct ls_xpc_reply {
    int32_t result;
    char reason[97];
    char session_id[37];
    double expiry_monotonic;
    uint32_t state;
    uint32_t power_source;
    bool sleep_disabled;
    int32_t ac_sleep_minutes;
};

struct ls_reply_writer {
    bool set;
    struct ls_xpc_reply value;
};

struct ls_xpc_client {
    xpc_connection_t connection;
    dispatch_queue_t event_queue;
    struct ls_identity_policy helper_policy;
    dispatch_semaphore_t serialization;
    atomic_bool invalid;
    /* The Swift owner holds one reference. Every reply callback holds another
       until it has stopped touching the connection and policy. */
    atomic_uint_fast32_t references;
};

enum ls_request_state {
    LS_REQUEST_PENDING = 0,
    LS_REQUEST_COMPLETED = 1,
    LS_REQUEST_ABANDONED = 2,
};

struct ls_xpc_request {
    struct ls_xpc_client *client;
    char *expected_request;
    dispatch_semaphore_t completion;
    atomic_int state;
    struct ls_xpc_reply decoded;
    int completion_status;
};

static void ls_xpc_client_retain(struct ls_xpc_client *client) {
    if (client) atomic_fetch_add_explicit(&client->references, 1, memory_order_relaxed);
}

static void ls_xpc_client_release_reference(struct ls_xpc_client *client) {
    if (!client || atomic_fetch_sub_explicit(&client->references, 1, memory_order_acq_rel) != 1) return;
    /* Plain C dispatch objects are Create/Copy-owned. The final client ref is
       reached only after the Swift wrapper and every reply callback released
       their ownership, so all three objects are now quiescent. */
    xpc_release(client->connection);
    dispatch_release(client->serialization);
    dispatch_release(client->event_queue);
    memset(client, 0, sizeof(*client));
    free(client);
}

static void ls_xpc_request_release(struct ls_xpc_request *request) {
    if (!request) return;
    free(request->expected_request);
    dispatch_release(request->completion);
    ls_xpc_client_release_reference(request->client);
    memset(request, 0, sizeof(*request));
    free(request);
}

static atomic_uint_fast64_t ls_last_identity_duration_ns;
uint64_t ls_xpc_last_identity_duration_ns(void) { return atomic_load(&ls_last_identity_duration_ns); }

static bool ls_safe_copy(char *destination, size_t capacity, const char *source) {
    if (!destination || !source || capacity == 0) return false;
    size_t length = strnlen(source, capacity);
    if (length == 0 || length >= capacity) return false;
    memcpy(destination, source, length);
    destination[length] = '\0';
    return true;
}

static bool ls_safe_optional_copy(char *destination, size_t capacity, const char *source) {
    if (!destination || capacity == 0) return false;
    if (!source || source[0] == '\0') {
        destination[0] = '\0';
        return true;
    }
    return ls_safe_copy(destination, capacity, source);
}

ls_identity_policy_t *ls_identity_policy_create(
    const char *identifier, const uint8_t *cdhash, size_t cdhash_length,
    uid_t expected_euid, ls_identity_profile_t profile, const char *team_identifier
) {
    if (!identifier || !cdhash || cdhash_length == 0 ||
        cdhash_length > LS_XPC_MAX_CDHASH_BYTES) return NULL;
    if (profile != LS_IDENTITY_MANUAL_EXACT && profile != LS_IDENTITY_DEVELOPER_ID_EXACT) return NULL;
    ls_identity_policy_t *policy = calloc(1, sizeof(*policy));
    if (!policy) return NULL;
    if (!ls_safe_copy(policy->identifier, sizeof(policy->identifier), identifier) ||
        !ls_safe_optional_copy(policy->team_identifier, sizeof(policy->team_identifier), team_identifier)) {
        free(policy);
        return NULL;
    }
    if (profile == LS_IDENTITY_DEVELOPER_ID_EXACT && policy->team_identifier[0] == '\0') {
        free(policy);
        return NULL;
    }
    memcpy(policy->cdhash, cdhash, cdhash_length);
    policy->cdhash_length = cdhash_length;
    policy->expected_euid = expected_euid;
    policy->profile = profile;
    return policy;
}

void ls_identity_policy_release(ls_identity_policy_t *policy) {
    if (!policy) return;
    memset(policy, 0, sizeof(*policy));
    free(policy);
}

static bool ls_cfstring_copy(CFTypeRef value, char *destination, size_t capacity) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return false;
    return CFStringGetCString((CFStringRef)value, destination, capacity, kCFStringEncodingUTF8);
}

static bool ls_extract_identity(SecStaticCodeRef code, bool dynamic, struct ls_code_identity *identity) {
    if (!code || !identity) return false;
    OSStatus validity = dynamic
        ? SecCodeCheckValidity((SecCodeRef)code, kSecCSStrictValidate, NULL)
        : SecStaticCodeCheckValidity(code, kSecCSStrictValidate, NULL);
    if (validity != errSecSuccess) return false;
    CFDictionaryRef info = NULL;
    OSStatus status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    if (status != errSecSuccess || !info) return false;
    bool valid = false;
    CFTypeRef identifier = CFDictionaryGetValue(info, kSecCodeInfoIdentifier);
    CFTypeRef cdhash = CFDictionaryGetValue(info, kSecCodeInfoUnique);
    CFTypeRef team = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
    if (ls_cfstring_copy(identifier, identity->identifier, sizeof(identity->identifier)) &&
        cdhash && CFGetTypeID(cdhash) == CFDataGetTypeID()) {
        CFIndex length = CFDataGetLength((CFDataRef)cdhash);
        if (length > 0 && length <= LS_XPC_MAX_CDHASH_BYTES) {
            CFDataGetBytes((CFDataRef)cdhash, CFRangeMake(0, length), identity->cdhash);
            identity->cdhash_length = (size_t)length;
            identity->team_identifier[0] = '\0';
            if (!team || ls_cfstring_copy(team, identity->team_identifier, sizeof(identity->team_identifier))) {
                valid = true;
            }
        }
    }
    CFRelease(info);
    return valid;
}

static bool ls_valid_developer_id(SecCodeRef code, const ls_identity_policy_t *policy) {
    const char *identifier = policy->identifier;
    const char *team = policy->team_identifier;
    for (const char *p = identifier; *p; p++) if (!(isalnum(*p) || *p == '.' || *p == '-')) return false;
    if (strlen(team) != 10) return false;
    for (const char *p = team; *p; p++) if (!(isupper(*p) || isdigit(*p))) return false;
    char requirement_buffer[384];
    int written = snprintf(requirement_buffer, sizeof(requirement_buffer),
        "anchor apple generic and identifier \"%s\" and certificate leaf[subject.OU] = \"%s\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
        identifier, team);
    if (written <= 0 || (size_t)written >= sizeof(requirement_buffer)) return false;
    CFStringRef requirement_text = CFStringCreateWithCString(kCFAllocatorDefault, requirement_buffer, kCFStringEncodingUTF8);
    if (!requirement_text) return false;
    SecRequirementRef requirement = NULL;
    OSStatus create_status = SecRequirementCreateWithString(requirement_text, kSecCSDefaultFlags, &requirement);
    CFRelease(requirement_text);
    if (create_status != errSecSuccess || !requirement) return false;
    OSStatus check_status = SecCodeCheckValidity(code, kSecCSStrictValidate, requirement);
    CFRelease(requirement);
    return check_status == errSecSuccess;
}

static bool ls_validate_message_identity(xpc_object_t message, uid_t peer_euid, const ls_identity_policy_t *policy) {
    struct timespec started = {0}, finished = {0};
    clock_gettime(CLOCK_MONOTONIC_RAW, &started);
    if (!message || !policy || peer_euid != policy->expected_euid) return false;
    SecCodeRef code = NULL;
    if (SecCodeCreateWithXPCMessage(message, kSecCSDefaultFlags, &code) != errSecSuccess || !code) return false;
    struct ls_code_identity actual = {0};
    bool valid = ls_extract_identity((SecStaticCodeRef)code, true, &actual);
    if (valid) {
        valid = strcmp(actual.identifier, policy->identifier) == 0 &&
            actual.cdhash_length == policy->cdhash_length &&
            memcmp(actual.cdhash, policy->cdhash, actual.cdhash_length) == 0;
    }
    if (valid && policy->profile == LS_IDENTITY_DEVELOPER_ID_EXACT) {
        valid = strcmp(actual.team_identifier, policy->team_identifier) == 0 &&
            ls_valid_developer_id(code, policy);
    }
    CFRelease(code);
    clock_gettime(CLOCK_MONOTONIC_RAW, &finished);
    int64_t seconds = (int64_t)finished.tv_sec - (int64_t)started.tv_sec;
    int64_t nanoseconds = (int64_t)finished.tv_nsec - (int64_t)started.tv_nsec;
    atomic_store(&ls_last_identity_duration_ns, (uint64_t)(seconds * 1000000000ll + nanoseconds));
    return valid;
}

static bool ls_capture_peer_identity(xpc_connection_t connection, uid_t expected_euid, ls_peer_identity_t *peer) {
    if (!connection || !peer) return false;
    const pid_t pid = xpc_connection_get_pid(connection);
    if (pid <= 0) return false;
    /* Keep the documented audit-session value signed until validation. XPC can
       report a negative sentinel; casting first would turn it into UINT32_MAX. */
    const au_asid_t asid = xpc_connection_get_asid(connection);
    if (asid < 0) return false;
    _Static_assert(sizeof(au_asid_t) <= sizeof(uint32_t), "ASID must fit protocol field");
    const uid_t euid = xpc_connection_get_euid(connection);
    /* Re-read after SecCode authentication so the persisted tuple cannot
       silently cross an EUID policy boundary between those two operations. */
    if (euid != expected_euid) return false;
    struct proc_bsdinfo info = {0};
    const int read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof(info));
    if (read != (int)sizeof(info) || info.pbi_pid != (uint32_t)pid ||
        info.pbi_start_tvsec == 0) return false;
    peer->pid = pid;
    peer->euid = (uint32_t)euid;
    peer->asid = (uint32_t)asid;
    peer->start_tvsec = info.pbi_start_tvsec;
    peer->start_tvusec = info.pbi_start_tvusec;
    return true;
}

bool ls_peer_identity_is_live(const ls_peer_identity_t *peer) {
    if (!peer || peer->pid <= 0 || peer->start_tvsec == 0) return false;
    struct proc_bsdinfo info = {0};
    const int read = proc_pidinfo(peer->pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof(info));
    return read == (int)sizeof(info) && info.pbi_pid == (uint32_t)peer->pid &&
        info.pbi_start_tvsec == peer->start_tvsec && info.pbi_start_tvusec == peer->start_tvusec;
}

bool ls_peer_identity_for_current_process(ls_peer_identity_t *peer) {
    if (!peer) return false;
    const pid_t pid = getpid();
    struct proc_bsdinfo info = {0};
    const int read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof(info));
    if (read != (int)sizeof(info) || info.pbi_pid != (uint32_t)pid || info.pbi_start_tvsec == 0) return false;
    peer->pid = pid; peer->euid = (uint32_t)geteuid(); peer->asid = 0;
    peer->start_tvsec = info.pbi_start_tvsec; peer->start_tvusec = info.pbi_start_tvusec;
    return true;
}

static bool ls_uuid_string(const uint8_t *bytes, char output[37]) {
    if (!bytes) return false;
    uuid_unparse_lower(bytes, output);
    return true;
}

static bool ls_request_key_allowed(const char *key) {
    return strcmp(key, kSchema) == 0 || strcmp(key, kOperation) == 0 ||
        strcmp(key, kRequestID) == 0 || strcmp(key, kSessionID) == 0;
}

static bool ls_reply_key_allowed(const char *key) {
    return strcmp(key, kSchema) == 0 || strcmp(key, kRequestID) == 0 ||
        strcmp(key, kResult) == 0 || strcmp(key, kReason) == 0 ||
        strcmp(key, kSessionID) == 0 || strcmp(key, kExpiry) == 0 ||
        strcmp(key, kState) == 0 || strcmp(key, kPower) == 0 ||
        strcmp(key, kSleepDisabled) == 0 || strcmp(key, kACSleep) == 0;
}

static bool ls_dictionary_exact(xpc_object_t dictionary, size_t count, bool reply) {
    if (xpc_get_type(dictionary) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_count(dictionary) != count) return false;
    __block bool valid = true;
    xpc_dictionary_apply(dictionary, ^bool(const char *key, xpc_object_t value) {
        (void)value;
        if (!(reply ? ls_reply_key_allowed(key) : ls_request_key_allowed(key))) valid = false;
        return valid;
    });
    return valid;
}

static bool ls_decode_request(xpc_object_t message, uint32_t *operation, char request_id[37], char session_id[37]) {
    if (!ls_dictionary_exact(message, 4, false)) return false;
    xpc_object_t schema = xpc_dictionary_get_value(message, kSchema);
    xpc_object_t op = xpc_dictionary_get_value(message, kOperation);
    xpc_object_t request = xpc_dictionary_get_value(message, kRequestID);
    xpc_object_t session = xpc_dictionary_get_value(message, kSessionID);
    if (!schema || xpc_get_type(schema) != XPC_TYPE_UINT64 || xpc_uint64_get_value(schema) != LS_XPC_PROTOCOL_VERSION ||
        !op || xpc_get_type(op) != XPC_TYPE_UINT64 || !request || xpc_get_type(request) != XPC_TYPE_UUID ||
        !session || xpc_get_type(session) != XPC_TYPE_UUID) return false;
    uint64_t raw_operation = xpc_uint64_get_value(op);
    if (raw_operation < LS_OPERATION_BEGIN || raw_operation > LS_OPERATION_RECONNECT) return false;
    const uint8_t *request_bytes = xpc_uuid_get_bytes(request);
    const uint8_t *session_bytes = xpc_uuid_get_bytes(session);
    if (!request_bytes || !session_bytes || uuid_is_null(request_bytes)) return false;
    if (raw_operation == LS_OPERATION_RESTORE && !uuid_is_null(session_bytes)) return false;
    if (raw_operation != LS_OPERATION_RESTORE && raw_operation != LS_OPERATION_SNAPSHOT && uuid_is_null(session_bytes)) return false;
    *operation = (uint32_t)raw_operation;
    return ls_uuid_string(request_bytes, request_id) && ls_uuid_string(session_bytes, session_id);
}

void ls_reply_writer_set(void *opaque, int32_t result, const char *reason, const char *session_id,
                         double expiry, uint32_t state, uint32_t power, bool sleep_disabled,
                         int32_t ac_sleep) {
    struct ls_reply_writer *writer = opaque;
    if (!writer || writer->set || !reason || !session_id || !isfinite(expiry) || state > 3 || power > 2 ||
        ac_sleep < -1 || ac_sleep > LS_AC_SLEEP_MINUTES_MAX) return;
    if (!ls_safe_copy(writer->value.reason, sizeof(writer->value.reason), reason) ||
        !ls_safe_copy(writer->value.session_id, sizeof(writer->value.session_id), session_id)) return;
    uuid_t parsed;
    if (uuid_parse(session_id, parsed) != 0) return;
    writer->value.result = result;
    writer->value.expiry_monotonic = expiry;
    writer->value.state = state;
    writer->value.power_source = power;
    writer->value.sleep_disabled = sleep_disabled;
    writer->value.ac_sleep_minutes = ac_sleep;
    writer->set = true;
}

struct ls_server_context {
    struct ls_identity_policy policy;
    ls_server_handler_t handler;
    ls_server_connection_event_t event;
    void *swift_context;
    atomic_uint_fast64_t next_connection_id;
};

struct ls_peer_context { uint64_t identifier; struct ls_server_context *server; };

static xpc_object_t ls_encode_reply(xpc_object_t request, const struct ls_xpc_reply *reply) {
    xpc_object_t message = xpc_dictionary_create_reply(request);
    if (!message) return NULL;
    uuid_t request_uuid = {0}, session_uuid = {0};
    const uint8_t *request_bytes = xpc_dictionary_get_uuid(request, kRequestID);
    if (!request_bytes || uuid_parse(reply->session_id, session_uuid) != 0) { xpc_release(message); return NULL; }
    memcpy(request_uuid, request_bytes, sizeof(uuid_t));
    xpc_dictionary_set_uint64(message, kSchema, LS_XPC_PROTOCOL_VERSION);
    xpc_dictionary_set_uuid(message, kRequestID, request_uuid);
    xpc_dictionary_set_int64(message, kResult, reply->result);
    xpc_dictionary_set_string(message, kReason, reply->reason);
    xpc_dictionary_set_uuid(message, kSessionID, session_uuid);
    xpc_dictionary_set_double(message, kExpiry, reply->expiry_monotonic);
    xpc_dictionary_set_uint64(message, kState, reply->state);
    xpc_dictionary_set_uint64(message, kPower, reply->power_source);
    xpc_dictionary_set_bool(message, kSleepDisabled, reply->sleep_disabled);
    xpc_dictionary_set_int64(message, kACSleep, reply->ac_sleep_minutes);
    return message;
}

int ls_xpc_server_run(const char *mach_service, const ls_identity_policy_t *policy,
                      ls_server_handler_t handler, ls_server_connection_event_t event, void *context) {
    if (!mach_service || !policy || !handler || !event) return 64;
    struct ls_server_context *server = calloc(1, sizeof(*server));
    if (!server) return 70;
    server->policy = *policy; server->handler = handler; server->event = event; server->swift_context = context;
    atomic_init(&server->next_connection_id, 1);
    dispatch_queue_t queue = dispatch_queue_create("com.johnsilva.lidswitch.helper.xpc", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = xpc_connection_create_mach_service(mach_service, queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) { free(server); return 69; }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t incoming) {
        if (xpc_get_type(incoming) != XPC_TYPE_CONNECTION) return;
        xpc_connection_t peer = (xpc_connection_t)incoming;
        struct ls_peer_context *peer_context = calloc(1, sizeof(*peer_context));
        if (!peer_context) { xpc_connection_cancel(peer); return; }
        peer_context->identifier = atomic_fetch_add(&server->next_connection_id, 1);
        peer_context->server = server;
        xpc_connection_set_context(peer, peer_context);
        xpc_connection_set_finalizer_f(peer, free);
        xpc_connection_set_target_queue(peer, queue);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            struct ls_peer_context *pc = xpc_connection_get_context(peer);
            if (!pc) return;
            if (xpc_get_type(message) == XPC_TYPE_ERROR) {
                pc->server->event(pc->server->swift_context, pc->identifier, true);
                return;
            }
            /* Identity is established from this exact message before any request field is read. */
            if (!ls_validate_message_identity(message, xpc_connection_get_euid(peer), &pc->server->policy)) {
                pc->server->event(pc->server->swift_context, pc->identifier, true);
                xpc_connection_cancel(peer);
                return;
            }
            /* The process tuple is captured only after per-message code
               validation, and before decoding/calling into Swift. */
            ls_peer_identity_t peer_identity = {0};
            if (!ls_capture_peer_identity(peer, pc->server->policy.expected_euid, &peer_identity)) {
                pc->server->event(pc->server->swift_context, pc->identifier, true);
                xpc_connection_cancel(peer);
                return;
            }
            uint32_t operation = 0; char request_id[37] = {0}; char session_id[37] = {0};
            if (!ls_decode_request(message, &operation, request_id, session_id)) {
                pc->server->event(pc->server->swift_context, pc->identifier, true);
                xpc_connection_cancel(peer);
                return;
            }
            struct ls_reply_writer writer = {0};
            pc->server->handler(pc->server->swift_context, pc->identifier, &peer_identity, operation, request_id, session_id, &writer);
            if (!writer.set) {
                pc->server->event(pc->server->swift_context, pc->identifier, true);
                xpc_connection_cancel(peer);
                return;
            }
            xpc_object_t reply = ls_encode_reply(message, &writer.value);
            if (!reply) { xpc_connection_cancel(peer); return; }
            xpc_connection_send_message(peer, reply);
            xpc_release(reply);
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
    dispatch_main();
    return 0;
}

static bool ls_decode_reply(xpc_object_t message, const char *expected_request, struct ls_xpc_reply *reply) {
    if (!ls_dictionary_exact(message, 10, true)) return false;
    xpc_object_t schema = xpc_dictionary_get_value(message, kSchema);
    xpc_object_t request = xpc_dictionary_get_value(message, kRequestID);
    xpc_object_t session = xpc_dictionary_get_value(message, kSessionID);
    if (!schema || xpc_get_type(schema) != XPC_TYPE_UINT64 || xpc_uint64_get_value(schema) != LS_XPC_PROTOCOL_VERSION ||
        !request || xpc_get_type(request) != XPC_TYPE_UUID || !session || xpc_get_type(session) != XPC_TYPE_UUID) return false;
    char request_id[37] = {0}; char session_id[37] = {0};
    if (!ls_uuid_string(xpc_uuid_get_bytes(request), request_id) || strcmp(request_id, expected_request) != 0 ||
        !ls_uuid_string(xpc_uuid_get_bytes(session), session_id)) return false;
    xpc_object_t reason = xpc_dictionary_get_value(message, kReason);
    if (!reason || xpc_get_type(reason) != XPC_TYPE_STRING) return false;
    if (!ls_safe_copy(reply->reason, sizeof(reply->reason), xpc_string_get_string_ptr(reason)) ||
        !ls_safe_copy(reply->session_id, sizeof(reply->session_id), session_id)) return false;
    xpc_object_t result = xpc_dictionary_get_value(message, kResult);
    xpc_object_t expiry = xpc_dictionary_get_value(message, kExpiry);
    xpc_object_t state = xpc_dictionary_get_value(message, kState);
    xpc_object_t power = xpc_dictionary_get_value(message, kPower);
    xpc_object_t disabled = xpc_dictionary_get_value(message, kSleepDisabled);
    xpc_object_t ac = xpc_dictionary_get_value(message, kACSleep);
    if (!result || xpc_get_type(result) != XPC_TYPE_INT64 || !expiry || xpc_get_type(expiry) != XPC_TYPE_DOUBLE ||
        !state || xpc_get_type(state) != XPC_TYPE_UINT64 || !power || xpc_get_type(power) != XPC_TYPE_UINT64 ||
        !disabled || xpc_get_type(disabled) != XPC_TYPE_BOOL || !ac || xpc_get_type(ac) != XPC_TYPE_INT64) return false;
    const int64_t raw_result = xpc_int64_get_value(result);
    const int64_t raw_ac = xpc_int64_get_value(ac);
    const uint64_t raw_state = xpc_uint64_get_value(state);
    const uint64_t raw_power = xpc_uint64_get_value(power);
    const double raw_expiry = xpc_double_get_value(expiry);
    if (raw_result < INT32_MIN || raw_result > INT32_MAX || raw_ac < -1 || raw_ac > LS_AC_SLEEP_MINUTES_MAX ||
        raw_state > 3 || raw_power > 2 || !isfinite(raw_expiry)) return false;
    reply->result = (int32_t)raw_result;
    reply->expiry_monotonic = raw_expiry;
    reply->state = (uint32_t)raw_state;
    reply->power_source = (uint32_t)raw_power;
    reply->sleep_disabled = xpc_bool_get_value(disabled);
    reply->ac_sleep_minutes = (int32_t)raw_ac;
    return true;
}

bool ls_xpc_status_is_indeterminate(int status) {
    return status == LS_XPC_STATUS_INDETERMINATE_TIMEOUT || status == LS_XPC_STATUS_INDETERMINATE_INTERRUPTED;
}

ls_xpc_client_t *ls_xpc_client_create(const char *service, const ls_identity_policy_t *policy) {
    if (!service || !policy) return NULL;
    ls_xpc_client_t *client = calloc(1, sizeof(*client));
    if (!client) return NULL;
    client->helper_policy = *policy;
    client->serialization = dispatch_semaphore_create(1);
    if (!client->serialization) { free(client); return NULL; }
    atomic_init(&client->invalid, false);
    atomic_init(&client->references, 1);
    client->event_queue = dispatch_queue_create("com.johnsilva.lidswitch.client.xpc", DISPATCH_QUEUE_SERIAL);
    if (!client->event_queue) { dispatch_release(client->serialization); free(client); return NULL; }
    client->connection = xpc_connection_create_mach_service(service, client->event_queue, 0);
    if (!client->connection) {
        dispatch_release(client->event_queue);
        dispatch_release(client->serialization);
        free(client);
        return NULL;
    }
    xpc_connection_set_event_handler(client->connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) atomic_store(&client->invalid, true);
    });
    xpc_connection_activate(client->connection);
    return client;
}

void ls_xpc_client_cancel(ls_xpc_client_t *client) { if (client && client->connection) { atomic_store(&client->invalid, true); xpc_connection_cancel(client->connection); } }
void ls_xpc_client_release(ls_xpc_client_t *client) {
    if (!client) return;
    xpc_connection_set_event_handler(client->connection, ^(xpc_object_t event) { (void)event; });
    ls_xpc_client_cancel(client);
    /* Do not synchronously drain the reply queue here. A timed request keeps
       a callback reference and must be allowed to release serialization after
       it observes cancellation; destroying the client first would be a UAF. */
    /* The connection event handler itself still captures `client`; this
       barrier drains only that serial event queue after installing its no-op
       handler. Reply callbacks run elsewhere and are protected by refcounts. */
    dispatch_sync(client->event_queue, ^{});
    ls_xpc_client_release_reference(client);
}

int ls_xpc_client_send(ls_xpc_client_t *client, uint32_t operation, const char *request_id,
                       const char *session_id, double timeout, ls_xpc_reply_t **output) {
    if (!client || !request_id || !session_id || !output || !isfinite(timeout) || timeout <= 0 || timeout > 10 ||
        operation < LS_OPERATION_BEGIN || operation > LS_OPERATION_RECONNECT) return LS_XPC_STATUS_INVALID_ARGUMENT;
    *output = NULL;
    const int64_t timeout_ns = (int64_t)(timeout * (double)NSEC_PER_SEC);
    if (dispatch_semaphore_wait(client->serialization, dispatch_time(DISPATCH_TIME_NOW, timeout_ns)) != 0) {
        /* A caller that loses behind an existing request must poison this
           connection too: its owner can release safely, while the existing
           callback receives cancellation and performs the paired signal. */
        ls_xpc_client_cancel(client);
        return LS_XPC_STATUS_INDETERMINATE_TIMEOUT;
    }
    if (atomic_load(&client->invalid)) { dispatch_semaphore_signal(client->serialization); return LS_XPC_STATUS_INDETERMINATE_INTERRUPTED; }
    uuid_t request_uuid, session_uuid;
    if (uuid_parse(request_id, request_uuid) != 0 || uuid_parse(session_id, session_uuid) != 0) { dispatch_semaphore_signal(client->serialization); return LS_XPC_STATUS_INVALID_ARGUMENT; }
    struct ls_xpc_request *request_context = calloc(1, sizeof(*request_context));
    if (!request_context) { dispatch_semaphore_signal(client->serialization); return LS_XPC_STATUS_ALLOCATION_FAILURE; }
    request_context->expected_request = strdup(request_id);
    if (!request_context->expected_request) { free(request_context); dispatch_semaphore_signal(client->serialization); return LS_XPC_STATUS_ALLOCATION_FAILURE; }
    request_context->completion = dispatch_semaphore_create(0);
    if (!request_context->completion) {
        free(request_context->expected_request); free(request_context);
        dispatch_semaphore_signal(client->serialization);
        return LS_XPC_STATUS_ALLOCATION_FAILURE;
    }
    request_context->client = client;
    atomic_init(&request_context->state, LS_REQUEST_PENDING);
    /* Retain before the callback is handed to XPC. The caller may time out and
       Swift may then release its owning wrapper, but the callback still needs
       the connection and identity policy to authenticate its reply safely. */
    ls_xpc_client_retain(client);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    if (!message) { ls_xpc_request_release(request_context); dispatch_semaphore_signal(client->serialization); return LS_XPC_STATUS_ALLOCATION_FAILURE; }
    xpc_dictionary_set_uint64(message, kSchema, LS_XPC_PROTOCOL_VERSION);
    xpc_dictionary_set_uint64(message, kOperation, operation);
    xpc_dictionary_set_uuid(message, kRequestID, request_uuid);
    xpc_dictionary_set_uuid(message, kSessionID, session_uuid);
    xpc_connection_send_message_with_reply(client->connection, message, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(xpc_object_t reply) {
        int expected = LS_REQUEST_PENDING;
        if (atomic_load_explicit(&request_context->state, memory_order_acquire) == LS_REQUEST_PENDING) {
            int status = LS_XPC_STATUS_OK;
            if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
                status = (xpc_equal(reply, XPC_ERROR_CONNECTION_INTERRUPTED) || xpc_equal(reply, XPC_ERROR_CONNECTION_INVALID))
                    ? LS_XPC_STATUS_INDETERMINATE_INTERRUPTED
                    : LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE;
            } else if (!ls_validate_message_identity(reply, xpc_connection_get_euid(request_context->client->connection), &request_context->client->helper_policy)) {
                status = LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE;
            } else if (!ls_decode_reply(reply, request_context->expected_request, &request_context->decoded)) {
                status = LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE;
            }
            request_context->completion_status = status;
            if (atomic_compare_exchange_strong_explicit(
                    &request_context->state, &expected, LS_REQUEST_COMPLETED,
                    memory_order_release, memory_order_acquire)) {
                dispatch_semaphore_signal(request_context->completion);
                return;
            }
        }
        /* The caller won the deadline race and returned indeterminate. This
           callback is now the sole owner of the request and serialization. */
        dispatch_semaphore_signal(request_context->client->serialization);
        ls_xpc_request_release(request_context);
    });
    xpc_release(message);
    long waited = dispatch_semaphore_wait(request_context->completion, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (waited != 0) {
        int expected = LS_REQUEST_PENDING;
        if (atomic_compare_exchange_strong_explicit(
                &request_context->state, &expected, LS_REQUEST_ABANDONED,
                memory_order_acq_rel, memory_order_acquire)) {
            /* A local reply deadline is indeterminate transport, not authority
               loss. The callback will release serialization and its retained
               client reference after it observes this abandoned state. */
            /* Force one eventual XPC error callback so the callback-owned
               request reference and serialization token cannot strand. */
            ls_xpc_client_cancel(client);
            return LS_XPC_STATUS_INDETERMINATE_TIMEOUT;
        }
        /* A reply completed while the timed wait expired. Drain the callback
           signal, then consume the already authenticated reply normally. */
        if (expected != LS_REQUEST_COMPLETED || dispatch_semaphore_wait(request_context->completion, DISPATCH_TIME_FOREVER) != 0) {
            ls_xpc_request_release(request_context);
            dispatch_semaphore_signal(client->serialization);
            return LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE;
        }
    }
    if (atomic_load_explicit(&request_context->state, memory_order_acquire) != LS_REQUEST_COMPLETED ||
        request_context->completion_status != LS_XPC_STATUS_OK) {
        const int status = request_context->completion_status == LS_XPC_STATUS_OK
            ? LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE : request_context->completion_status;
        ls_xpc_request_release(request_context);
        dispatch_semaphore_signal(client->serialization);
        return status;
    }
    ls_xpc_reply_t *reply = malloc(sizeof(*reply));
    if (!reply) { ls_xpc_request_release(request_context); dispatch_semaphore_signal(client->serialization); return LS_XPC_STATUS_ALLOCATION_FAILURE; }
    *reply = request_context->decoded; *output = reply;
    ls_xpc_request_release(request_context);
    dispatch_semaphore_signal(client->serialization);
    return 0;
}

#define LS_REPLY_ACCESSOR(name, type, field, fallback) type name(const ls_xpc_reply_t *r) { return r ? r->field : fallback; }
LS_REPLY_ACCESSOR(ls_xpc_reply_result, int32_t, result, -1)
LS_REPLY_ACCESSOR(ls_xpc_reply_reason, const char *, reason, NULL)
LS_REPLY_ACCESSOR(ls_xpc_reply_session_id, const char *, session_id, NULL)
LS_REPLY_ACCESSOR(ls_xpc_reply_expiry_monotonic, double, expiry_monotonic, 0)
LS_REPLY_ACCESSOR(ls_xpc_reply_state, uint32_t, state, 0)
LS_REPLY_ACCESSOR(ls_xpc_reply_power_source, uint32_t, power_source, 0)
LS_REPLY_ACCESSOR(ls_xpc_reply_sleep_disabled, bool, sleep_disabled, false)
LS_REPLY_ACCESSOR(ls_xpc_reply_ac_sleep_minutes, int32_t, ac_sleep_minutes, -1)
void ls_xpc_reply_release(ls_xpc_reply_t *reply) { if (reply) { memset(reply, 0, sizeof(*reply)); free(reply); } }

static ls_code_identity_t *ls_copy_identity(SecStaticCodeRef code, bool dynamic) {
    ls_code_identity_t *identity = calloc(1, sizeof(*identity));
    if (!identity) return NULL;
    if (!ls_extract_identity(code, dynamic, identity)) { free(identity); return NULL; }
    return identity;
}
ls_code_identity_t *ls_copy_current_code_identity(void) {
    SecCodeRef code = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess || !code) return NULL;
    ls_code_identity_t *identity = ls_copy_identity((SecStaticCodeRef)code, true); CFRelease(code); return identity;
}
ls_code_identity_t *ls_copy_static_code_identity(const char *path) {
    if (!path) return NULL;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)path, strlen(path), false);
    if (!url) return NULL;
    SecStaticCodeRef code = NULL;
    OSStatus status = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code); CFRelease(url);
    if (status != errSecSuccess || !code) return NULL;
    ls_code_identity_t *identity = ls_copy_identity(code, false); CFRelease(code); return identity;
}
const char *ls_code_identity_identifier(const ls_code_identity_t *i) { return i ? i->identifier : NULL; }
const uint8_t *ls_code_identity_cdhash(const ls_code_identity_t *i) { return i ? i->cdhash : NULL; }
size_t ls_code_identity_cdhash_length(const ls_code_identity_t *i) { return i ? i->cdhash_length : 0; }
const char *ls_code_identity_team_identifier(const ls_code_identity_t *i) { return i ? i->team_identifier : NULL; }
void ls_code_identity_release(ls_code_identity_t *identity) { if (identity) { memset(identity, 0, sizeof(*identity)); free(identity); } }

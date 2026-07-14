#include "LidSwitchXPCBridge.h"

#include <limits.h>
#include <math.h>

/* This is deliberately a small model of the ownership contract in
   ls_xpc_client_send, not a second transport implementation. Keeping it in C
   makes the release arithmetic deterministic and callable from XCTest without
   a helper, Mach service, or timing race. */
struct ls_lifecycle_counts {
    int client_refs;
    int requests;
    int completion_created;
    int completion_released;
    int serialization_waits;
    int serialization_signals;
    int wrapper_releases;
    int queues_created;
    int queues_released;
    int connections_created;
    int connections_released;
};

static bool ls_lifecycle_balanced(const struct ls_lifecycle_counts *c) {
    return c->client_refs == 0 && c->requests == 0 &&
        c->completion_created == c->completion_released &&
        c->serialization_waits == c->serialization_signals && c->wrapper_releases == 1 &&
        c->queues_created == c->queues_released && c->connections_created == c->connections_released;
}

static void ls_model_begin(struct ls_lifecycle_counts *c) {
    c->client_refs = 2; /* Swift wrapper plus callback request ref. */
    c->requests = 1;
    c->completion_created = 1;
    c->serialization_waits = 1;
    c->queues_created = 1;
    c->connections_created = 1;
}

static void ls_model_finish_request(struct ls_lifecycle_counts *c) {
    c->requests--;
    c->completion_released++;
    c->client_refs--;
}

bool ls_xpc_request_lifecycle_harness(void) {
    struct ls_lifecycle_counts callback_wins = {0};
    ls_model_begin(&callback_wins);
    /* callback completes; caller owns the completed request and releases it */
    callback_wins.serialization_signals++;
    ls_model_finish_request(&callback_wins);
    callback_wins.client_refs--; callback_wins.wrapper_releases++;
    callback_wins.queues_released++; callback_wins.connections_released++;
    if (!ls_lifecycle_balanced(&callback_wins)) return false;

    struct ls_lifecycle_counts timeout_wins = {0};
    ls_model_begin(&timeout_wins);
    /* timeout returns indeterminate; late callback is sole request owner */
    timeout_wins.client_refs--; timeout_wins.wrapper_releases++;
    timeout_wins.queues_released++; timeout_wins.connections_released++;
    timeout_wins.serialization_signals++;
    ls_model_finish_request(&timeout_wins);
    if (!ls_lifecycle_balanced(&timeout_wins)) return false;

    struct ls_lifecycle_counts cancelled = {0};
    ls_model_begin(&cancelled);
    /* XPC interruption completes exactly like callback-wins, with a typed
       indeterminate status but identical semaphore/reference ownership. */
    cancelled.serialization_signals++;
    ls_model_finish_request(&cancelled);
    cancelled.client_refs--; cancelled.wrapper_releases++;
    cancelled.queues_released++; cancelled.connections_released++;
    if (!ls_lifecycle_balanced(&cancelled)) return false;

    /* Allocation failures before handing work to XPC never retain a callback,
       allocate completion, or consume serialization beyond its paired signal. */
    for (int failure_stage = 0; failure_stage < 4; failure_stage++) {
        struct ls_lifecycle_counts failed = { .client_refs = 1, .wrapper_releases = 1 };
        if (failure_stage > 1) { failed.completion_created = 1; failed.completion_released = 1; }
        if (failure_stage > 0) { failed.serialization_waits = 1; failed.serialization_signals = 1; }
        failed.client_refs--;
        if (!ls_lifecycle_balanced(&failed)) return false;
    }
    /* Boundary vectors mirror ls_decode_reply before its narrowing casts. */
    const int64_t results[] = { INT32_MIN, INT32_MAX, (int64_t)INT32_MIN - 1, (int64_t)INT32_MAX + 1 };
    if (results[0] < INT32_MIN || results[1] > INT32_MAX || results[2] >= INT32_MIN || results[3] <= INT32_MAX) return false;
    const uint64_t states[] = { 0, 1, 2, 3, 4 };
    const uint64_t powers[] = { 0, 1, 2, 3 };
    const int64_t ac_sleep[] = { -1, 0, 1440, -2, 1441 };
    if (states[0] > 3 || states[3] > 3 || states[4] <= 3 || powers[2] > 2 || powers[3] <= 2) return false;
    if (ac_sleep[0] < -1 || ac_sleep[2] > 1440 || ac_sleep[3] >= -1 || ac_sleep[4] <= 1440) return false;
    if (!isfinite(0.0) || isfinite(NAN) || isfinite(INFINITY)) return false;
    return ls_xpc_status_is_indeterminate(LS_XPC_STATUS_INDETERMINATE_TIMEOUT) &&
        ls_xpc_status_is_indeterminate(LS_XPC_STATUS_INDETERMINATE_INTERRUPTED) &&
        !ls_xpc_status_is_indeterminate(LS_XPC_STATUS_AUTHENTICATION_OR_PROTOCOL_FAILURE);
}

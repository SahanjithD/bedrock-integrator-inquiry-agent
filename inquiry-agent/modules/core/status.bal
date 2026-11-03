// Health status for `GET /ping`.
//
// AgentCore Runtime keeps a session alive past its idle timeout while the container
// reports `HealthyBusy`. `time_of_last_update` is the time the status last changed. It is
// never refreshed on a ping, so an idle container is not kept alive by accident.

import ballerina/time;

# The body of a `GET /ping` response.
public type PingResponse record {|
    # `Healthy` when idle, `HealthyBusy` while background work runs
    "Healthy"|"HealthyBusy" status;
    # Unix time in seconds of the last status change
    int time_of_last_update;
|};

isolated record {|int active; int changedAt;|} work = {active: 0, changedAt: time:utcNow()[0]};

# Records that a background job started.
public isolated function jobStarted() {
    lock {
        if work.active == 0 {
            work.changedAt = time:utcNow()[0];
        }
        work.active += 1;
    }
}

# Records that a background job finished, successfully or not.
public isolated function jobFinished() {
    lock {
        if work.active > 0 {
            work.active -= 1;
            if work.active == 0 {
                work.changedAt = time:utcNow()[0];
            }
        }
    }
}

# Returns the current health status.
#
# + return - The ping response
public isolated function currentStatus() returns PingResponse {
    lock {
        return {
            status: work.active > 0 ? "HealthyBusy" : "Healthy",
            time_of_last_update: work.changedAt
        };
    }
}

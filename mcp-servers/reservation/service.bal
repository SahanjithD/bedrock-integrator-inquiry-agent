// Reservation tools for the inquiry agent, served over MCP (streamable HTTP, stateless).
// AgentCore Runtime expects MCP servers on 0.0.0.0:8000 at /mcp.
//
// Data is synthetic and loaded from data/reservations.json at startup. Changes made by
// the write tool live only in this runtime session's memory.

import ballerina/io;
import ballerina/mcp;
import ballerina/time;

configurable string dataFile = "data/reservations.json";

final ReservationData & readonly seed = check loadSeed();

// Confirmations issued by this process, and receipts by approval ID (idempotency).
isolated Confirmation[] issued = [];
isolated map<ReissueReceipt> receipts = {};

function loadSeed() returns ReservationData & readonly|error {
    json content = check io:fileReadJson(dataFile);
    ReservationData data = check content.cloneWithType();
    return data.cloneReadOnly();
}

listener mcp:StreamableHttpListener mcpListener = check new (8000);

// TODO(verify): AgentCore Runtime adds an Mcp-Session-Id header to each request; confirm that
// STATELESS mode accepts it.
@mcp:StreamableHttpServiceConfig {
    info: {name: "reservation-tools", version: "0.1.0"},
    sessionMode: mcp:STATELESS
}
service mcp:StreamableHttpService /mcp on mcpListener {

    # Lists the reservations held by a guest, newest stay first. Read-only.
    #
    # + guestRef - Guest reference, e.g. `G-10427`
    # + return - Reservation summaries
    remote function findReservations(string guestRef) returns ReservationSummary[] {
        return from Reservation r in seed.reservations
            where r.guestRef == guestRef
            order by r.checkIn descending
            select {
                reservationId: r.reservationId,
                property: r.property,
                checkIn: r.checkIn,
                checkOut: r.checkOut,
                status: r.status,
                version: r.version
            };
    }

    # Gets the current state of a reservation, including its version number. Read-only.
    #
    # + reservationId - Reservation ID, e.g. `R-48213`
    # + return - The reservation, or an error if it does not exist
    remote function getReservation(string reservationId) returns Reservation|error {
        return findReservation(reservationId);
    }

    # Lists every change made to a reservation, with the status of the confirmation job each
    # change triggered. Read-only.
    #
    # + reservationId - Reservation ID
    # + return - Changes in version order
    remote function getReservationHistory(string reservationId) returns ReservationChange[]|error {
        _ = check findReservation(reservationId);
        return from ReservationChange c in seed.history
            where c.reservationId == reservationId
            order by c.version ascending
            select c;
    }

    # Gets the latest confirmation sent to the guest for a reservation. Compare its
    # `reservationVersion` and dates with the reservation itself. Read-only.
    #
    # + reservationId - Reservation ID
    # + return - The latest confirmation, or an error if none was issued
    remote function getConfirmation(string reservationId) returns Confirmation|error {
        _ = check findReservation(reservationId);
        return latestConfirmation(reservationId);
    }

    # Issues and sends a new confirmation that matches the current reservation version.
    # WRITE: call only with an approved change. Repeating a call with the same `approvalId`
    # returns the first result instead of sending another confirmation.
    #
    # + reservationId - Reservation ID
    # + approvalId - Approval reference, `<caseId>#<proposalVersion>`
    # + return - The new confirmation, or an error
    remote function reissueConfirmation(string reservationId, string approvalId) returns ReissueReceipt|error {
        if approvalId.trim() == "" {
            return error("approvalId is required for a write");
        }
        ReissueReceipt? earlier;
        lock {
            earlier = receipts[approvalId].clone();
        }
        if earlier is ReissueReceipt {
            earlier.outcome = "ALREADY_APPLIED";
            return earlier;
        }
        Reservation reservation = check findReservation(reservationId);
        Confirmation current = check latestConfirmation(reservationId);
        if current.reservationVersion == reservation.version {
            return error(string `Confirmation ${current.confirmationNumber} already matches version ${reservation.version}`);
        }
        Confirmation fresh = {
            confirmationNumber: string `CNF-${reservationId.substring(2)}-${reservation.version}`,
            reservationId,
            reservationVersion: reservation.version,
            checkIn: reservation.checkIn,
            checkOut: reservation.checkOut,
            roomType: reservation.roomType,
            issuedAt: time:utcToString(time:utcNow()),
            deliveryStatus: "QUEUED"
        };
        ReissueReceipt receipt = {outcome: "REISSUED", approvalId, confirmation: fresh};
        lock {
            issued.push(fresh.clone());
        }
        lock {
            receipts[approvalId] = receipt.clone();
        }
        return receipt;
    }
}

function findReservation(string reservationId) returns Reservation|error {
    foreach Reservation r in seed.reservations {
        if r.reservationId == reservationId {
            return r;
        }
    }
    return error(string `Reservation ${reservationId} not found`);
}

function latestConfirmation(string reservationId) returns Confirmation|error {
    Confirmation[] issuedHere;
    lock {
        issuedHere = issued.clone();
    }
    Confirmation[] newestFirst = from Confirmation c in [...seed.confirmations, ...issuedHere]
        where c.reservationId == reservationId
        order by c.reservationVersion descending, c.issuedAt descending
        select c;
    if newestFirst.length() == 0 {
        return error(string `No confirmation issued for ${reservationId}`);
    }
    return newestFirst[0];
}

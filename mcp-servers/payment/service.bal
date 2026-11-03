// Payment tools for the inquiry agent, served over MCP (streamable HTTP, stateless).
// AgentCore Runtime expects MCP servers on 0.0.0.0:8000 at /mcp.
//
// Data is synthetic and loaded from data/payments.json at startup. Card details are limited
// to a brand and the last four digits. Refunds made by the write tool live only in this
// runtime session's memory; no payment processor is called.

import ballerina/io;
import ballerina/mcp;
import ballerina/time;

configurable string dataFile = "data/payments.json";

final PaymentData & readonly seed = check loadSeed();

// Refunds made by this process, and receipts by approval ID (idempotency).
isolated Charge[] refunds = [];
isolated map<RefundReceipt> receipts = {};

function loadSeed() returns PaymentData & readonly|error {
    json content = check io:fileReadJson(dataFile);
    PaymentData data = check content.cloneWithType();
    return data.cloneReadOnly();
}

listener mcp:StreamableHttpListener mcpListener = check new (8000);

// TODO(verify): AgentCore Runtime adds an Mcp-Session-Id header to each request; confirm that
// STATELESS mode accepts it.
@mcp:StreamableHttpServiceConfig {
    info: {name: "payment-tools", version: "0.1.0"},
    sessionMode: mcp:STATELESS
}
service mcp:StreamableHttpService /mcp on mcpListener {

    # Lists card authorizations, captures and refunds for a guest, newest first. Read-only.
    #
    # + guestRef - Guest reference, e.g. `G-20934`
    # + return - Charges, including the descriptor shown on the card statement
    remote function listCharges(string guestRef) returns Charge[] {
        return from Charge c in allCharges()
            where c.guestRef == guestRef
            order by c.createdAt descending
            select c;
    }

    # Gets one charge, including how it relates to other charges. Read-only.
    #
    # + chargeId - Charge ID, e.g. `CH-7003`
    # + return - The charge, or an error if not found
    remote function getCharge(string chargeId) returns Charge|error {
        return findCharge(chargeId);
    }

    # Gets the folio (itemized bill) for a stay: lines, payments applied and card holds.
    # Read-only.
    #
    # + reservationId - Reservation ID, e.g. `R-50642`
    # + return - The folio, or an error if not found
    remote function getFolio(string reservationId) returns Folio|error {
        foreach Folio f in seed.folios {
            if f.reservationId == reservationId {
                return f;
            }
        }
        return error(string `No folio for reservation ${reservationId}`);
    }

    # Refunds all or part of a captured charge to the original card.
    # WRITE: call only with an approved change. Repeating a call with the same `approvalId`
    # returns the first result instead of refunding again.
    #
    # + chargeId - The captured charge to refund
    # + amount - Amount to refund, no more than what is left on the charge
    # + approvalId - Approval reference, `<caseId>#<proposalVersion>`
    # + return - The refund, or an error
    remote function refundCharge(string chargeId, decimal amount, string approvalId) returns RefundReceipt|error {
        if approvalId.trim() == "" {
            return error("approvalId is required for a write");
        }
        RefundReceipt? earlier;
        lock {
            earlier = receipts[approvalId].clone();
        }
        if earlier is RefundReceipt {
            earlier.outcome = "ALREADY_APPLIED";
            return earlier;
        }
        Charge charge = check findCharge(chargeId);
        if charge.kind != "CAPTURE" {
            return error(string `${chargeId} is a ${charge.kind}; only captures can be refunded`);
        }
        decimal alreadyRefunded = decimal:sum(...from Charge r in allCharges()
            where r?.refundOf == chargeId
            select r.amount);
        decimal remaining = charge.amount - alreadyRefunded;
        if amount <= 0d || amount > remaining {
            return error(string `Refund must be more than 0 and at most ${remaining} ${charge.currency}`);
        }
        Charge refund = {
            chargeId: string `RF-${chargeId.substring(3)}`,
            guestRef: charge.guestRef,
            reservationId: charge.reservationId,
            card: charge.card,
            kind: "REFUND",
            amount,
            currency: charge.currency,
            descriptor: string `REFUND ${charge.descriptor}`,
            createdAt: time:utcToString(time:utcNow()),
            status: "PENDING_SETTLEMENT",
            refundOf: chargeId,
            note: string `Refund approved under ${approvalId}`
        };
        lock {
            refunds.push(refund.clone());
        }
        RefundReceipt receipt = {outcome: "REFUNDED", approvalId, refund};
        lock {
            receipts[approvalId] = receipt.clone();
        }
        return receipt;
    }
}

function allCharges() returns Charge[] {
    Charge[] madeHere;
    lock {
        madeHere = refunds.clone();
    }
    return [...seed.charges, ...madeHere];
}

function findCharge(string chargeId) returns Charge|error {
    foreach Charge c in allCharges() {
        if c.chargeId == chargeId {
            return c;
        }
    }
    return error(string `Charge ${chargeId} not found`);
}

// Loyalty tools for the inquiry agent, served over MCP (streamable HTTP, stateless).
// AgentCore Runtime expects MCP servers on 0.0.0.0:8000 at /mcp.
//
// Data is synthetic and loaded from data/loyalty.json at startup. Changes made by the write
// tool live only in this runtime session's memory.

import ballerina/io;
import ballerina/mcp;
import ballerina/time;

configurable string dataFile = "data/loyalty.json";
# Largest credit one approval may grant, as a guard against a malformed proposal.
configurable int maxCreditPerStay = 20000;

final LoyaltyData & readonly seed = check loadSeed();

// Adjustments made by this process, and receipts by approval ID (idempotency).
isolated PointsActivity[] adjustments = [];
isolated map<CreditReceipt> receipts = {};

function loadSeed() returns LoyaltyData & readonly|error {
    json content = check io:fileReadJson(dataFile);
    LoyaltyData data = check content.cloneWithType();
    return data.cloneReadOnly();
}

listener mcp:StreamableHttpListener mcpListener = check new (8000);

// TODO(verify): AgentCore Runtime adds an Mcp-Session-Id header to each request; confirm that
// STATELESS mode accepts it.
@mcp:StreamableHttpServiceConfig {
    info: {name: "loyalty-tools", version: "0.1.0"},
    sessionMode: mcp:STATELESS
}
service mcp:StreamableHttpService /mcp on mcpListener {

    # Gets a loyalty member's tier and current points balance. Read-only.
    #
    # + memberId - Member ID, e.g. `M-77310`
    # + return - The member, or an error if not found
    remote function getMember(string memberId) returns Member|error {
        Member member = check findMember(memberId);
        member.pointsBalance += adjustedPoints(memberId);
        return member;
    }

    # Lists a member's stays with qualifying spend and the status of each points accrual.
    # Read-only.
    #
    # + memberId - Member ID
    # + return - Stays, most recent first
    remote function listStays(string memberId) returns Stay[]|error {
        _ = check findMember(memberId);
        return from Stay s in seed.stays
            where s.memberId == memberId
            order by s.checkIn descending
            select s;
    }

    # Lists points earned, redeemed and adjusted for a member, most recent first. Read-only.
    #
    # + memberId - Member ID
    # + return - Points activity
    remote function listPointsActivity(string memberId) returns PointsActivity[]|error {
        _ = check findMember(memberId);
        PointsActivity[] madeHere;
        lock {
            madeHere = adjustments.clone();
        }
        return from PointsActivity a in [...seed.activity, ...madeHere]
            where a.memberId == memberId
            order by a.postedAt descending
            select a;
    }

    # Credits points for a completed stay whose accrual did not post.
    # WRITE: call only with an approved change. Repeating a call with the same `approvalId`
    # returns the first result instead of crediting again.
    #
    # + memberId - Member ID
    # + stayId - The stay the points are for
    # + points - Points to credit
    # + approvalId - Approval reference, `<caseId>#<proposalVersion>`
    # + return - The posted adjustment and the new balance, or an error
    remote function creditPoints(string memberId, string stayId, int points, string approvalId)
            returns CreditReceipt|error {
        if approvalId.trim() == "" {
            return error("approvalId is required for a write");
        }
        CreditReceipt? earlier;
        lock {
            earlier = receipts[approvalId].clone();
        }
        if earlier is CreditReceipt {
            earlier.outcome = "ALREADY_APPLIED";
            return earlier;
        }
        Member member = check findMember(memberId);
        Stay stay = check findStay(stayId);
        if stay.memberId != memberId {
            return error(string `Stay ${stayId} does not belong to member ${memberId}`);
        }
        if stay.accrualStatus == "POSTED" {
            return error(string `Points for stay ${stayId} were already posted`);
        }
        if adjustedPointsForStay(stayId) != 0 {
            return error(string `Points for stay ${stayId} were already adjusted`);
        }
        if points <= 0 || points > maxCreditPerStay {
            return error(string `Points must be between 1 and ${maxCreditPerStay}`);
        }
        PointsActivity adjustment = {
            activityId: string `PA-ADJ-${stayId.substring(2)}`,
            memberId,
            postedAt: time:utcToString(time:utcNow()),
            kind: "ADJUSTMENT",
            stayId,
            points,
            description: string `Missing accrual for stay ${stayId} (${approvalId})`
        };
        lock {
            adjustments.push(adjustment.clone());
        }
        CreditReceipt receipt = {
            outcome: "CREDITED",
            approvalId,
            activity: adjustment,
            newBalance: member.pointsBalance + adjustedPoints(memberId)
        };
        lock {
            receipts[approvalId] = receipt.clone();
        }
        return receipt;
    }
}

function findMember(string memberId) returns Member|error {
    foreach Member m in seed.members {
        if m.memberId == memberId {
            // A new, mutable copy: the seed is read-only.
            return {...m};
        }
    }
    return error(string `Member ${memberId} not found`);
}

function findStay(string stayId) returns Stay|error {
    foreach Stay s in seed.stays {
        if s.stayId == stayId {
            return s;
        }
    }
    return error(string `Stay ${stayId} not found`);
}

function adjustedPoints(string memberId) returns int {
    PointsActivity[] madeHere;
    lock {
        madeHere = adjustments.clone();
    }
    return int:sum(...from PointsActivity a in madeHere where a.memberId == memberId select a.points);
}

function adjustedPointsForStay(string stayId) returns int {
    PointsActivity[] madeHere;
    lock {
        madeHere = adjustments.clone();
    }
    return int:sum(...from PointsActivity a in madeHere where a?.stayId == stayId select a.points);
}

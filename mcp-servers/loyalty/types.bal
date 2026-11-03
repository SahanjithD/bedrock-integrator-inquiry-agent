type Member record {|
    string memberId;
    string guestRef;
    string name;
    string email;
    string tier;
    int pointsBalance;
    string joinedOn;
|};

type Stay record {|
    string stayId;
    string memberId;
    string reservationId;
    string property;
    string checkIn;
    string checkOut;
    int nights;
    decimal qualifyingSpend;
    string folioClosedAt;
    "POSTED"|"PENDING"|"FAILED" accrualStatus;
    string accrualNote;
|};

type PointsActivity record {|
    string activityId;
    string memberId;
    string postedAt;
    "EARN"|"REDEEM"|"ADJUSTMENT" kind;
    string stayId?;
    int points;
    string description;
|};

type LoyaltyData record {|
    Member[] members;
    Stay[] stays;
    PointsActivity[] activity;
|};

type CreditReceipt record {|
    "CREDITED"|"ALREADY_APPLIED" outcome;
    string approvalId;
    PointsActivity activity;
    int newBalance;
|};

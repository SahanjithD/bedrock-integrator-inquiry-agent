type Charge record {|
    string chargeId;
    string guestRef;
    string reservationId;
    string card;
    "AUTHORIZATION"|"CAPTURE"|"REFUND" kind;
    decimal amount;
    string currency;
    string descriptor;
    string createdAt;
    string status;
    string capturedAs?;
    string sourceAuthorization?;
    string refundOf?;
    string note;
|};

type FolioLine record {|
    string date;
    string description;
    decimal amount;
|};

type AppliedPayment record {|
    string chargeId;
    decimal amount;
|};

type Hold record {|
    string chargeId;
    decimal amount;
    string expectedAction;
|};

type Folio record {|
    string reservationId;
    string guestRef;
    string status;
    string closedAt;
    FolioLine[] lines;
    decimal incidentalsTotal;
    decimal total;
    AppliedPayment[] paymentsApplied;
    Hold[] holds;
    decimal balance;
|};

type PaymentData record {|
    Charge[] charges;
    Folio[] folios;
|};

type RefundReceipt record {|
    "REFUNDED"|"ALREADY_APPLIED" outcome;
    string approvalId;
    Charge refund;
|};

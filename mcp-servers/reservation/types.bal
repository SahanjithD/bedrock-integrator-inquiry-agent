type Reservation record {|
    string reservationId;
    string guestRef;
    string guestName;
    string guestEmail;
    string property;
    string roomType;
    string checkIn;
    string checkOut;
    string status;
    int version;
    string bookedVia;
    string updatedAt;
|};

type ReservationSummary record {|
    string reservationId;
    string property;
    string checkIn;
    string checkOut;
    string status;
    int version;
|};

type ReservationChange record {|
    string reservationId;
    int version;
    string changedAt;
    string channel;
    string change;
    string confirmationJob;
    string confirmationJobError?;
|};

type Confirmation record {|
    string confirmationNumber;
    string reservationId;
    int reservationVersion;
    string checkIn;
    string checkOut;
    string roomType;
    string issuedAt;
    string deliveryStatus;
|};

type ReservationData record {|
    Reservation[] reservations;
    ReservationChange[] history;
    Confirmation[] confirmations;
|};

type ReissueReceipt record {|
    "REISSUED"|"ALREADY_APPLIED" outcome;
    string approvalId;
    Confirmation confirmation;
|};

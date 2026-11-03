# Runbook: guest does not recognize a card charge

Applies to: guests who see a charge from one of the group's properties that they cannot match
to a stay or a purchase.

## Background

Three kinds of card activity can appear for a stay:

- **Authorization (hold)** for incidentals, taken at check-in. It should be released at
  checkout once the folio closes, and the guest is never charged for it.
- **Capture** of the final folio at checkout. Its descriptor includes the reservation number.
- **Capture of incidentals** by the automated reconciliation job, used only when the folio
  shows incidentals that were not settled at checkout.

## Investigation steps

1. List the guest's charges. Note each charge's kind, amount, descriptor and status.
2. Get the charge the guest is asking about. Check `sourceAuthorization` and `note`.
3. Get the folio for the related reservation. Compare `incidentalsTotal`, `paymentsApplied`,
   `holds` and `balance` with the charges.

## Diagnosis

| Finding | Cause |
| --- | --- |
| Capture matches the folio total and the descriptor has the reservation number | Legitimate stay charge; explain the descriptor |
| Incidentals capture, but the folio shows no incidentals and a zero balance | The hold was captured instead of released; the guest was overcharged |
| Authorization still open after checkout | Hold not released; it drops off within the card issuer's window, no refund needed |

## Fix

For a hold captured in error, propose `payment___refundCharge` for the incidentals capture
(`chargeId`) and its full `amount`. Never refund the folio settlement charge.

## Reply guidance

Explain what the descriptor means in plain words, confirm the refund amount, and say that
refunds usually appear on the statement within 5 to 10 business days. Refer to the card only
by its brand and last four digits, or not at all.

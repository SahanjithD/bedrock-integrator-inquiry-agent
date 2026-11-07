# Runbook: booking change not reflected on the confirmation

Applies to: guests who changed dates, room type or guest count, and whose confirmation still
shows the earlier details.

## Background

Every change to a reservation creates a new reservation version. Each version starts a
confirmation job that renders and sends a new confirmation. If that job fails, the reservation
is correct but the guest keeps the previous confirmation.

## Investigation steps

1. Get the reservation and note its current `version`, dates and room type.
2. Get the reservation history. Find the change the guest describes and check the
   `confirmationJob` status recorded for that version.
3. Get the latest confirmation and compare its `reservationVersion`, dates and room type with
   the reservation.

## Diagnosis

| Reservation | Latest confirmation | Cause |
| --- | --- | --- |
| Shows the new details | Older version, job `FAILED` | Confirmation job failed after the change was saved |
| Shows the old details | Matches the reservation | The change was never saved; ask the guest to make it again or make it for them |
| Shows the new details | Same version, job `SENT` | Delivery problem; check the guest's spam folder or contact details |

## Fix

When the confirmation is older than the reservation and the job failed, propose
`reservation___reissueConfirmation` with the `reservationId`. Do not change the reservation
itself: it is already correct.

## Reply guidance

Confirm the dates the guest now holds, say a new confirmation is on its way, and apologize
for the confusion. Do not quote internal job names.

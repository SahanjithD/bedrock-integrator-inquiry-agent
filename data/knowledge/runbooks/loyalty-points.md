# Runbook: loyalty points missing after a stay

Applies to: members who completed a stay and do not see the points for it.

## Background

A nightly batch posts points for stays whose folio is closed. Points normally appear within
72 hours of checkout. If the folio is still open when the batch runs, the batch marks the
accrual `FAILED` and does not queue the stay again.

## Investigation steps

1. Get the member to confirm the tier and current balance.
2. List the member's stays. Find the stay the guest describes and check `accrualStatus`,
   `accrualNote`, `folioClosedAt` and `qualifyingSpend`.
3. List points activity and confirm there is no `EARN` or `ADJUSTMENT` entry for that stay.
4. Work out the points owed with the earning policy (see "Points earning and adjustments").

## Diagnosis

| Accrual status | Time since checkout | Action |
| --- | --- | --- |
| `PENDING` | Under 72 hours | Nothing to fix; tell the guest when to expect the points |
| `FAILED` | Any | Credit the missing points |
| `POSTED` | Any | Show the guest the posted entry; nothing is missing |

## Fix

For a `FAILED` accrual with no later adjustment, propose `loyalty___creditPoints` with the
`memberId`, `stayId` and the points owed. Never credit a stay that already has posted points.

## Reply guidance

Name the stay by property and dates, state how many points were added, and mention that the
balance updates right away.

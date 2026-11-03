# Internal MCP servers

Three WSO2 Integrator (Ballerina) MCP servers stand in for a hotel and resort group's internal
reservation, loyalty and payment systems. Each one runs on Amazon Bedrock AgentCore Runtime
with the MCP protocol and is registered as a target on Amazon Bedrock AgentCore Gateway. The
inquiry agent reaches all of them through the gateway's one MCP endpoint.

Each server keeps its own synthetic data in memory, loaded at startup from `data/*.json`. No
separate mock service is deployed.

| Server | Read-only tools (investigate action) | Write tool (apply action only) |
| --- | --- | --- |
| `reservation` | `findReservations`, `getReservation`, `getReservationHistory`, `getConfirmation` | `reissueConfirmation` |
| `loyalty` | `getMember`, `listStays`, `listPointsActivity` | `creditPoints` |
| `payment` | `listCharges`, `getCharge`, `getFolio` | `refundCharge` |

Through the gateway, tool names carry the target name as a prefix, for example
`loyalty___creditPoints`. The inquiry agent's tool lists are in
`../inquiry-agent/modules/core/tools.bal`.

## Contract with AgentCore Runtime

- Listens on `0.0.0.0:8000`, path `/mcp`, streamable HTTP in stateless mode
  (`sessionMode: mcp:STATELESS`).
- ARM64 container image (`docker buildx build --platform linux/arm64`).
- Tool descriptions come from the Ballerina doc comments on each `remote function`.

## Write tools

- Every write tool requires an `approvalId` (`<caseId>#<proposalVersion>`) and is idempotent per
  `approvalId`: a repeated call returns the first receipt with `outcome: "ALREADY_APPLIED"`.
- Each write checks the record first, for example that the confirmation is really out of date,
  that the stay has no posted points, or that the refund does not exceed what was captured.
- Changes are kept in memory for the life of the runtime session. AgentCore Runtime gives each
  session its own microVM, so a later read in another session will not see the change. Check
  the result through the case status and the write tool's response stored on the case.

## Scenario data

| Inquiry | Records | What the data shows |
| --- | --- | --- |
| Changed dates, old confirmation | Guest `G-10427`, reservation `R-48213` | Version 3 moved the dates; the confirmation job for that change failed, so the latest confirmation is still version 2. |
| Missing loyalty points | Member `M-77310`, stay `S-90551` | The accrual batch ran before the folio closed and skipped the stay. |
| Unrecognized card charge | Guest `G-20934`, reservation `R-50642` | The check-in hold `CH-7001` was captured as `CH-7003` under the descriptor `RESORT INCIDENTALS 0423`, although the folio shows no incidentals. |

Names, email addresses and card endings are made up. Email addresses use `example.com`.

## Build and run locally

```bash
cd reservation
bal run
```

```bash
docker buildx build --platform linux/arm64 -t reservation-mcp reservation
```

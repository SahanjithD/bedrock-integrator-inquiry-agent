# Inquiry agent

A WSO2 Integrator (Ballerina) service that runs on Amazon ECS (Fargate, ARM64). It has no
HTTP endpoints. Two SQS listeners pull work from the support console's queues:

| Listener | Queue | Work |
| --- | --- | --- |
| Jobs | `<project>-jobs` | Investigate an inquiry and save findings for approval |
| Decisions | `<project>-decisions` | Reject, or apply the approved change |

## Investigate (jobs queue)

1. Claims the case with a conditional update: `QUEUED` → `INVESTIGATING`. The claim records the
   SQS message ID, so a redelivery of the same message may resume, but a second job for the
   same case is skipped.
2. Runs a stateless `ai:Agent` (`memory = ()`) with:
   - the Bedrock Converse API (`ballerinax/ai.aws.bedrock`) and a guardrail that masks
     personal data,
   - `searchKnowledge`, which retrieves runbooks, policies and resolved cases from the managed
     knowledge base,
   - the gateway's read-only tools only (`ai:McpToolKit` with `permittedTools`), using the
     investigator Cognito client, which has the read scope only.
3. Checks the proposal (`modules/core/tools.bal`): known write tool, required arguments, IDs
   found in the evidence, no `approvalId` from the model.
4. Saves findings, the proposed fix and the draft reply, increments `proposalVersion`, and sets
   `PENDING_APPROVAL` (or `NO_ACTION_PROPOSED`).
5. Deletes the SQS message only after the save succeeds.

If an attempt fails, the message becomes visible again after `retryDelaySeconds`. After the
third attempt the case is marked `FAILED`, and SQS moves the message to the jobs DLQ.

## Apply (decisions queue)

The decision message carries only `caseId`, `decision` and `proposalVersion`.

- **Rejected:** `PENDING_APPROVAL` → `REJECTED`, if the version is current.
- **Approved:**
  1. Claim: `PENDING_APPROVAL` → `APPLYING`, if the version is current.
  2. If the case is already `APPLYING` (a redelivered decision), an earlier attempt may have
     made the change. The tool is not called again; the case becomes `NEEDS_REVIEW`.
  3. Load the proposal from the case (never from the message) and call that one write tool
     through the gateway, with the applier Cognito client (write scope) and
     `approvalId = <caseId>#<proposalVersion>`.
  4. `APPLYING` → `APPLIED`, storing the tool's response.
  5. Add a resolved-case summary to the knowledge base's custom data source.

A decision that no longer matches the case (stale version, already decided) is logged and
deleted.

## Visibility timeouts

An investigation can take several minutes. The listener receives jobs with a 900-second
visibility timeout (`jobVisibilitySeconds`), longer than the longest expected run, so another
task does not pick up the same job meanwhile. The jobs queue uses the same default. Raise both
together if your investigations take longer.

## Layout

| File | Purpose |
| --- | --- |
| `listeners.bal` | The two SQS listeners, message parsing, delete and retry |
| `investigate.bal` | Investigation agent and the `searchKnowledge` tool |
| `apply.bal` | Reject and apply flows, knowledge base ingestion |
| `cases.bal` | DynamoDB reads and conditional status updates |
| `clients.bal`, `config.bal`, `prompts.bal` | Clients, settings, prompts |
| `modules/core` | Types, tool lists, job, decision and proposal checks (unit tested) |

## Build and test

```bash
bal test
```

```bash
docker buildx build --platform linux/arm64 -t inquiry-agent .
```

To run locally, copy `Config.toml.example` to `Config.toml` and fill it in. Set
`INVESTIGATOR_CLIENT_SECRET` and `APPLIER_CLIENT_SECRET`, then run `bal run` with AWS
credentials that can reach the same resources. Stop the ECS service first, or set its
desired count to 0, if you don't want it to compete for messages.

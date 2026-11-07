# Support portal

A WSO2 Integrator (Ballerina) HTTP service that stands in for a support team's portal. It runs on
your machine, not in AWS, and uses your default AWS credentials. It creates cases, sends
investigation jobs and decisions to the SQS queues, and shows what the inquiry agent found.

It uses the same DynamoDB case table, item shape and queue messages that the inquiry listener
expects:

- **Case item:** `caseId`, `status: QUEUED`, `job` (a JSON string), `createdAt` and
  `updatedAt`. The listener adds the findings and status changes.
- **Job message:** `{caseId, customerRef, inquiry, channel, context, submittedAt, requestedBy}`.
- **Decision message:** `{caseId, decision: "APPROVED" | "REJECTED", proposalVersion, decidedBy}`.

`requestedBy` and `decidedBy` name the representative. The listener passes them to the agent as
the runtime user ID and stores `decidedBy` on the case. The portal has no sign-in: the name comes
from the **Representative** box on the page or, if that is empty, from `representative` in
`Config.toml` (`portal-config.sh` sets it to your login name).

## Run

```bash
../scripts/portal-config.sh
```

```bash
bal run
```

Then open http://localhost:9090. You can also open `support-portal/` in WSO2 Integrator and
choose **Run**.

`scripts/portal-config.sh` writes `Config.toml` from the deploy outputs. To fill it in by hand,
copy `Config.toml.example`.

## API

| Method and path | Body | Does |
| --- | --- | --- |
| `GET /` | | The portal page (`static/index.html`) |
| `POST /cases` | `{"sample": 1}` or `{"inquiry": "...", "customerRef": "G-10427"}`, with an optional `"representative"` | Creates a case (`QUEUED`) and sends the job to the jobs queue. Returns `201` with the case ID |
| `GET /cases` | | Lists cases with their status, most recently updated first |
| `GET /cases/{caseId}` | | Shows one case: status, findings, proposed fix, draft reply and, once applied, the write tool's response |
| `POST /cases/{caseId}/decision` | `{"decision": "approve"}` or `{"decision": "reject"}`, with an optional `"representative"` | Sends `{caseId, decision, proposalVersion, decidedBy}` to the decisions queue. Returns `409` unless the case is `PENDING_APPROVAL`, `400` if there is no representative |
| `GET /failures` | | Lists up to 10 messages in each dead-letter queue, without removing them. SQS cannot list a queue exactly, so this is a best-effort sample from a few receives; a message read here stays hidden for 2 seconds, then reappears |

For a free-text inquiry, `customerRef`, `channel` and `context` are optional. `customerRef`
defaults to `G-UNSPECIFIED`. Samples 1-3 come from `../data/sample-inquiries.json`.

Examples:

```bash
curl -s -X POST localhost:9090/cases -H 'content-type: application/json' -d '{"sample": 2}'
```

```bash
curl -s localhost:9090/cases/CASE-20261105-1a2b3c
```

```bash
curl -s -X POST localhost:9090/cases/CASE-20261105-1a2b3c/decision -H 'content-type: application/json' -d '{"decision": "approve"}'
```

## Permissions

Your AWS credentials need:

- `dynamodb:GetItem`, `PutItem`, `UpdateItem` and `Scan` on the case table,
- `sqs:SendMessage` on the jobs and decisions queues,
- `sqs:ReceiveMessage` on the two dead-letter queues (for `GET /failures`).

## Layout

| File | Purpose |
| --- | --- |
| `service.bal` | REST API and the page at `/` |
| `cases.bal` | Case table and queue access |
| `clients.bal`, `config.bal` | AWS clients and settings |
| `modules/core` | Case IDs, job and decision messages, case view (unit tested) |
| `static/index.html` | The portal page: plain HTML, CSS and `fetch`, no build step |

#!/usr/bin/env python3
"""Mock support console for the customer inquiry agent sample.

A representative uses it to send an investigation job, read the agent's findings, and
approve or reject the proposed change. The case item in DynamoDB stands in for the ticket a
real support system would hold. The inquiry agent on Amazon ECS picks up jobs and decisions
from the two SQS queues.

    python3 scripts/console.py submit --sample 1
    python3 scripts/console.py show CASE-20261103-1a2b3c --watch
    python3 scripts/console.py decide CASE-20261103-1a2b3c --approve
    python3 scripts/console.py list
    python3 scripts/console.py failures

Settings come from .deploy/outputs.env (written by the deploy scripts). Environment
variables CASE_TABLE, JOB_QUEUE_URL, DECISION_QUEUE_URL, JOB_DLQ_URL, DECISION_DLQ_URL and
AWS_REGION override them.
"""

import argparse
import json
import os
import secrets
import shlex
import sys
import textwrap
import time
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUTS_FILE = REPO_ROOT / ".deploy" / "outputs.env"
SAMPLES_FILE = REPO_ROOT / "data" / "sample-inquiries.json"

# Statuses where the workflow is still working on the case.
IN_PROGRESS = {"QUEUED", "INVESTIGATING", "APPLYING"}
# Statuses where the case is waiting for a person.
WAITING = {"PENDING_APPROVAL"}


def load_settings():
    values = {}
    if OUTPUTS_FILE.exists():
        for line in OUTPUTS_FILE.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                key, raw = line.split("=", 1)
                parts = shlex.split(raw)
                values[key] = parts[0] if parts else ""
    settings = {
        "region": os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION"),
        "table": os.environ.get("CASE_TABLE") or values.get("CaseTableName"),
        "job_queue": os.environ.get("JOB_QUEUE_URL") or values.get("JobQueueUrl"),
        "decision_queue": os.environ.get("DECISION_QUEUE_URL") or values.get("DecisionQueueUrl"),
        "job_dlq": os.environ.get("JOB_DLQ_URL") or values.get("JobDeadLetterQueueUrl"),
        "decision_dlq": os.environ.get("DECISION_DLQ_URL") or values.get("DecisionDeadLetterQueueUrl"),
    }
    missing = [name for name in ("table", "job_queue", "decision_queue") if not settings[name]]
    if missing:
        sys.exit(f"Missing settings: {', '.join(missing)}. Deploy first, or set the environment variables.")
    return settings


def clients(settings):
    import boto3  # imported here so --help works without boto3 installed

    session = boto3.session.Session(region_name=settings["region"])
    return session.client("dynamodb"), session.client("sqs")


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_case_id():
    return f"CASE-{datetime.now(timezone.utc):%Y%m%d}-{secrets.token_hex(3)}"


def read_case(dynamodb, table, case_id):
    item = dynamodb.get_item(TableName=table, Key={"caseId": {"S": case_id}}, ConsistentRead=True).get("Item")
    if not item:
        sys.exit(f"Case {case_id} not found.")
    case = {}
    for key, value in item.items():
        if "S" in value:
            case[key] = value["S"]
        elif "N" in value:
            case[key] = int(value["N"])
    for key in ("findings", "proposedAction", "applyResult", "job"):
        if isinstance(case.get(key), str):
            try:
                case[key] = json.loads(case[key])
            except json.JSONDecodeError:
                pass
    return case


def cmd_submit(args, settings):
    if args.sample:
        samples = {s["id"]: s for s in json.loads(SAMPLES_FILE.read_text())}
        if args.sample not in samples:
            sys.exit(f"No sample {args.sample}. Choose one of {sorted(samples)}.")
        sample = samples[args.sample]
        inquiry, customer_ref = sample["inquiry"], sample["customerRef"]
        channel, context = sample["channel"], dict(sample["context"])
    else:
        if not (args.text and args.customer_ref):
            sys.exit("Use --sample N, or --text and --customer-ref.")
        inquiry, customer_ref, channel = args.text, args.customer_ref, args.channel
        context = dict(pair.split("=", 1) for pair in args.context or [])

    case_id = new_case_id()
    job = {
        "caseId": case_id,
        "customerRef": customer_ref,
        "inquiry": inquiry,
        "channel": channel,
        "context": context,
        "submittedAt": now_iso(),
    }
    dynamodb, sqs = clients(settings)
    dynamodb.put_item(
        TableName=settings["table"],
        Item={
            "caseId": {"S": case_id},
            "status": {"S": "QUEUED"},
            "job": {"S": json.dumps(job)},
            "createdAt": {"S": job["submittedAt"]},
            "updatedAt": {"S": job["submittedAt"]},
        },
        ConditionExpression="attribute_not_exists(caseId)",
    )
    sqs.send_message(QueueUrl=settings["job_queue"], MessageBody=json.dumps(job))
    if args.id_only:
        print(case_id)
        return
    print(f"Submitted {case_id}")
    print(f"  Inquiry: {inquiry}")
    print(f"  Next:    python3 scripts/console.py show {case_id} --watch")


def print_case(case):
    findings = case.get("findings") or {}
    action = case.get("proposedAction")
    job = case.get("job") or {}
    print(f"Case {case['caseId']}  status={case.get('status')}  proposalVersion={case.get('proposalVersion', '-')}")
    if job:
        print(f"  Inquiry: {job.get('inquiry')}")
    if findings:
        print("\nSummary")
        print(textwrap.indent(textwrap.fill(findings.get("summary", ""), 96), "  "))
        print("\nRoot cause")
        print(textwrap.indent(textwrap.fill(findings.get("rootCause", ""), 96), "  "))
        print(f"\nEvidence (confidence: {findings.get('confidence', '-')})")
        for item in findings.get("evidence", []):
            print(f"  - [{item.get('source')}] {item.get('detail')}")
        if findings.get("knowledgeSources"):
            print(f"\nKnowledge used: {', '.join(findings['knowledgeSources'])}")
    if isinstance(action, dict):
        print("\nProposed change (needs approval)")
        print(f"  Tool:      {action.get('tool')}")
        print(f"  Arguments: {json.dumps(action.get('arguments'))}")
        print(f"  Why:       {action.get('rationale')}")
    if case.get("draftReply"):
        print("\nDraft reply")
        print(textwrap.indent(textwrap.fill(case["draftReply"], 96), "  "))
    if case.get("applyResult"):
        print("\nWrite tool response")
        print(textwrap.indent(json.dumps(case["applyResult"], indent=2), "  "))
    if case.get("failureReason"):
        print(f"\nFailure: {case['failureReason']}")
    if case.get("status") in WAITING:
        print(f"\nNext: python3 scripts/console.py decide {case['caseId']} --approve   (or --reject)")


def cmd_show(args, settings):
    dynamodb, _ = clients(settings)
    case = read_case(dynamodb, settings["table"], args.case_id)
    if args.watch:
        last = None
        deadline = time.time() + args.timeout
        while case.get("status") in IN_PROGRESS and time.time() < deadline:
            if case.get("status") != last:
                last = case.get("status")
                print(f"... {last}")
            time.sleep(5)
            case = read_case(dynamodb, settings["table"], args.case_id)
    print_case(case)


def cmd_list(args, settings):
    dynamodb, _ = clients(settings)
    items = dynamodb.scan(TableName=settings["table"], Limit=args.limit).get("Items", [])
    rows = sorted(items, key=lambda i: i.get("updatedAt", {}).get("S", ""), reverse=True)
    for item in rows:
        job = json.loads(item.get("job", {}).get("S", "{}"))
        print(f"{item['caseId']['S']:<24} {item.get('status', {}).get('S', '-'):<20} "
              f"{item.get('updatedAt', {}).get('S', ''):<22} {job.get('inquiry', '')[:60]}")


def cmd_decide(args, settings):
    dynamodb, sqs = clients(settings)
    case = read_case(dynamodb, settings["table"], args.case_id)
    if case.get("status") != "PENDING_APPROVAL":
        sys.exit(f"Case {args.case_id} is {case.get('status')}; only PENDING_APPROVAL cases can be decided.")
    decision = "APPROVED" if args.approve else "REJECTED"
    # Only these three fields travel. The apply action loads the stored proposal itself.
    message = {"caseId": args.case_id, "decision": decision, "proposalVersion": case["proposalVersion"]}
    sqs.send_message(QueueUrl=settings["decision_queue"], MessageBody=json.dumps(message))
    print(f"Sent {decision} for {args.case_id} (proposal version {case['proposalVersion']}).")
    print(f"  Next: python3 scripts/console.py show {args.case_id} --watch")


def cmd_failures(_args, settings):
    _, sqs = clients(settings)
    found = False
    for label, key in (("jobs DLQ", "job_dlq"), ("decisions DLQ", "decision_dlq")):
        if not settings[key]:
            continue
        # Peek only: VisibilityTimeout=0 leaves the messages on the queue.
        messages = sqs.receive_message(
            QueueUrl=settings[key], MaxNumberOfMessages=10, VisibilityTimeout=0, WaitTimeSeconds=1
        ).get("Messages", [])
        for message in messages:
            found = True
            try:
                body = json.loads(message["Body"])
            except json.JSONDecodeError:
                body = {}
            print(f"{label:<14} {body.get('caseId', '-'):<24} {message['Body'][:100]}")
    if not found:
        print("No messages in the dead-letter queues.")


def main():
    parser = argparse.ArgumentParser(description="Mock support console for the inquiry agent sample.")
    sub = parser.add_subparsers(dest="command", required=True)

    submit = sub.add_parser("submit", help="send an investigation job")
    submit.add_argument("--sample", type=int, help="sample inquiry from data/sample-inquiries.json (1-3)")
    submit.add_argument("--text", help="inquiry text, instead of --sample")
    submit.add_argument("--customer-ref", help="guest reference, e.g. G-10427")
    submit.add_argument("--channel", default="email", help="email, chat or phone")
    submit.add_argument("--context", nargs="*", metavar="KEY=VALUE", help="identifiers on file, e.g. reservationId=R-48213")
    submit.add_argument("--id-only", action="store_true", help="print only the new case ID")
    submit.set_defaults(func=cmd_submit)

    show = sub.add_parser("show", help="show a case")
    show.add_argument("case_id")
    show.add_argument("--watch", action="store_true", help="wait while the case is being worked on")
    show.add_argument("--timeout", type=int, default=900, help="seconds to wait with --watch")
    show.set_defaults(func=cmd_show)

    listing = sub.add_parser("list", help="list recent cases")
    listing.add_argument("--limit", type=int, default=25)
    listing.set_defaults(func=cmd_list)

    decide = sub.add_parser("decide", help="approve or reject the proposed change")
    decide.add_argument("case_id")
    choice = decide.add_mutually_exclusive_group(required=True)
    choice.add_argument("--approve", action="store_true")
    choice.add_argument("--reject", action="store_true")
    decide.set_defaults(func=cmd_decide)

    failures = sub.add_parser("failures", help="peek at messages in the dead-letter queues")
    failures.set_defaults(func=cmd_failures)

    args = parser.parse_args()
    args.func(args, load_settings())


if __name__ == "__main__":
    main()

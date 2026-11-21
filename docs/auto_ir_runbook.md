# Auto-IR Runbook

**Human + Amazon Bedrock Incident Response**

## Purpose

This runbook defines how a human on-call engineer uses the Bedrock-generated
incident report safely, verifies it against raw evidence, and produces a
final, auditable incident artifact.

**Core rule: Bedrock accelerates analysis. Humans own correctness.**

The report the Lambda writes to S3 is a *draft*. It is built only from the
evidence bundle sitting next to it — nothing else — but a model can still
misread a log line or mis-cite a field. Every report must be read against
its own evidence bundle before it's treated as the final record.

## What triggers this

```
CloudWatch Alarm (apne1-db-connection-failure) -> ALARM
  -> SNS topic apne1-sns_topic01 (apne1-db-incidents)
     -> email subscription (existing, unchanged)
     -> apne1-ir-reporter Lambda (new)
        -> evidence collection -> Bedrock -> S3 -> "IR Report Ready" SNS
```

The Lambda runs automatically. This runbook is what the human does *after*
it has run.

## Step 1 — Find the report

You'll get an "IR Report Ready" SNS notification with the S3 path. Or list
recent reports directly:

```bash
aws s3 ls s3://<REPORT_BUCKET>/reports/ --recursive | tail
```

## Step 2 — Confirm the Lambda actually ran cleanly

```bash
aws logs tail /aws/lambda/apne1-ir-reporter --since 30m
```

Look for the `Incident <id> mode=<fast|deep> window=...` log line and
confirm there's no unhandled exception after it.

## Step 3 — Pull both artifacts

```bash
aws s3 cp s3://<REPORT_BUCKET>/reports/<incident_id>.md -
aws s3 cp s3://<REPORT_BUCKET>/reports/<incident_id>.json -
```

## Step 4 — Redaction check (do this every time, no exceptions)

```bash
aws s3 cp s3://<REPORT_BUCKET>/reports/<incident_id>.json - | grep -i password && echo "FAIL" || echo "PASS"
```

If this ever prints `FAIL`, stop. Do not forward the report. Rotate the
credential immediately (it means the password reached the evidence bundle
or the model echoed it back), then file a bug against `handler.py`'s
`scrub_secrets`/`get_secret_meta_and_password` split.

## Step 5 — Verify every claim against the evidence bundle

Go section by section through the Markdown report against the JSON
evidence bundle:

- **Section 4.1–4.4 (Evidence Collected):** does every number/log line in
  the report actually appear in `queries`, `ssm_params`, or `secret_meta`
  in the JSON? If the report states something the JSON doesn't support,
  that's a hallucination — strike it and flag it.
- **Section 5 (Root Cause Analysis):** does the stated confidence level
  match how much evidence actually supports it? A "High" confidence root
  cause backed by one ambiguous log line is wrong — downgrade it.
- **Any field the report marks "Unknown":** confirm the evidence bundle
  really doesn't contain that information. If it does and the model
  missed it, that's a model miss, not a data gap — note it either way.

## Step 6 — Decide: accept, edit, or regenerate

- **Accept** if every claim checks out against the evidence.
- **Edit** the Markdown directly for small corrections (a mis-cited field,
  a timeline gap you can fill from memory/tickets) — note in Section 8
  (Appendix) what you changed and why.
- **Regenerate** (re-invoke the Lambda with the same `incident_id`, or a
  `deep` mode run instead of `fast`) if the evidence itself was too thin —
  e.g. the 15-minute `fast` window missed the actual onset.

## Step 7 — Close the loop

- Add the final, human-reviewed report to wherever your team tracks
  postmortems (ticket, wiki, incident channel).
- If Section 7 (Preventive Actions) names something concrete and
  evidence-backed (credential rotation automation, SG drift detection,
  WAF rule tuning), open a ticket for it — don't let it live only in the
  Markdown file.

## Two report modes

| Mode | Window | Extra queries | When to use |
|------|--------|----------------|-------------|
| `fast` | 15 min | — | First response, still-active incident |
| `deep` | 60 min | top URIs overall, error-signature clustering | Postmortem, or `fast` evidence was too thin |

Trigger a specific mode manually from the Lambda console with
`tokyo/lambda_ir_reporter/test_event.json` (fast, real alarm shape) or
`test_event_deep.json` (deep, direct test-JSON shape) as the test event —
these also double as the "no real alarm needed" test harness.

## Prerequisites before this can run for real

- **Bedrock model access:** Anthropic models on Bedrock require a one-time
  use-case form submission before first invocation (console playground, or
  the `PutUseCaseForModelAccess` API). Do this once per account before
  the first real incident, not during one.
- **IAM propagation:** if `apne1_ir_reporter_role` was just created/changed,
  give IAM a minute before the first invocation — role changes are
  eventually consistent and an immediate call can fail with
  `AccessDeniedException` for reasons unrelated to the policy itself.

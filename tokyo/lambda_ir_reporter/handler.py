"""
IncidentReporter — Bedrock Auto-IR Lambda

Flow: alarm -> evidence collection -> LLM summarization -> report artifact -> notify.

Triggered by the same SNS topic the apne1-db-connection-failure CloudWatch
alarm already publishes to. Collects evidence (alarm metadata, CloudWatch
Logs Insights results, SSM params, Secrets Manager metadata), asks Bedrock
to draft a structured Markdown incident report constrained to that
evidence, then writes both the evidence bundle (JSON) and the report
(Markdown) to S3 and publishes a "Report Ready" SNS notification.

Core rule enforced throughout: the DB password is read (to connect, in the
app) but is NEVER placed in the evidence bundle, the prompt, or the report.
"""

import json
import os
import re
import time
import uuid
import datetime
import logging

import boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Config from environment (set by tokyo/bedrock_autoreport.tf)
# ---------------------------------------------------------------------------
REPORT_BUCKET = os.environ["REPORT_BUCKET"]
REPORT_PREFIX = os.environ.get("REPORT_PREFIX", "reports/")
APP_LOG_GROUP = os.environ["APP_LOG_GROUP"]
WAF_LOG_GROUP = os.environ["WAF_LOG_GROUP"]
SSM_PREFIX = os.environ.get("SSM_PREFIX", "/meridian/tokyo/db")
DB_SECRET_ID = os.environ["DB_SECRET_ID"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "us-east-1")
DEFAULT_MODE = os.environ.get("IR_REPORT_MODE", "fast")

LOCAL_REGION = os.environ.get("AWS_REGION", "ap-northeast-1")

RETRY_CONFIG = Config(retries={"max_attempts": 5, "mode": "adaptive"})

logs_client = boto3.client("logs", region_name=LOCAL_REGION, config=RETRY_CONFIG)
ssm_client = boto3.client("ssm", region_name=LOCAL_REGION, config=RETRY_CONFIG)
sm_client = boto3.client("secretsmanager", region_name=LOCAL_REGION, config=RETRY_CONFIG)
s3_client = boto3.client("s3", region_name=LOCAL_REGION, config=RETRY_CONFIG)
sns_client = boto3.client("sns", region_name=LOCAL_REGION, config=RETRY_CONFIG)

# Bedrock is invoked in BEDROCK_REGION explicitly, same cross-region-client
# pattern this project already uses for São Paulo -> Tokyo SSM/Secrets reads.
bedrock_client = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION, config=RETRY_CONFIG)

MODE_WINDOW_MINUTES = {"fast": 15, "deep": 60}


# ---------------------------------------------------------------------------
# Event parsing
# ---------------------------------------------------------------------------
def parse_alarm_event(event):
    """Accept a real SNS-wrapped alarm notification OR a direct test JSON."""
    if "Records" in event and event["Records"] and "Sns" in event["Records"][0]:
        msg = event["Records"][0]["Sns"]["Message"]
        try:
            return json.loads(msg)
        except json.JSONDecodeError:
            return {"raw_message": msg}
    return event


def extract_alarm_fields(incident):
    """Pull what we can from a CloudWatch alarm->SNS payload. Missing
    fields are reported as "Unknown" rather than guessed."""
    trigger = incident.get("Trigger", {}) if isinstance(incident, dict) else {}
    return {
        "name": incident.get("AlarmName", "Unknown"),
        "metric": trigger.get("MetricName", "Unknown"),
        "namespace": trigger.get("Namespace", "Unknown"),
        "threshold": trigger.get("Threshold", "Unknown"),
        "state": incident.get("NewStateValue", "Unknown"),
        "state_reason": incident.get("NewStateReason", "Unknown"),
        "state_change_time": incident.get("StateChangeTime", "Unknown"),
    }


# ---------------------------------------------------------------------------
# CloudWatch Logs Insights
# ---------------------------------------------------------------------------
def run_logs_insights_query(log_group, query_string, start_ts, end_ts, max_wait_s=25):
    """StartQuery + poll GetQueryResults. Returns a list of row-dicts, or
    an explicit error marker on timeout/failure — never silently empty."""
    try:
        start = logs_client.start_query(
            logGroupName=log_group,
            startTime=start_ts,
            endTime=end_ts,
            queryString=query_string,
            limit=200,
        )
    except Exception as e:  # e.g. log group doesn't exist yet
        logger.warning("start_query failed for %s: %s", log_group, e)
        return {"status": "ERROR", "error": str(e), "rows": []}

    query_id = start["queryId"]
    elapsed = 0
    poll_interval = 1
    while elapsed < max_wait_s:
        resp = logs_client.get_query_results(queryId=query_id)
        status = resp["status"]
        if status in ("Complete", "Failed", "Cancelled"):
            rows = [
                {field["field"]: field["value"] for field in row}
                for row in resp.get("results", [])
            ]
            return {"status": status, "rows": rows}
        time.sleep(poll_interval)
        elapsed += poll_interval

    logs_client.stop_query(queryId=query_id)
    return {"status": "TIMEOUT", "rows": []}


def build_queries(mode):
    """The minimum required query pack, plus deep-mode extras."""
    queries = {
        "app_error_rate_1m": (
            APP_LOG_GROUP,
            'fields @timestamp, @message '
            '| filter @message like /ERROR|Exception|Traceback/ '
            '| stats count(*) as error_count by bin(1m)',
        ),
        "app_db_error_lines": (
            APP_LOG_GROUP,
            'fields @timestamp, @message '
            '| filter @message like /DB_CONNECTION_FAILURE|OperationalError|pymysql|mysql/ '
            '| sort @timestamp desc '
            '| limit 50',
        ),
        "waf_allow_vs_block": (
            WAF_LOG_GROUP,
            'fields @timestamp, action '
            '| stats count(*) as hits by action',
        ),
        "waf_top_blocked_ip_uri": (
            WAF_LOG_GROUP,
            'fields httpRequest.clientIp as clientIp, httpRequest.uri as uri, action '
            '| filter action = "BLOCK" '
            '| stats count(*) as hits by clientIp, uri '
            '| sort hits desc '
            '| limit 20',
        ),
    }

    if mode == "deep":
        queries["waf_top_uris_overall"] = (
            WAF_LOG_GROUP,
            'fields httpRequest.uri as uri '
            '| stats count(*) as hits by uri '
            '| sort hits desc '
            '| limit 20',
        )
        queries["app_error_clustering"] = (
            APP_LOG_GROUP,
            'fields @timestamp, @message '
            '| filter @message like /ERROR|Exception/ '
            '| parse @message "DB_CONNECTION_FAILURE: *" as err_detail '
            '| stats count(*) as occurrences by err_detail '
            '| sort occurrences desc '
            '| limit 10',
        )
    return queries


def run_query_pack(mode, start_ts, end_ts):
    results = {}
    for name, (log_group, query_string) in build_queries(mode).items():
        results[name] = run_logs_insights_query(log_group, query_string, start_ts, end_ts)
    return results


# ---------------------------------------------------------------------------
# Config sources (SSM + Secrets Manager) — redaction happens here
# ---------------------------------------------------------------------------
def get_ssm_params():
    names = [f"{SSM_PREFIX}/endpoint", f"{SSM_PREFIX}/port", f"{SSM_PREFIX}/name"]
    try:
        resp = ssm_client.get_parameters(Names=names, WithDecryption=False)
        values = {p["Name"]: p["Value"] for p in resp["Parameters"]}
        return {
            "endpoint": values.get(f"{SSM_PREFIX}/endpoint", "Unknown"),
            "port": values.get(f"{SSM_PREFIX}/port", "Unknown"),
            "name": values.get(f"{SSM_PREFIX}/name", "Unknown"),
        }
    except Exception as e:
        logger.warning("SSM read failed: %s", e)
        return {"endpoint": "Unknown", "port": "Unknown", "name": "Unknown"}


def get_secret_meta_and_password():
    """Returns (safe_meta, password_or_None). safe_meta NEVER contains the
    password — callers must only ever persist/prompt-with safe_meta."""
    try:
        resp = sm_client.get_secret_value(SecretId=DB_SECRET_ID)
        secret = json.loads(resp["SecretString"])
    except Exception as e:
        logger.warning("Secrets Manager read failed: %s", e)
        return {"host": "Unknown", "port": "Unknown", "dbname": "Unknown", "username": "Unknown"}, None

    safe_meta = {
        "host": secret.get("host", "Unknown"),
        "port": secret.get("port", "Unknown"),
        "dbname": secret.get("dbname", "Unknown"),
        "username": secret.get("username", "Unknown"),
    }
    return safe_meta, secret.get("password")


def scrub_secrets(obj, secrets_to_scrub):
    """Defense-in-depth: walk a JSON-able structure and replace any string
    that contains a known secret value with a redaction marker, even
    though the password is never intentionally included upstream."""
    secrets_to_scrub = [s for s in secrets_to_scrub if s]
    if not secrets_to_scrub:
        return obj

    def _scrub_str(s):
        for secret in secrets_to_scrub:
            if secret in s:
                s = s.replace(secret, "[REDACTED]")
        return s

    if isinstance(obj, dict):
        return {k: scrub_secrets(v, secrets_to_scrub) for k, v in obj.items()}
    if isinstance(obj, list):
        return [scrub_secrets(v, secrets_to_scrub) for v in obj]
    if isinstance(obj, str):
        return _scrub_str(obj)
    return obj


# ---------------------------------------------------------------------------
# Prompt pack — non-negotiable anti-hallucination rules
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = """You are an incident-response report writer for a cloud platform team.
Rules (non-negotiable):
1. Use ONLY the evidence provided in the user message. Do not invent facts,
   log lines, IPs, or timestamps that are not present in the evidence.
2. If a fact is not present or not determinable from the evidence, write
   "Unknown" for that field. Do not guess.
3. For every key claim (root cause, scope, timeline entry), cite which
   evidence key/field supports it, e.g. "(evidence: queries.app_db_error_lines)".
4. Include a confidence level (High/Medium/Low) next to the root cause
   classification and explain briefly why.
5. End the report with a short list of the next evidence you would pull
   to raise that confidence, if it is not already High.
6. Root cause category must be chosen from exactly these options unless
   none apply: Credential drift | Network isolation | DB interruption |
   External attack | Other.
7. Never include a password, secret value, or access key in the report,
   even if one somehow appears in the evidence."""


def build_prompt(incident_id, mode, alarm, time_window, queries, ssm_params, secret_meta):
    evidence = {
        "incident_id": incident_id,
        "mode": mode,
        "time_window_utc": time_window,
        "alarm": alarm,
        "queries": queries,
        "ssm_params": ssm_params,
        "secret_meta": secret_meta,
    }
    evidence_json = json.dumps(evidence, indent=2, default=str)

    return f"""Generate an incident report in Markdown using EXACTLY this heading structure
(fill in the content, keep every heading, keep the order):

# Incident Report: {incident_id} — <short title you infer from the alarm/evidence>

## 1. Executive Summary
## 2. Timeline (UTC)
## 3. Scope and Blast Radius
## 4. Evidence Collected
### 4.1 CloudWatch Alarm
### 4.2 App Logs (CloudWatch Logs Insights)
### 4.3 WAF Logs (CloudWatch Logs Insights)
### 4.4 Configuration Sources (for Recovery)
## 5. Root Cause Analysis
## 6. Resolution
## 7. Preventive Actions
## 8. Appendix

Here is the evidence bundle (the ONLY source of truth for this report):

```json
{evidence_json}
```
"""


def call_bedrock(prompt):
    """Bedrock Converse API — unified request/response shape across model
    families, preferred over provider-specific InvokeModel payloads."""
    response = bedrock_client.converse(
        modelId=BEDROCK_MODEL_ID,
        system=[{"text": SYSTEM_PROMPT}],
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={
            "maxTokens": 2000,  # MUST be explicit — unset defaults to model max and can throttle
            "temperature": 0.2,  # low temperature: factual consistency over creativity
        },
    )
    return response["output"]["message"]["content"][0]["text"]


# ---------------------------------------------------------------------------
# S3 + SNS
# ---------------------------------------------------------------------------
def write_report_objects(incident_id, evidence_bundle, report_markdown):
    json_key = f"{REPORT_PREFIX}{incident_id}.json"
    md_key = f"{REPORT_PREFIX}{incident_id}.md"

    s3_client.put_object(
        Bucket=REPORT_BUCKET,
        Key=json_key,
        Body=json.dumps(evidence_bundle, indent=2, default=str).encode("utf-8"),
        ContentType="application/json",
    )
    s3_client.put_object(
        Bucket=REPORT_BUCKET,
        Key=md_key,
        Body=report_markdown.encode("utf-8"),
        ContentType="text/markdown",
    )
    return json_key, md_key


def publish_report_ready(incident_id, md_key):
    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="IR Report Ready",
        Message=f"Incident report ready: {incident_id}\ns3://{REPORT_BUCKET}/{md_key}",
    )


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------
def lambda_handler(event, context):
    incident = parse_alarm_event(event)
    alarm = extract_alarm_fields(incident) if isinstance(incident, dict) else extract_alarm_fields({})

    mode = (event.get("mode") if isinstance(event, dict) else None) or DEFAULT_MODE
    if mode not in MODE_WINDOW_MINUTES:
        mode = "fast"

    incident_id = (
        (event.get("incident_id") if isinstance(event, dict) else None)
        or f"{alarm['name']}-{uuid.uuid4().hex[:8]}"
    )

    end_dt = datetime.datetime.now(datetime.timezone.utc)
    start_dt = end_dt - datetime.timedelta(minutes=MODE_WINDOW_MINUTES[mode])
    time_window = {
        "start": start_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "end": end_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    start_ts, end_ts = int(start_dt.timestamp()), int(end_dt.timestamp())

    logger.info("Incident %s mode=%s window=%s", incident_id, mode, time_window)

    queries = run_query_pack(mode, start_ts, end_ts)
    ssm_params = get_ssm_params()
    secret_meta, password = get_secret_meta_and_password()

    evidence_bundle = {
        "incident_id": incident_id,
        "time_window_utc": time_window,
        "alarm": alarm,
        "queries": queries,
        "ssm_params": ssm_params,
        "secret_meta": secret_meta,  # never contains password
    }
    # Defense-in-depth: scrub the password out of the bundle even though
    # it was never placed in it, in case a log line echoed it verbatim.
    evidence_bundle = scrub_secrets(evidence_bundle, [password])

    prompt = build_prompt(incident_id, mode, alarm, time_window, queries, ssm_params, secret_meta)

    try:
        report_markdown = call_bedrock(prompt)
    except Exception as e:
        logger.error("Bedrock call failed: %s", e)
        report_markdown = (
            f"# Incident Report: {incident_id} — Bedrock generation failed\n\n"
            f"## 1. Executive Summary\n- Bedrock InvokeModel/Converse call failed: {e}\n"
            f"- Raw evidence bundle was still written to S3 for manual review.\n"
        )
    report_markdown = scrub_secrets(report_markdown, [password])

    json_key, md_key = write_report_objects(incident_id, evidence_bundle, report_markdown)
    publish_report_ready(incident_id, md_key)

    return {
        "incident_id": incident_id,
        "mode": mode,
        "evidence_key": json_key,
        "report_key": md_key,
    }

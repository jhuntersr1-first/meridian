
#!/usr/bin/env python3
"""
malgus_waf_summary.py

Summarizes WAF activity from a CloudWatch Logs Insights log group over a
given time window: top actions (ALLOW/BLOCK/COUNT) and the top client IPs
by request volume.

This kind of WAF triage supports day-to-day security operations (spotting
traffic spikes or false positives) and doubles as audit evidence for
showing what the WAF actually blocked.
"""
import boto3, time, json, argparse
from datetime import datetime, timezone, timedelta

logs = boto3.client("logs")

def run(group, query, minutes):
    end = int(datetime.now(timezone.utc).timestamp())
    start = int((datetime.now(timezone.utc)-timedelta(minutes=minutes)).timestamp())
    qid = logs.start_query(logGroupName=group, startTime=start, endTime=end, queryString=query, limit=50)["queryId"]
    for _ in range(30):
        r = logs.get_query_results(queryId=qid)
        if r["status"] == "Complete":
            return [{x["field"]: x["value"] for x in row} for row in r["results"]]
        time.sleep(1)
    raise TimeoutError("Query timed out")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log-group", required=True)
    ap.add_argument("--minutes", type=int, default=30)
    args = ap.parse_args()

    actions = run(args.log_group, "stats count() as hits by action | sort hits desc", args.minutes)
    top_ips = run(args.log_group, "stats count() as hits by httpRequest.clientIp | sort hits desc | limit 10", args.minutes)
    print(json.dumps({"actions": actions, "top_ips": top_ips}, indent=2))

if __name__ == "__main__":
    main()
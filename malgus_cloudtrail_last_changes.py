#!/usr/bin/env python3
"""
malgus_cloudtrail_last_changes.py

Queries recent CloudTrail events in both regions and summarizes who changed
what, when, and from which AWS service. Used for incident-response triage
and as a change-history artifact during audit review.
"""
import boto3, json
from datetime import datetime, timezone, timedelta

def lookup(region, minutes=120):
    ct = boto3.client("cloudtrail", region_name=region)
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=minutes)

    # EventName filters can be added here to scope results to specific change types.
    resp = ct.lookup_events(
        StartTime=start, EndTime=end,
        MaxResults=50
    )
    events = []
    for e in resp.get("Events", []):
        events.append({
            "region": region,
            "time": str(e.get("EventTime")),
            "event": e.get("EventName"),
            "user": e.get("Username"),
            "source": e.get("EventSource"),
        })
    return events

def main():
    tokyo = lookup("ap-northeast-1")
    sp    = lookup("sa-east-1")
    print(json.dumps({"tokyo": tokyo, "saopaulo": sp}, indent=2))

if __name__ == "__main__":
    main()
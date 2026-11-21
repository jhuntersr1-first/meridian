#!/usr/bin/env python3
"""
malgus_residency_proof.py

Verifies APPI data-residency compliance by confirming RDS instances exist
only in Tokyo (ap-northeast-1) and not in Sao Paulo (sa-east-1), and
produces a pass/fail evidence artifact suitable for audit submission.
"""
import boto3, json

def list_rds(region):
    rds = boto3.client("rds", region_name=region)
    resp = rds.describe_db_instances()
    out = []
    for d in resp.get("DBInstances", []):
        out.append({
            "region": region,
            "id": d["DBInstanceIdentifier"],
            "az": d.get("AvailabilityZone"),
            "endpoint": d.get("Endpoint", {}).get("Address")
        })
    return out

def main():
    tokyo = list_rds("ap-northeast-1")
    sp    = list_rds("sa-east-1")

    evidence = {
        "tokyo_rds": tokyo,
        "saopaulo_rds": sp,
        "assertion": "PASS" if len(tokyo) > 0 and len(sp) == 0 else "FAIL"
    }
    print(json.dumps(evidence, indent=2))

if __name__ == "__main__":
    main()
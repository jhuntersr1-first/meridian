#!/usr/bin/env python3
"""
malgus_tgw_corridor_proof.py

Captures a snapshot of Transit Gateway resources (gateways and attachments)
in both Tokyo and Sao Paulo, used as evidence that the cross-region network
corridor between the two regions is actually provisioned and attached --
not just assumed from the Terraform plan.

Networking evidence like this is routinely requested during audits and
incident response in multi-region environments.
"""
import boto3, json

def tgw_snapshot(region):
    ec2 = boto3.client("ec2", region_name=region)
    tgws = ec2.describe_transit_gateways().get("TransitGateways", [])
    atts = ec2.describe_transit_gateway_attachments().get("TransitGatewayAttachments", [])
    return {"region": region, "transit_gateways": tgws, "attachments": atts}

def main():
    tokyo = tgw_snapshot("ap-northeast-1")
    sp    = tgw_snapshot("sa-east-1")
    print(json.dumps({"tokyo": tokyo, "saopaulo": sp}, indent=2, default=str))

if __name__ == "__main__":
    main()
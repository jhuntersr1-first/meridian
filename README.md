# Meridian — Cross-Region Healthcare Architecture with Japan Data Residency (APPI)

![Terraform](https://img.shields.io/badge/Terraform-%7E%3E5.0-844FBA?logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-ap--northeast--1%20%7C%20sa--east--1-FF9900?logo=amazonaws&logoColor=white)
![CI](https://img.shields.io/badge/CI-Jenkins-D24939?logo=jenkins&logoColor=white)
![Data Residency](https://img.shields.io/badge/Data%20Residency-Japan%20APPI-005BAC)
![Bedrock](https://img.shields.io/badge/Bedrock%20Auto--IR-Claude%203%20Haiku-6E56CF?logo=amazonbedrock&logoColor=white)
![Status](https://img.shields.io/badge/Auto--IR%20status-build--only%2C%20not%20deployed-lightgrey)

Multi-region AWS reference architecture for a regulated healthcare platform:
patient data (PHI) is stored exclusively in Tokyo (`ap-northeast-1`) to satisfy
Japan's APPI data-residency requirements, while São Paulo (`sa-east-1`) runs as
a stateless compute satellite. A single CloudFront distribution in front of
both regions gives doctors in either location one global URL.

- `tokyo/` — data authority: VPC, RDS (PHI), CloudFront, WAF, ACM, CloudTrail,
  Secrets Manager, SSM, and the Transit Gateway hub (module prefix `apne1`).
- `saopaulo/` — stateless compute satellite: VPC, EC2, ALB, Transit Gateway
  spoke (module prefix `saeast1`). No database, no PHI at rest.
- `Jenkinsfile` — four-stage CI/CD pipeline that sequences the cross-region
  Transit Gateway peering handshake and runs post-deploy compliance checks.
- `malgus_*.py` — audit evidence scripts (data residency proof, TGW corridor
  proof, CloudTrail change history, WAF summary, CloudFront cache report).

Global/edge resources (CloudFront, WAF, ACM cert, shared origin secret) use
the `meridian` naming prefix; region-scoped resources use their AWS region
code (`apne1`, `saeast1`) so a resource's name tells you where it lives.

## Architecture

```text
                                   Doctors / Clients
                                          |
                                     one global URL
                                          v
                        +-----------------------------------+
                        |   CloudFront (meridian_cdn)        |
                        |   + WAFv2 Web ACL + ACM cert       |
                        +------------------+------------------+
                                           |
                     origin header required (shared secret, Secrets Manager)
                                           |
            +------------------------------+------------------------------+
            |                                                             |
            v                                                             v
+----------------------------------+                      +----------------------------------+
|  TOKYO  ap-northeast-1 (apne1)   |                       |  SAO PAULO  sa-east-1 (saeast1)   |
|  data authority                  |                       |  stateless compute satellite      |
|                                   |                       |                                   |
|  ALB --> EC2 (app)                |                      |  ALB --> EC2 (app)                 |
|           |                       |                      |           |                        |
|           v                       |                      |           |  (no database, no PHI)|
|  RDS (PHI, encrypted)             |                      |                                   |
|           ^                       |                      |                                   |
|           | SSM params / Secrets  |                      |                                   |
|           | Manager (db creds)    |                      |                                   |
|                                   |                       |                                   |
|  CloudWatch alarm:                |                      |                                   |
|  apne1-db-connection-failure      |                       |                                   |
|           |                       |                      |                                   |
|  Transit Gateway (apne1) <====== cross-region peering ======> Transit Gateway (saeast1)        |
|                                   |                       |                                   |
|  CloudTrail --> S3 audit bucket   |                      +----------------------------------+
+----------------------------------+
            |
            v  (alarm fires)
  +-------------------+     +---------------------+     +---------------------------+
  |  SNS topic        | --> |  Lambda ir_reporter  | --> |  Bedrock (Claude 3 Haiku) |
  +-------------------+     |  pulls CW Logs       |     |  Converse API drafts      |
                            |  Insights (app+WAF)  |     |  incident report          |
                            +---------+-------------+     +-------------+-------------+
                                      |                                 |
                                      v                                 v
                            +-------------------+           +---------------------------+
                            |  S3 (report .md/.json) | <--  |  Report written back to S3 |
                            +-------------------+           +---------------------------+
                                      |
                                      v
                            SNS "Report Ready" --> human reviewer
                            (verifies every claim against the
                             evidence bundle before closing out)
```

## Bedrock Auto-IR

`tokyo/bedrock_autoreport.tf` + `tokyo/lambda_ir_reporter/` add an
automated incident-response pipeline on top of the existing
`apne1-db-connection-failure` alarm: alarm → SNS → Lambda → CloudWatch
Logs Insights (app + WAF) + SSM/Secrets config → Bedrock (Claude 3 Haiku,
Converse API) → Markdown + JSON report in S3 → "Report Ready" SNS
notification. See `docs/incident_report_template.md` for the report
structure and `docs/auto_ir_runbook.md` for how a human reviews and
closes out a generated report (short version: Bedrock drafts, humans
verify every claim against the evidence bundle before treating it as
final). Not yet deployed/tested against live AWS — build-only so far.

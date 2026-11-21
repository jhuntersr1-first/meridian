############################################
# São Paulo ALB — Origin Cloaking
#
# Mirrors Tokyo exactly — same secret header check.
#
# The secret is NOT stored here. São Paulo reads it from the
# shared Secrets Manager secret that Tokyo created. Both ALBs end up
# checking for the exact same value that CloudFront sends.
#
# Apply order:
#   1. Apply Tokyo first — creates the secret
#   2. Apply São Paulo — reads the secret via a data source
############################################

############################################
# Read the secret from Secrets Manager
#
# The secret was created in the Tokyo state and stored
# in Secrets Manager under "meridian/edge/origin-secret".
# São Paulo looks it up by name — no Tokyo state file
############################################

data "aws_secretsmanager_secret" "meridian_origin_secret" {
  count    = var.tokyo_peering_attachment_ready ? 1 : 0
  provider = aws.tokyo
  name     = "meridian/edge/origin-secret"
}

data "aws_secretsmanager_secret_version" "meridian_origin_secret" {
  count     = var.tokyo_peering_attachment_ready ? 1 : 0
  provider  = aws.tokyo
  secret_id = data.aws_secretsmanager_secret.meridian_origin_secret[0].id
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

data "aws_ssm_parameter" "tokyo_tgw_peering_attachment_id" {
  count    = var.tokyo_peering_attachment_ready ? 1 : 0
  provider = aws.tokyo
  name     = "/meridian/apne1/tgw/peering-attachment-id"
}

data "aws_ssm_parameter" "tokyo_rds_endpoint" {
  count    = var.tokyo_peering_attachment_ready ? 1 : 0
  provider = aws.tokyo
  name     = "/meridian/tokyo/db/endpoint"
}

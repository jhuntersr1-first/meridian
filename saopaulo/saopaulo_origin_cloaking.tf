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
# needed, no variables, no manual copying.
############################################

# data "aws_secretsmanager_secret" "meridian_origin_secret" {
#   provider = aws.saopaulo
#   name     = "meridian/edge/origin-secret"
# }

# data "aws_secretsmanager_secret_version" "meridian_origin_secret" {
#   provider  = aws.saopaulo
#   secret_id = data.aws_secretsmanager_secret.meridian_origin_secret.id
# }

############################################
# Listener Rule — Priority 1
############################################

# Explanation: Same rule as Tokyo.
# X-Origin-Verify correct → forward to app.
# Missing or wrong → fall through to 403 default.
resource "aws_lb_listener_rule" "saeast1_require_origin_header" {

count        = var.tokyo_peering_attachment_ready ? 1 : 0

  provider     = aws.saopaulo
  listener_arn = aws_lb_listener.saeast1_http_listener01.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.saeast1_tg01.arn
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values = [data.aws_secretsmanager_secret_version.meridian_origin_secret[0].secret_string]
    }
  }
}

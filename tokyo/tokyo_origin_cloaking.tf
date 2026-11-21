############################################
# Listener Rule — Priority 1
# Allow requests that carry the correct secret header
############################################

# Explanation: Priority 1 = first thing the ALB checks.
# If X-Origin-Verify matches → forward to the app.
# If it doesn't match → fall through to the default 403 below.
resource "aws_lb_listener_rule" "apne1_require_origin_header" {
  listener_arn = aws_lb_listener.apne1_http_listener01.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apne1_tg01.arn
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [data.aws_secretsmanager_secret_version.meridian_origin_secret.secret_string]
    }
  }
}



############################################
# Tokyo — Origin Secret (Secrets Manager)
#
# Tokyo generates the random secret and stores it
# in AWS Secrets Manager. São Paulo reads it from
# there using a data source — no manual copying,
# no variables, no output flags.
#
# Apply order:
#   1. Apply Tokyo → secret is generated and stored
#   2. Apply São Paulo → reads the secret via a data source
#      (São Paulo apply will fail if Tokyo hasn't applied
#       first — the secret doesn't exist yet)
############################################

############################################
# Generate the secret
############################################

resource "random_password" "meridian_origin_secret" {
  length  = 32
  special = false
}

############################################
# Store it in Secrets Manager under "meridian/edge/origin-secret".
# São Paulo looks it up by that name via a data source (see
# saopaulo_origin_cloaking.tf).
############################################

resource "aws_secretsmanager_secret" "meridian_origin_secret" {
  name                    = "meridian/edge/origin-secret"
  description             = "X-Origin-Verify header secret shared between CloudFront and both ALBs"
  recovery_window_in_days = 0 # Allows immediate delete/recreate during iterative deploys

  tags = {
    Name = "${var.platform_name}-origin-secret"
    Project = "meridian"
  }
}

resource "aws_secretsmanager_secret_version" "meridian_origin_secret_version" {
  secret_id     = aws_secretsmanager_secret.meridian_origin_secret.id
  secret_string = random_password.meridian_origin_secret.result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

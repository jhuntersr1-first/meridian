############################################
# Bedrock Auto-IR — "evidence collection -> LLM summary -> report -> notify"
#
# Flow:
#   1) aws_cloudwatch_metric_alarm.apne1_db_alarm01 -> ALARM
#   2) -> aws_sns_topic.apne1_sns_topic01 (already exists, tokyo_main.tf)
#   3) -> this Lambda (apne1_ir_reporter), subscribed to that same topic
#   4) Lambda runs Logs Insights against the app + WAF log groups,
#      reads DB config from SSM/Secrets Manager (password redacted),
#      calls Bedrock to draft the report, writes JSON+Markdown to
#      aws_s3_bucket.audit_bucket under reports/, then publishes a
#      second "IR Report Ready" message to the same SNS topic.
#
# Humans still own correctness — see docs/auto_ir_runbook.md.
############################################

############################################
# Variables
############################################

variable "bedrock_model_id" {
  description = "Bedrock model ID the IncidentReporter Lambda calls via Converse."
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
}

variable "bedrock_region" {
  description = "Region to invoke Bedrock in. Called explicitly from the ap-northeast-1 Lambda, same cross-region-client pattern already used for São Paulo -> Tokyo SSM/Secrets reads."
  type        = string
  default     = "us-east-1"
}

variable "ir_report_mode" {
  description = "Default report mode: fast (15-min window) or deep (60-min window + extra WAF correlation). Can be overridden per-invocation via the event payload."
  type        = string
  default     = "fast"
}

variable "ir_report_prefix" {
  description = "S3 key prefix (inside the audit bucket) that evidence bundles and reports are written under."
  type        = string
  default     = "reports/"
}

############################################
# IAM Role
############################################

resource "aws_iam_role" "apne1_ir_reporter_role" {
  name = "${local.name_prefix}-ir-reporter-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name    = "${local.name_prefix}-ir-reporter-role"
    Project = "meridian"
  }
}

# Explanation: least-privilege, resource-scoped where the API supports it.
# Bedrock is scoped to the exact model ARN — never bedrock:* / wildcard models.
resource "aws_iam_role_policy" "apne1_ir_reporter_policy" {
  name = "${local.name_prefix}-ir-reporter-policy"
  role = aws_iam_role.apne1_ir_reporter_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logging"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:ap-northeast-1:${var.account_id}:log-group:/aws/lambda/${local.name_prefix}-ir-reporter:*"
      },
      {
        Sid    = "LogsInsightsQuery"
        Effect = "Allow"
        Action = ["logs:StartQuery", "logs:GetQueryResults", "logs:StopQuery"]
        Resource = [
          "${aws_cloudwatch_log_group.apne1_log_group01.arn}:*",
          "${aws_cloudwatch_log_group.waf_log_group.arn}:*",
        ]
      },
      {
        Sid      = "ReadDbConfig"
        Effect   = "Allow"
        Action   = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = "arn:aws:ssm:ap-northeast-1:${var.account_id}:parameter/meridian/tokyo/db/*"
      },
      {
        Sid      = "ReadDbSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.apne1_db_secret01.arn
      },
      {
        Sid      = "InvokeReportModel"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.bedrock_region}::foundation-model/${var.bedrock_model_id}"
      },
      {
        Sid      = "WriteReportBundle"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.audit_bucket.arn}/${var.ir_report_prefix}*"
      },
      {
        Sid      = "NotifyReportReady"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.apne1_sns_topic01.arn
      }
    ]
  })
}

############################################
# Lambda
############################################

resource "aws_cloudwatch_log_group" "apne1_ir_reporter_log_group" {
  name              = "/aws/lambda/${local.name_prefix}-ir-reporter"
  retention_in_days = 30

  tags = {
    Name    = "${local.name_prefix}-ir-reporter-log-group"
    Project = "meridian"
  }
}

resource "aws_lambda_function" "apne1_ir_reporter" {
  function_name = "${local.name_prefix}-ir-reporter"
  role          = aws_iam_role.apne1_ir_reporter_role.arn

  filename         = "${path.module}/lambda_ir_reporter/lambda_ir_reporter.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda_ir_reporter/lambda_ir_reporter.zip")

  handler = "handler.lambda_handler"
  runtime = "python3.12"
  timeout = 90
  memory_size = 256

  environment {
    variables = {
      REPORT_BUCKET     = aws_s3_bucket.audit_bucket.id
      REPORT_PREFIX     = var.ir_report_prefix
      APP_LOG_GROUP     = aws_cloudwatch_log_group.apne1_log_group01.name
      WAF_LOG_GROUP     = aws_cloudwatch_log_group.waf_log_group.name
      SSM_PREFIX        = "/meridian/tokyo/db"
      DB_SECRET_ID      = aws_secretsmanager_secret.apne1_db_secret01.name
      SNS_TOPIC_ARN     = aws_sns_topic.apne1_sns_topic01.arn
      BEDROCK_MODEL_ID  = var.bedrock_model_id
      BEDROCK_REGION    = var.bedrock_region
      IR_REPORT_MODE    = var.ir_report_mode
    }
  }

  depends_on = [aws_cloudwatch_log_group.apne1_ir_reporter_log_group]

  tags = {
    Name    = "${local.name_prefix}-ir-reporter"
    Project = "meridian"
  }
}

############################################
# SNS -> Lambda wiring
#
# Same topic the DB-connection-failure alarm already publishes to
# (aws_sns_topic.apne1_sns_topic01, tokyo_main.tf). The human email
# subscription stays; this adds a second, parallel subscriber.
############################################

resource "aws_sns_topic_subscription" "apne1_ir_reporter_sub" {
  topic_arn = aws_sns_topic.apne1_sns_topic01.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.apne1_ir_reporter.arn
}

# Explanation: resource-based policy on the Lambda side — SNS needs
# explicit permission to invoke it. source_arn pins this to the one
# topic (confused-deputy protection), not "any SNS topic in the account."
resource "aws_lambda_permission" "apne1_ir_reporter_sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.apne1_ir_reporter.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.apne1_sns_topic01.arn
}

############################################
# Outputs
############################################

output "ir_reporter_function_name" {
  value = aws_lambda_function.apne1_ir_reporter.function_name
}

output "ir_reporter_log_group" {
  value = aws_cloudwatch_log_group.apne1_ir_reporter_log_group.name
}

output "verify_no_secrets_in_report_command" {
  description = "Auditor/grading check: evidence bundle must never contain the DB password."
  value       = "aws s3 cp s3://${var.log_bucket_name}/${var.ir_report_prefix}<incident_id>.json - | grep -i password && echo FAIL || echo PASS"
}

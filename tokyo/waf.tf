############################################
# WAF WebACL — attached to CloudFront
# Scope must be CLOUDFRONT → us-east-1
# Managed rules: AWSManagedRulesCommonRuleSet
############################################

resource "aws_wafv2_web_acl" "meridian_waf" {
  provider    = aws.useast1
  name        = "meridian-waf-cloudfront"
  description = "WAF for Meridian CloudFront distribution - edge security control"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "meridian-waf-cloudfront"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "meridian-waf-cloudfront"
    Project = "meridian"
  }
}

############################################
# WAF Logging → CloudWatch Logs
# Log group name must start with aws-waf-logs-
############################################

resource "aws_cloudwatch_log_group" "waf_log_group" {
  provider          = aws.useast1
  name              = "aws-waf-logs-meridian"
  retention_in_days = 90

  tags = {
    Name = "aws-waf-logs-meridian"
    Project = "meridian"
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "waf_logging" {
  provider                = aws.useast1
  log_destination_configs = [aws_cloudwatch_log_group.waf_log_group.arn]
  resource_arn            = aws_wafv2_web_acl.meridian_waf.arn
}

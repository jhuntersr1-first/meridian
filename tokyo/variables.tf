variable "domain_name" {
  description = "Primary domain for CloudFront distribution."
  type        = string
  default     = "example.com"
}

variable "app_subdomain" {
  description = "Application subdomain."
  type        = string
  default     = "app"
}

variable "api_subdomain" {
  description = "API subdomain."
  type        = string
  default     = "api"
}
variable "log_bucket_name" {
  description = "S3 bucket for all audit logs."
  type        = string
  default     = "meridian-audit-123456789012"
}

variable "cloudfront_log_prefix" {
  description = "CloudFront log prefix in S3."
  type        = string
  default     = "cloudfront-logs/"
}

variable "account_id" {
  description = "AWS account ID."
  type        = string
  default     = "123456789012"
}

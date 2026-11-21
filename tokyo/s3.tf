############################################
# S3 Audit Bucket — Meridian
# Receives: CloudFront logs, CloudTrail logs
# Versioning enabled = immutability posture
############################################

resource "aws_s3_bucket" "audit_bucket" {
  bucket        = var.log_bucket_name
  force_destroy = true

  tags = {
    Name    = "meridian-audit-logs"
    Purpose = "audit-evidence"
    Project = "meridian"
  }
}

resource "aws_s3_bucket_versioning" "audit_versioning" {
  bucket = aws_s3_bucket.audit_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "audit_ownership" {
  bucket = aws_s3_bucket.audit_bucket.id

  rule {
    object_ownership = "ObjectWriter"
  }
}

resource "aws_s3_bucket_public_access_block" "audit_block" {
  bucket                  = aws_s3_bucket.audit_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Note: no bucket ACL resource here. CloudTrail and CloudFront Standard
# Logging v2 both deliver via service principals that attach the
# bucket-owner-full-control canned ACL header on each PutObject — the
# bucket policy below (which checks for that header) is sufficient.
# A bucket_acl resource that tries to set the ACL owner to CloudFront's
# log-delivery canonical user ID is rejected by S3 (you cannot reassign
# bucket ownership via PutBucketAcl) and is unnecessary here.

# CloudTrail + CloudFront bucket policy
resource "aws_s3_bucket_policy" "audit_bucket_policy" {
  bucket = aws_s3_bucket.audit_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = "arn:aws:s3:::${var.log_bucket_name}"
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${var.log_bucket_name}/cloudtrail-logs/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid    = "CloudFrontLogsWrite"
        Effect = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${var.log_bucket_name}/${var.cloudfront_log_prefix}*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

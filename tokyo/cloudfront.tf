############################################
# Meridian — CloudFront Distribution
#
# Origin:  origin.example.com
#          Route 53 latency routing resolves this to
#          whichever ALB is fastest for the requester:
#            - apne1-alb01  (Tokyo,     ap-northeast-1)
#            - saeast1-alb01 (São Paulo, sa-east-1)
#
# WAF:     meridian-waf-cloudfront  (waf.tf)
# Cert:    meridian_cdn_cert  (this file, us-east-1)
# Cache:   meridian_cache_*  (tokyo_cache_policies.tf)
#
# One distribution/origin in front of two regional ALBs. Route 53
# latency routing picks Tokyo or São Paulo; the client only sees
# one global URL and is unaware of which region served the request.
############################################

############################################
# DNS names this distribution answers to
#
# apex + www + app + api, all on one distribution/origin.
# Only the path (/api/*, /static/*, ...) changes cache behavior —
# the subdomain itself is just an alias, same as "app" always was.
############################################

locals {
  cdn_record_names = toset([
    var.domain_name,
    "www.${var.domain_name}",
    "${var.app_subdomain}.${var.domain_name}",
    "${var.api_subdomain}.${var.domain_name}",
  ])
}

############################################
# ACM Certificate for CloudFront (must be us-east-1)
#
# CloudFront is a global service — certificates it uses must be
# requested/validated in us-east-1 regardless of where origins live.
############################################

resource "aws_acm_certificate" "meridian_cdn_cert" {
  provider = aws.useast1

  domain_name               = var.domain_name
  validation_method         = "DNS"
  subject_alternative_names = tolist(setsubtract(local.cdn_record_names, [var.domain_name]))

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.platform_name}-cf-cert"
    Project = "meridian"
  }
}

# Explanation: ACM requires one DNS validation record PER name on the
# cert (primary + every SAN) — looping over domain_validation_options
# (not hardcoding index [0]) is what makes that work for more than
# one name at a time.
resource "aws_route53_record" "meridian_cdn_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.meridian_cdn_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.primary_zone.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

# Explanation: CloudFront will reject a certificate that hasn't finished
# DNS validation yet. Waiting on this (instead of handing CloudFront the
# raw certificate ARN) is what guarantees the cert is actually ISSUED
# before CreateDistribution is called.
resource "aws_acm_certificate_validation" "meridian_cdn_cert_validation" {
  provider                = aws.useast1
  certificate_arn         = aws_acm_certificate.meridian_cdn_cert.arn
  validation_record_fqdns = [for r in aws_route53_record.meridian_cdn_cert_validation : r.fqdn]
}

############################################
# CloudFront Distribution
############################################

resource "aws_cloudfront_distribution" "meridian_cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.platform_name} — edge security + multi-region latency routing"
  default_root_object = ""
  aliases             = tolist(local.cdn_record_names)

  # WAF attached at the edge — blocks bad traffic before it reaches either ALB.
  # Defined in waf.tf. Must be CLOUDFRONT scope + us-east-1.
  web_acl_id = aws_wafv2_web_acl.meridian_waf.arn

  ############################################
  # Origin — ALB (Tokyo or São Paulo via Route 53 latency)
  #
  # CloudFront sends all origin requests to origin.example.com.
  # Route 53 latency routing resolves that name to whichever
  # regional ALB is closest to the CloudFront edge node making the request.
  ############################################

  origin {
    domain_name = "origin.${var.domain_name}"
    origin_id   = "meridian-alb-origin"

    custom_origin_config {
      http_port  = 80
      https_port = 443
      # http-only: CloudFront → ALB traffic stays on the AWS backbone.
      # The ALB cert covers the ALB DNS name, not origin.example.com,
      # so https-only would cause TLS negotiation errors.
      # Security is handled at two layers instead:
      #   Layer 1 — SG: only CloudFront prefix list IPs reach the ALB
      #   Layer 2 — X-Origin-Verify header: ALB rejects requests without it
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Secret password — ALB listener rule checks for this exact value.
    # Defined in random_password.meridian_origin_secret above.
    # ALB listener rules (in tokyo_main.tf and saopaulo_main.tf) must
    # reference this same value.
    custom_header {
      name  = "X-Origin-Verify"
      value = data.aws_secretsmanager_secret_version.meridian_origin_secret.secret_string
    }
  }

  ############################################
  # Default Cache Behavior — Dynamic / API
  #
  # Catch-all for any path not matched by the ordered behaviors below.
  # Caching is OFF — every request is forwarded directly to the ALB.
  ############################################

  default_cache_behavior {
    target_origin_id       = "meridian-alb-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # Cache policy: TTL=0, nothing stored. Defined in tokyo_cache_policies.tf.
    cache_policy_id = aws_cloudfront_cache_policy.meridian_cache_dynamic_disabled.id

    # ORP: forward cookies, query strings, Content-Type, Origin, Host.
    # The ALB (and Flask app behind it) needs all of these to work correctly.
    origin_request_policy_id = aws_cloudfront_origin_request_policy.meridian_orp_api.id
  }

  ############################################
  # Ordered Behavior 1 — /static/*
  #
  # Static files (images, CSS, JS) that never change. CloudFront caches
  # for up to a year, so the ALB is not hit until the cache expires.
  ############################################

  ordered_cache_behavior {
    path_pattern           = "/static/*"
    target_origin_id       = "meridian-alb-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    # Cache policy: up to 1 year. Defined in tokyo_cache_policies.tf.
    cache_policy_id = aws_cloudfront_cache_policy.meridian_cache_static.id

    # ORP: minimal — no cookies, no headers, no query strings for S3 static files.
    origin_request_policy_id = aws_cloudfront_origin_request_policy.meridian_orp_static.id

    # RSP: stamps Cache-Control: public, max-age=31536000, immutable on the response.
    # Tells browsers to keep the file for a year without re-checking.
    response_headers_policy_id = aws_cloudfront_response_headers_policy.meridian_rsp_static.id
  }

  ############################################
  # Ordered Behavior 2 — /api/public-feed
  #
  # Short-lived cache (up to 30s) for a public, non-personalized feed.
  # CloudFront honors the origin's Cache-Control header, so the app
  # controls freshness rather than this Terraform config.
  ############################################

 ordered_cache_behavior {
  path_pattern           = "/api/public-feed"
  target_origin_id       = "meridian-alb-origin"
  viewer_protocol_policy = "redirect-to-https"
  allowed_methods        = ["GET", "HEAD", "OPTIONS"]
  cached_methods         = ["GET", "HEAD"]

  cache_policy_id          = aws_cloudfront_cache_policy.meridian_cache_public_feed.id
  origin_request_policy_id = aws_cloudfront_origin_request_policy.meridian_orp_api.id
}
  ############################################
  # Ordered Behavior 3 — /api/*
  #
  # Never cached — always forwarded to the origin. Serving a cached
  # API response to the wrong user is a patient-safety risk here.
  ############################################

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "meridian-alb-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = aws_cloudfront_cache_policy.meridian_cache_dynamic_disabled.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.meridian_orp_api.id
  }

  ############################################
  # TLS / Viewer Certificate
  ############################################

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate_validation.meridian_cdn_cert_validation.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  ############################################
  # Geo Restriction
  ############################################

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  # CloudFront Standard Logging v2 — zero trust aligned.
  # Uses CloudFront's canonical user ID instead of a canned ACL.
  # The bucket ACL in s3.tf grants FULL_CONTROL to this canonical user only.
  # Prefix stays cloudfront-logs/ to match the audit bucket's expected layout.
  logging_config {
    bucket          = aws_s3_bucket.audit_bucket.bucket_regional_domain_name
    prefix          = "cloudfront-logs/"
    include_cookies = false
  }

  tags = {
    Name = "${var.platform_name}-cf"
    Project = "meridian"
  }
}

############################################
# Route 53 — apex + www + app + api → CloudFront
#
# Every one of these names resolves to the same CloudFront distribution;
# only the request path determines which cache behavior applies.
############################################

resource "aws_route53_record" "cdn_alias" {
  for_each = local.cdn_record_names

  zone_id         = data.aws_route53_zone.primary_zone.zone_id
  name            = each.value
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.meridian_cdn.domain_name
    zone_id                = aws_cloudfront_distribution.meridian_cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

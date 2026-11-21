############################################
# Meridian — CloudFront Cache & Origin Request Policies
#
# These resources are GLOBAL — they live in CloudFront,
# not in Tokyo or São Paulo. Cache policies have no region.
# They are referenced by the CloudFront distribution behaviors.
#
# Tokyo and São Paulo ALBs both receive traffic forwarded by the same
# CloudFront distribution, so these policies apply uniformly to both origins:
#   - static assets  -> cached for up to a year
#   - API / dynamic  -> never cached, always forwarded to the origin
############################################

############################################
# 1) Cache Policy — Static Assets (aggressive)
#
# Long-lived cache for assets that don't change. Reduces origin load
# and latency by serving from the edge until the TTL expires.
############################################

resource "aws_cloudfront_cache_policy" "meridian_cache_static" {
  name        = "meridian-cache-static"
  comment     = "Aggressive caching for /static/* — images, CSS, JS that never change"
  default_ttl = 86400     # 1 day default
  max_ttl     = 31536000  # 1 year maximum
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    # No cookies in cache key — static assets are identical for every requester.
    cookies_config { cookie_behavior = "none" }

    # No query strings — /static/logo.png?v=1 and /static/logo.png are the same file.
    query_strings_config { query_string_behavior = "none" }

    # No headers in cache key — maximizes the chance of a cache hit.
    headers_config { header_behavior = "none" }

    # Compress files before caching — smaller = faster delivery.
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

############################################
# 2) Cache Policy — API / Dynamic (disabled)
#
# TTL=0 means CloudFront never stores the response — every request
# is forwarded to the origin so dynamic data is always fresh.
############################################

resource "aws_cloudfront_cache_policy" "meridian_cache_dynamic_disabled" {
  name        = "meridian-cache-dynamic-disabled"
  comment     = "Caching OFF for dynamic routes — every request goes to the origin ALB"
  default_ttl = 0
  max_ttl     = 0
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    # With TTL=0, nothing is ever stored, so cache key settings
    # are irrelevant — kept minimal and explicit for clarity.
    cookies_config { cookie_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
    headers_config { header_behavior = "none" }

    # Nothing to compress at the cache layer when TTL=0.
    enable_accept_encoding_gzip   = false
    enable_accept_encoding_brotli = false
  }
}

############################################
# 3) Origin Request Policy — API
#
# Defines what CloudFront forwards to the ALB on a cache miss:
# cookies (session tokens), query strings (filters/search terms),
# and the headers the app needs to format its response.
#
# Applies to both the apne1 (Tokyo) and saeast1 (São Paulo) ALBs —
# Route 53 latency routing determines which ALB receives the request.
############################################

resource "aws_cloudfront_origin_request_policy" "meridian_orp_api" {
  name    = "meridian-orp-api"
  comment = "Forward cookies, query strings, and key headers to ALB origins (Tokyo + Sao Paulo)"

  cookies_config { cookie_behavior = "all" }

  query_strings_config { query_string_behavior = "all" }

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Content-Type", "Origin", "Host", "If-None-Match", "If-Modified-Since"]
    }
  }
}

############################################
# 4) Origin Request Policy — Static (minimal)
#
# Static asset requests only need the path — no cookies, headers,
# or query strings are forwarded to the S3 origin.
############################################

resource "aws_cloudfront_origin_request_policy" "meridian_orp_static" {
  name    = "meridian-orp-static"
  comment = "Minimal forwarding for /static/* from S3 — no cookies, no headers, no query strings"

  cookies_config { cookie_behavior = "none" }
  query_strings_config { query_string_behavior = "none" }
  headers_config { header_behavior = "none" }
}

############################################
# 5) Response Headers Policy — Static
#
# Tells the browser how long it may cache the asset. This value must
# match the cache policy's max_ttl (31536000) exactly — a mismatch
# causes CloudFront and the browser to disagree on freshness.
############################################

resource "aws_cloudfront_response_headers_policy" "meridian_rsp_static" {
  name    = "meridian-rsp-static"
  comment = "Explicit Cache-Control header for static assets — must match cache policy max_ttl"

  custom_headers_config {
    items {
      header   = "Cache-Control"
      override = true
      # public       = browsers and CDNs may cache this
      # max-age      = keep for 1 year (matches cache policy max_ttl)
      # immutable    = tell browser: don't revalidate even on refresh
      value = "public, max-age=31536000, immutable"
    }
  }
}

resource "aws_cloudfront_cache_policy" "meridian_cache_public_feed" {
  name    = "meridian-cache-public-feed"
  comment = "30s TTL with ETag revalidation support for /api/public-feed RefreshHit"

  default_ttl = 30
  max_ttl     = 60
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}
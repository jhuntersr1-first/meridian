data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

data "aws_route53_zone" "primary_zone" {
  name         = var.domain_name
  private_zone = false
}

data "aws_secretsmanager_secret_version" "meridian_origin_secret" {
  secret_id = aws_secretsmanager_secret.meridian_origin_secret.id

  depends_on = [aws_secretsmanager_secret_version.meridian_origin_secret_version]
}

data "aws_ssm_parameter" "saeast1_tgw_id" {
  count    = var.saopaulo_tgw_ready ? 1 : 0
  provider = aws.saopaulo
  name     = "/meridian/saeast1/tgw/id"
}

data "aws_ec2_transit_gateway_route_table" "apne1_default_rt" {
  filter {
    name   = "transit-gateway-id"
    values = [aws_ec2_transit_gateway.apne1_tgw01.id]
  }
  filter {
    name   = "default-association-route-table"
    values = ["true"]
  }
}

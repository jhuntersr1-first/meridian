resource "aws_ec2_transit_gateway_route" "tokyo_to_saopaulo" {
 count = var.tokyo_peering_accepted ? 1 : 0

  destination_cidr_block         = "10.190.0.0/16"
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.apne1_default_rt.id
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.apne1_to_saeast1_peer01[0].id

  depends_on = [
    aws_ec2_transit_gateway_peering_attachment.apne1_to_saeast1_peer01
  ]
}
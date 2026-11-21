variable "project_name" {
  description = "Prefix for naming. São Paulo region uses saeast1-* convention."
  type        = string
  default     = "saeast1"
}

variable "vpc_cidr" {
  description = "São Paulo VPC CIDR. Must not overlap with Tokyo (10.0.0.0/16)."
  type        = string
  default     = "10.190.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs for São Paulo."
  type        = list(string)
  default     = ["10.190.1.0/24", "10.190.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs for São Paulo."
  type        = list(string)
  default     = ["10.190.101.0/24", "10.190.102.0/24"]
}

variable "azs" {
  description = "Availability zones in sa-east-1."
  type        = list(string)
  default     = ["sa-east-1a", "sa-east-1b"]
}

variable "ec2_ami_id" {
  description = "AMI ID for sa-east-1. Must be a valid AMI in the São Paulo region."
  type        = string
  default     = "ami-025f404fafb21297b" # Amazon Linux 2023, sa-east-1 — verify current at apply time
}

variable "ec2_instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "my_ip" {
  description = "Your public IP for SSH access."
  type        = string
  default     = "203.0.113.0/32" # TODO: supply your own value
}

variable "sns_email_endpoint" {
  description = "Email for SNS incident notifications."
  type        = string
  default     = "you@example.com"
}

# ── Tokyo cross-region inputs ─────────────────────────────────────────────
# These values come from Tokyo Terraform outputs (remote state or manual supply).

variable "tokyo_vpc_cidr" {
  description = "Tokyo VPC CIDR block. Used for TGW routes and RDS SG rules."
  type        = string
  default     = "10.52.0.0/16" # Must match Tokyo var.vpc_cidr
}

variable "tokyo_rds_endpoint" {
  description = "Tokyo RDS endpoint hostname. EC2 app connects here over TGW."
  type        = string
  default     = "" # Must be supplied from Tokyo outputs after Tokyo apply
}

variable "tokyo_db_name" {
  description = "Database name in Tokyo RDS."
  type        = string
  default     = "labdb"
}

variable "tokyo_tgw_peering_attachment_id" {
  description = "TGW peering attachment ID initiated by Tokyo (apne1_to_saeast1_peer01)."
  type        = string
  default     = "tgw-attach-00000000000000000" # Must be supplied after Tokyo TGW peering request is created
}

variable "domain_name" {
  description = "Primary domain for CloudFront distribution."
  type        = string
  default     = "example.com"
}

variable "tokyo_peering_attachment_ready" {
  type    = bool
  default = false
}

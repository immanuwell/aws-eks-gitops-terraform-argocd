module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # NAT Gateway configuration
  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # DNS settings required for EKS
  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC Flow Logs for security auditing
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60

  # Subnet tags required for EKS auto-discovery of subnets for ALBs
  # Public subnets — internet-facing ALBs
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${var.name}"           = "shared"
  }

  # Private subnets — internal ALBs and EKS nodes
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${var.name}"           = "shared"
    # Tag used by Karpenter for node provisioning (if added later)
    "karpenter.sh/discovery"                      = var.name
  }

  tags = merge(var.tags, {
    Name = var.name
  })
}

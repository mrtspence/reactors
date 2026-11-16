data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "reactor" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "reactor-aws-vpc"
  }
}

resource "aws_default_security_group" "reactor" {
  vpc_id = aws_vpc.reactor.id
}

locals {
  az_ids = slice(sort(data.aws_availability_zones.available.zone_ids), 0, 2)
}

resource "aws_subnet" "public" {
  for_each = toset(local.az_ids)

  vpc_id                  = aws_vpc.reactor.id
  cidr_block              = cidrsubnet(aws_vpc.reactor.cidr_block, 8, index(local.az_ids, each.key))
  availability_zone_id    = each.value
  map_public_ip_on_launch = false
  tags = {
    Name = "public-${each.value}"
  }
}

resource "aws_subnet" "private" {
  for_each = toset(local.az_ids)

  vpc_id                  = aws_vpc.reactor.id
  cidr_block              = cidrsubnet(aws_vpc.reactor.cidr_block, 2, index(local.az_ids, each.key) + 2)
  availability_zone_id    = each.value
  map_public_ip_on_launch = false
  tags = {
    Name = "private-${each.value}"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "reactor-nat-eip"
  }
}

resource "aws_internet_gateway" "reactor" {
  vpc_id = aws_vpc.reactor.id
  tags = {
    Name = "reactor-aws-internet-gateway"
  }
}

resource "aws_nat_gateway" "reactor" {
  allocation_id     = aws_eip.nat.id
  subnet_id         = aws_subnet.public[local.az_ids[0]].id
  availability_mode = "zonal"

  tags = {
    Name = "reactor-nat-gateway"
  }

  depends_on = [aws_internet_gateway.reactor]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.reactor.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.reactor.id
  }

  tags = {
    Name = "reactor-public-route-table"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.reactor.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.reactor.id
  }

  tags = {
    Name = "reactor-private-route-table"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.reactor.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "s3-gateway-endpoint"
  }
}

data "aws_db_snapshot" "source" {
  count = var.restore_rds_snapshot ? 1 : 0

  snapshot_type          = "manual"
  db_instance_identifier = "reactor-db"
  most_recent            = true
}

resource "time_static" "restore_point" {}

locals {
  timestamp = formatdate("YYYYMMDD-hhmm", time_static.restore_point.rfc3339)
}

ephemeral "aws_ssm_parameter" "rds_db_password" {
  arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/reactor/production/rds/master_password"
}


resource "aws_db_subnet_group" "rds" {
  name        = "rds-subnet-group"
  description = "Subnet group for the rds instance"
  subnet_ids  = values(aws_subnet.private)[*].id
}

resource "aws_security_group" "rds" {
  name        = "rds-private-sg"
  description = "Security group for rds instance"
  vpc_id      = aws_vpc.reactor.id

  tags = {
    Name = "rds-private-sg"
  }
}

resource "aws_db_instance" "reactor" {
  identifier        = "reactor-db"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"

  username            = "postgres"
  password_wo         = ephemeral.aws_ssm_parameter.rds_db_password.value
  password_wo_version = 1 # Rotation: docs/reference/infrastructure.md
  storage_encrypted   = true

  multi_az               = false
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  snapshot_identifier       = var.restore_rds_snapshot ? data.aws_db_snapshot.source[0].id : null
  backup_retention_period   = 0
  skip_final_snapshot       = false
  final_snapshot_identifier = "reactor-db-${local.timestamp}"
  deletion_protection       = false
  copy_tags_to_snapshot     = false # TODO: circle back to add tags from elsewhere later

  lifecycle {
    ignore_changes = [
      snapshot_identifier
    ]
  }

  tags = {
    RestoredAt     = time_static.restore_point.rfc3339
    SourceSnapshot = one(data.aws_db_snapshot.source[*].id)
  }
}

### EKS STUFF TODO: SPLIT OUT LATER

data "aws_iam_policy_document" "eks_cluster" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "reactor-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_eks_cluster" "reactor" {
  name                          = "reactor"
  version                       = "1.37"
  role_arn                      = aws_iam_role.eks_cluster.arn
  bootstrap_self_managed_addons = false
  enabled_cluster_log_types     = []

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids              = [for s in aws_subnet.private : s.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.admin_cidrs
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster
  ]
}

# TODO: Get this its own proper iam role later
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

resource "aws_eks_access_entry" "eks_cluster" {
  cluster_name  = aws_eks_cluster.reactor.name
  principal_arn = data.aws_iam_session_context.current.issuer_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "eks_cluster" {
  cluster_name  = aws_eks_cluster.reactor.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_eks_access_entry.eks_cluster.principal_arn

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_addon" "eks_cluster_vpc_cni" {
  cluster_name = aws_eks_cluster.reactor.name
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "eks_cluster_kube_proxy" {
  cluster_name = aws_eks_cluster.reactor.name
  addon_name   = "kube-proxy"
}

resource "aws_eks_addon" "eks_cluster_eks_pod_identity_agent" {
  cluster_name = aws_eks_cluster.reactor.name
  addon_name   = "eks-pod-identity-agent"
}

data "aws_iam_policy_document" "eks_node" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "reactor-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node.json
}

resource "aws_iam_role_policy_attachment" "eks_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node.name
}

# TODO: Move this off here onto the vpc-cni add on identity later
resource "aws_iam_role_policy_attachment" "eks_node_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr_read" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  role       = aws_iam_role.eks_node.name
}

resource "aws_eks_node_group" "reactor" {
  cluster_name    = aws_eks_cluster.reactor.name
  node_group_name = "reactor"
  node_role_arn   = aws_iam_role.eks_node.arn
  capacity_type   = "ON_DEMAND"
  instance_types  = ["t4g.medium"] # switch to non-burstable like m7g large etc if runing up surplus cpu charges
  ami_type        = "AL2023_ARM_64_STANDARD"
  subnet_ids      = [for s in aws_subnet.private : s.id]

  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_policy,
    aws_iam_role_policy_attachment.eks_node_cni,
    aws_iam_role_policy_attachment.eks_node_ecr_read,
    aws_eks_addon.eks_cluster_eks_pod_identity_agent,
    aws_eks_addon.eks_cluster_vpc_cni,
    aws_eks_addon.eks_cluster_kube_proxy,
    aws_internet_gateway.reactor,
    aws_nat_gateway.reactor,
    aws_route_table.private,
    aws_route_table_association.private
  ]
}

# this needs to be wired up after the node group
resource "aws_eks_addon" "eks_cluster_coredns" {
  cluster_name = aws_eks_cluster.reactor.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.reactor]
}

resource "aws_vpc_security_group_ingress_rule" "node_to_rds" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_eks_cluster.reactor.vpc_config[0].cluster_security_group_id
  description                  = "Allow rds/postgres access from EKS nodes"

  ip_protocol = "tcp"
  from_port   = 5432
  to_port     = 5432
}

### Certificates etc. TODO: slice out later

resource "aws_acm_certificate" "reactor" {
  domain_name       = "play.reactor-game.dev"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_route53_zone" "subdomain" {
  name         = "play.reactor-game.dev"
  private_zone = false
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.reactor.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.subdomain.id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "reactor" {
  certificate_arn = aws_acm_certificate.reactor.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_security_group" "alb" {
  name        = "reactor-alb-sg"
  description = "Security group for the ALB"
  vpc_id      = aws_vpc.reactor.id

  tags = {
    Name = "reactor-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_in" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from admin CIDR ${each.value}"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_in" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS from admin CIDR ${each.value}"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_eks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow ALB to forward traffic to EKS cluster on port 80"
  referenced_security_group_id = aws_eks_cluster.reactor.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_ingress_rule" "eks_from_alb" {
  security_group_id = aws_eks_cluster.reactor.vpc_config[0].cluster_security_group_id
  description       = "Allow HTTP from ALB into the EKS cluster"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_lb" "reactor" {
  name = "reactor-alb"
  internal = false
  load_balancer_type = "application"
  idle_timeout = 60
  drop_invalid_header_fields = true
  subnets = [for s in aws_subnet.public : s.id]
  security_groups = [aws_security_group.alb.id]
}

# TODO: This isn't gonna be used until I get the target group binding in later. Untested rn
resource "aws_lb_target_group" "eks" {
  name        = "reactor-eks-lb-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.reactor.id
  target_type = "ip"
  deregistration_delay = 30

  health_check {
    path = "/up"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.reactor.arn
  port = "443"
  protocol = "HTTPS"
  ssl_policy = "ELBSecurityPolicy-TLS13-1-3-PQ-2025-09"
  certificate_arn = aws_acm_certificate_validation.reactor.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.eks.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.reactor.arn
  port = "80"
  protocol = "HTTP"

  default_action {
    type             = "redirect"
    redirect {
      port = "443"
      protocol = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_route53_record" "apex" {
  name = data.aws_route53_zone.subdomain.name
  type = "A"
  zone_id = data.aws_route53_zone.subdomain.zone_id

  alias {
    name = aws_lb.reactor.dns_name
    zone_id = aws_lb.reactor.zone_id
    evaluate_target_health = false
  }
}

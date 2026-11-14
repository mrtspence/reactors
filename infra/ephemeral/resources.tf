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



# TODO: PROLLY NEED LATER, REMOVE COMMENT ONCE ATTACHED OR REMOVE IF NOT USED
data "aws_route53_zone" "this" {
  name = "play.reactor-game.dev"
}

data "aws_ecr_repository" "this" {
  name = "reactor"
}

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.expected_account_id
      error_message = "The authenticated AWS account does not match expected_account_id."
    }
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "cluster" {
  for_each = local.cluster_subnets

  vpc_id                  = aws_vpc.lab.id
  availability_zone       = each.value.az
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${each.key}"
    Tier = "cluster"
  }
}

resource "aws_subnet" "infra" {
  for_each = local.infra_subnets

  vpc_id                  = aws_vpc.lab.id
  availability_zone       = each.value.az
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${each.key}"
    Tier = "infra"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.lab.id
  availability_zone       = each.value.az
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${each.key}"
    Tier = "public-egress"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat_a" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-a-eip"
  }

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_nat_gateway" "a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public["public-a"].id

  tags = {
    Name = "${var.project_name}-nat-a"
  }

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.a.id
}

resource "aws_route_table_association" "cluster" {
  for_each = aws_subnet.cluster

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "infra" {
  for_each = aws_subnet.infra

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

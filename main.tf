provider "aws" {
  region = "ap-south-1"
}

############################
# VPC
############################

resource "aws_vpc" "sathya_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "sathya_vpc"
  }
}

resource "aws_internet_gateway" "sathya_igw" {
  vpc_id = aws_vpc.sathya_vpc.id
}

resource "aws_subnet" "sathya_subnet" {
  count = 2

  vpc_id                  = aws_vpc.sathya_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.sathya_vpc.cidr_block, 8, count.index)
  availability_zone       = element(["ap-south-1a", "ap-south-1b"], count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "sathya_subnet-${count.index}"

    # Required for EKS
    "kubernetes.io/cluster/sathya-cluster" = "shared"
    "kubernetes.io/role/elb"               = "1"
  }
}

resource "aws_route_table" "sathya_route_table" {
  vpc_id = aws_vpc.sathya_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sathya_igw.id
  }
}

resource "aws_route_table_association" "sathya_association" {
  count          = 2
  subnet_id      = aws_subnet.sathya_subnet[count.index].id
  route_table_id = aws_route_table.sathya_route_table.id
}

############################
# Security Groups
############################

resource "aws_security_group" "sathya_node_sg" {
  vpc_id = aws_vpc.sathya_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "sathya_cluster_sg" {
  vpc_id = aws_vpc.sathya_vpc.id

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.sathya_node_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################
# IAM Roles
############################

resource "aws_iam_role" "sathya_cluster_role" {
  name = "sathya-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.sathya_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "sathya_node_group_role" {
  name = "sathya-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "worker_node_policy" {
  role       = aws_iam_role.sathya_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni_policy" {
  role       = aws_iam_role.sathya_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "registry_policy" {
  role       = aws_iam_role.sathya_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

############################
# EKS Cluster
############################

resource "aws_eks_cluster" "sathya" {
  name     = "sathya-cluster"
  role_arn = aws_iam_role.sathya_cluster_role.arn

  vpc_config {
    subnet_ids         = aws_subnet.sathya_subnet[*].id
    security_group_ids = [aws_security_group.sathya_cluster_sg.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]
}

############################
# Node Group
############################

resource "aws_eks_node_group" "sathya" {

  depends_on = [
    aws_iam_role_policy_attachment.worker_node_policy,
    aws_iam_role_policy_attachment.cni_policy,
    aws_iam_role_policy_attachment.registry_policy
  ]

  cluster_name    = aws_eks_cluster.sathya.name
  node_group_name = "sathya-node-group"
  node_role_arn   = aws_iam_role.sathya_node_group_role.arn
  subnet_ids      = aws_subnet.sathya_subnet[*].id

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  instance_types = ["c7i-flex.large"]
}

############################
# IRSA for EBS CSI
############################

data "aws_eks_cluster" "sathya" {
  name = aws_eks_cluster.sathya.name
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da0afd40e24"]
  url             = data.aws_eks_cluster.sathya.identity[0].oidc[0].issuer
}

resource "aws_iam_role" "ebs_csi_irsa_role" {
  name = "sathya-ebs-csi-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(data.aws_eks_cluster.sathya.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_irsa_policy" {
  role       = aws_iam_role.ebs_csi_irsa_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

############################
# EBS CSI Addon
############################

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = aws_eks_cluster.sathya.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_irsa_role.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.sathya,
    aws_iam_role_policy_attachment.ebs_csi_irsa_policy
  ]
}


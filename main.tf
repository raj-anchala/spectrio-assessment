provider "aws" {
  region = "us-west-2"
}

resource "aws_vpc" "eks_vpc" {
  cidr_block = "10.88.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = {
    Name = "eks_vpc"
  }
}

resource "aws_subnet" "public_subnets" {
  count             = 2
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count)
  map_public_ip_on_launch = true
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  tags = {
    Name = "public_subnet-${count.index + 1}"
  }
}

resource "aws_subnet" "private_subnets" {
  count             = 2
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count + 2)
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  tags = {
    Name = "private_subnet-${count.index + 1}"
  }
}

resource "aws_eks_cluster" "eks_cluster" {
  name     = "eks_cluster"
  role_arn = aws_iam_role.eks_role.arn
  version  = "1.29"

  vpc_config {
    subnet_ids = concat(aws_subnet.public_subnets[*].id, aws_subnet.private_subnets[*].id)
  }

  depends_on = [aws_iam_role_policy_attachment.eks_policy]
}

resource "aws_eks_node_group" "node_group_01" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "node_group_01"
  node_role_arn   = aws_iam_role.eks_node_group_role.arn
  subnet_ids      = aws_subnet.private_subnets[*].id
  instance_types  = ["t3.medium"]

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 2
  }
}

resource "aws_eks_node_group" "node_group_02" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "node_group_02"
  node_role_arn   = aws_iam_role.eks_node_group_role.arn
  subnet_ids      = aws_subnet.private_subnets[*].id
  instance_types  = ["t3.small"]

  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }

  taint {
    key    = "app"
    value  = "podinfo"
    effect = "NO_SCHEDULE"
  }
}

resource "aws_iam_role" "eks_role" {
  name = "eks_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_role.name
}

resource "aws_iam_role" "eks_node_group_role" {
  name = "eks_node_group_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node_group_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "eks_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group_role.name
}

resource "aws_iam_role_policy_attachment" "eks_ebs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.eks_node_group_role.name
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name   = aws_eks_cluster.eks_cluster.name
  addon_name     = "vpc-cni"
  addon_version  = "v1.9.0-eksbuild.1"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name   = aws_eks_cluster.eks_cluster.name
  addon_name     = "kube-proxy"
  addon_version  = "v1.20.0-eksbuild.1"
}

resource "aws_eks_addon" "coredns" {
  cluster_name   = aws_eks_cluster.eks_cluster.name
  addon_name     = "coredns"
  addon_version  = "v1.8.0-eksbuild.1"
}

resource "aws_eks_addon" "ebs_csi_controller" {
  cluster_name   = aws_eks_cluster.eks_cluster.name
  addon_name     = "aws-ebs-csi-driver"
  addon_version  = "v1.0.0-eksbuild.1"
}

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
  }

  provisioner          = "ebs.csi.aws.com"
  volume_binding_mode  = "WaitForFirstConsumer"
  reclaim_policy       = "Retain"
  parameters = {
    type = "gp3"
  }
}

resource "kubernetes_storage_class" "default" {
  metadata {
    name = "gp2"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  provisioner          = "kubernetes.io/aws-ebs"
  volume_binding_mode  = "WaitForFirstConsumer"
  reclaim_policy       = "Retain"
  parameters = {
    type = "gp2"
  }
}

resource "kubernetes_deployment" "web_app" {
  metadata {
    name = "web-app"
    labels = {
      app = "web-app"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "web-app"
      }
    }

    template {
      metadata {
        labels = {
          app = "web-app"
        }
      }

      spec {
        container {
          name  = "web-app"
          image = "your-container-registry/your-web-app:latest"
          ports {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "podinfo" {
  metadata {
    name = "podinfo"
    labels = {
      app = "podinfo"
    }
  }

  spec {
    replicas = 5

    selector {
      match_labels = {
        app = "podinfo"
      }
    }

    template {
      metadata {
        labels = {
          app = "podinfo"
        }
      }

      spec {
        toleration {
          key      = "app"
          operator = "Equal"
          value    = "podinfo"
          effect   = "NoSchedule"
        }

        container {
          name  = "podinfo"
          image = "stefanprodan/podinfo:latest"
          ports {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "aws_codebuild_project" "ci_cd" {
  name          = "ci_cd"
  service_role  = aws_iam_role.codebuild_role.arn
  artifacts {
    type = "NO_ARTIFACTS"
  }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:4.0"
    type                        = "LINUX_CONTAINER"
    environment_variables {
      name  = "EKS_CLUSTER_NAME"
      value = aws_eks_cluster.eks_cluster.name
    }
  }
  source {
    type            = "GITHUB"
    location        = "https://github.com/your-repo/your-web-app"
    buildspec       = file("buildspec.yml")
  }
}

resource "aws_iam_role" "codebuild_role" {
  name = "codebuild_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "codebuild.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codebuild_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.codebuild_role.name
}

data "aws_availability_zones" "available" {}

output "cluster_endpoint" {
  value = aws_eks_cluster.eks_cluster.endpoint
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.eks_cluster.vpc_config[0].cluster_security_group_id
}

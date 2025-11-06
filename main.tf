# VPC Configuration
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs             = data.aws_availability_zones.available.names
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  # EKS Managed Node Group(s)
  eks_managed_node_group_defaults = {
    instance_types = var.node_instance_types

    # ✅ CRITICAL CHANGE 1: Don't attache cluster SG to the nodes
    # To avoid duplicate tag error causing conflict
    attach_cluster_primary_security_group = false
  }

  eks_managed_node_groups = {
    default = {
      name = "nodes"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      labels = {
        Environment = var.environment
        NodeGroup   = "default"
      }

      tags = {
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
        "k8s.io/cluster-autoscaler/enabled"             = "true"
      }
    }
  }

  # ✅ CRITICAL CHANGE 2: Add explicit rules for node security group
  # These rules replace the lost ones when disabling attach_cluster_primary_security_group
  node_security_group_additional_rules = {
    # Allow control plane traffic to nodes (1025-65535)
    ingress_cluster_to_node_all = {
      description                   = "Allow all traffic from cluster control plane to nodes"
      type                          = "ingress"
      protocol                      = "tcp"
      from_port                     = 1025
      to_port                       = 65535
      source_cluster_security_group = true
    }

    # Allow all traffic between nodes (Mandatory for CNI and pod-to-pod communication)
    ingress_self_all = {
      description = "Node to node all traffic"
      type        = "ingress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      self        = true
    }

    # ✅ CRITICAL: Allow traffic to NodePorts (30000-32767)
    # Mandatory to LoadBalancers can access to the services
    ingress_allow_nodeports = {
      description = "Allow NodePort traffic from anywhere (needed for LoadBalancers)"
      type        = "ingress"
      protocol    = "tcp"
      from_port   = 30000
      to_port     = 32767
      cidr_blocks = ["0.0.0.0/0"]
    }

    # Allow HTTP traffic from any origin (if you need to expose web services)
    ingress_allow_http = {
      description = "Allow HTTP traffic from anywhere"
      type        = "ingress"
      protocol    = "tcp"
      from_port   = 80
      to_port     = 80
      cidr_blocks = ["0.0.0.0/0"]
    }

    # Allow HTTPS traffic from any origin (if you need to expose web services)
    ingress_allow_https = {
      description = "Allow HTTPS traffic from anywhere"
      type        = "ingress"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_blocks = ["0.0.0.0/0"]
    }

    # Allow all outbound traffic
    egress_all = {
      description = "Allow all outbound traffic"
      type        = "egress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }
}

# ECR Repository for Docker images
resource "aws_ecr_repository" "guestbook" {
  name                 = "${var.project_name}/guestbook"
  image_tag_mutability = "MUTABLE"
  force_delete         = true  # Allow deletion even with images

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# ECR Lifecycle Policy
resource "aws_ecr_lifecycle_policy" "guestbook" {
  repository = aws_ecr_repository.guestbook.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# ============================================================================
# AWS LOAD BALANCER CONTROLLER - IMPROVED CONFIGURATION
# ============================================================================

# Download IAM policy document for AWS Load Balancer Controller
data "http" "lb_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json"
}

# Create IAM policy for AWS Load Balancer Controller
resource "aws_iam_policy" "aws_lb_controller" {
  name        = "${var.cluster_name}-AWSLoadBalancerControllerIAMPolicy"
  description = "IAM policy for AWS Load Balancer Controller"
  policy      = data.http.lb_controller_iam_policy.response_body

  tags = {
    Name = "${var.cluster_name}-lb-controller-policy"
  }
}

# Create IAM role for service account (IRSA) for AWS Load Balancer Controller
module "aws_lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.cluster_name}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = {
    Name = "${var.cluster_name}-lb-controller-role"
  }
}

# ✅ IMPROVED: Advanced configuration of AWS Load Balancer Controller
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.2"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.aws_lb_controller_irsa.iam_role_arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  # ✅ IMPROVED: Additional configuration for better performance and reliability
  set {
    name  = "replicaCount"
    value = "2"  # High availability with 2 replicas
  }

  set {
    name  = "enableShield"
    value = "false"  # Disable AWS Shield by default (it will be expensive)
  }

  set {
    name  = "enableWaf"
    value = "false"  # Disable AWS WAF by default (it will be expensive)
  }

  set {
    name  = "enableWafv2"
    value = "false"  # Disable AWS WAFv2 by default (it will be expensive)
  }

  # Improve logging for debugging
  set {
    name  = "logLevel"
    value = "info"  # Options: debug, info, warn, error
  }

  # Configure controller resources
  set {
    name  = "resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "resources.requests.memory"
    value = "128Mi"
  }

  set {
    name  = "resources.limits.cpu"
    value = "200m"
  }

  set {
    name  = "resources.limits.memory"
    value = "256Mi"
  }

  depends_on = [
    module.eks,
    module.aws_lb_controller_irsa
  ]
}

# ============================================================================
# DATA SOURCES
# ============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

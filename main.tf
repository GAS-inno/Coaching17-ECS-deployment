provider "aws" {
  region = "us-east-1"
}

terraform {

  required_version = ">= 1.0.0" # Specify a suitable version constraint

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # Specify a version relevant to your deployment
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
  backend "s3" {
    bucket = "sctp-ce11-tfstate"
    key    = "group3.tfstate" #Change this
    region = "us-east-1"
  }
}

locals {
  prefix = "group3"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_vpc" "existing" {
  filter {
    name   = "tag:Name"
    values = ["ce11-tf-vpc-95"]
  }
}

data "aws_subnets" "existing" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
}

resource "aws_ecr_repository" "ecr" {
  name         = "${local.prefix}-ecr"
  force_delete = true
}

resource "aws_security_group" "ecs_service" {
  name        = "${local.prefix}-ecs-service-sg"
  description = "Security group for ECS service"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    description = "Allow HTTP traffic on port 8080"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.prefix}-ecs-service-sg"
  }
}

# IAM Role for ECS Task (with custom permissions)
resource "aws_iam_role" "ecs_task_role" {
  name = "${local.prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${local.prefix}-ecs-task-role"
  }
}

# IAM Policy for S3 access
resource "aws_iam_role_policy" "ecs_task_s3_policy" {
  name = "${local.prefix}-ecs-task-s3-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::*/*",
          "arn:aws:s3:::*"
        ]
      }
    ]
  })
}

# IAM Policy for DynamoDB access
resource "aws_iam_role_policy" "ecs_task_dynamodb_policy" {
  name = "${local.prefix}-ecs-task-dynamodb-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem"
        ]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/*"
      }
    ]
  })
}

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 5.9.0"

  cluster_name = "${local.prefix}-ecs"
  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 100
      }
    }
  }

  services = {
    group3-flask-app = { #task definition and service name
      cpu    = 512
      memory = 1024
      
      # Prevent module from creating default task role
      create_task_role = false
      # Use our custom task role
      tasks_iam_role_arn = aws_iam_role.ecs_task_role.arn
      
      container_definitions = {
        flask-app = { #container name
          essential = true
          image     = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/${local.prefix}-ecr:latest"
          port_mappings = [
            {
              containerPort = 8080
              protocol      = "tcp"
            }
          ]
        }
      }
      assign_public_ip                   = true
      deployment_minimum_healthy_percent = 100
      subnet_ids                         = data.aws_subnets.existing.ids
      security_group_ids                 = [aws_security_group.ecs_service.id]
    }
  }
}
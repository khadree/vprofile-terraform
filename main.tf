provider "aws" {
  region = "eu-west-1"
}

data "aws_vpc" "existing" {
  id = var.vpc_id
}


data "aws_subnet" "selected" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

//S3 bucket for CodePipeline Artifact
resource "aws_s3_bucket" "bucket" {
  bucket        = "vprofile-artifact-bucket-my-2025"
  force_destroy = true

  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}

// ECR repository for application

resource "aws_ecr_repository" "image_repo" {
  name                 = "vporifle-repo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

// Application Security Group for the service
resource "aws_security_group" "app_sg" {
  name        = "vprofile-SG"
  description = "Example in default VPC"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


//Create the target group to be attached to the load balancer
resource "aws_lb_target_group" "vprofile_TG" {
  name        = "Vprofile-TargetGroup"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  health_check {
    path                = "/"
    protocol            = "HTTP"
    timeout             = 10
    interval            = 60
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  vpc_id = data.aws_vpc.existing.id
}



// Load balancer Security Group
resource "aws_security_group" "lb_sg" {
  name        = "vprofile-ELB"
  description = "Security group for the Load balance"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

//Create the Laod balancer to be attached
resource "aws_lb" "vprofileLB" {
  name               = "VprofileLB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [for s in data.aws_subnet.selected : s.id]
}

// Add listener to the Load Balancer

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.vprofileLB.arn # reference to your ALB
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vprofile_TG.arn
  }
}

// Create a cluster
resource "aws_ecs_cluster" "ecs_vprofile" {
  name = "vprofifle-cluster"
}

resource "aws_iam_role" "ecs_execution_role" {
  name = "ecsExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


resource "aws_iam_role" "ecs_task_role" {
  name = "ecsTaskRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

#Create Log groups
resource "aws_cloudwatch_log_group" "vprofile_log_group" {
  name              = "/ecs/vprofile-log"
  retention_in_days = 1
}

# Create Task Definition
resource "aws_ecs_task_definition" "vprofile" {
  family                   = "vprofile-task"
  network_mode             = "awsvpc"
  cpu                      = "2048"
  memory                   = "4096"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "vprofileContainer"
      image     = "${aws_ecr_repository.image_repo.repository_url}:latest"
      cpu       = 2048
      memory    = 4096
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/vprofile-log"
          "awslogs-region"        = "eu-west-1"
          "awslogs-stream-prefix" = "vprofile-log"
        }
      }
    }
  ])
}



//Create a service for the container
resource "aws_ecs_service" "vprofile" {
  name            = "vprofile_service"
  cluster         = aws_ecs_cluster.ecs_vprofile.id
  task_definition = aws_ecs_task_definition.vprofile.arn
  desired_count   = 0
  launch_type     = "FARGATE"

  health_check_grace_period_seconds = 30

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = [for s in data.aws_subnet.selected : s.id]
    security_groups  = [aws_security_group.app_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.vprofile_TG.arn
    container_name   = "vprofileContainer"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.listener]
}


# IAM Role for CodeBuild
resource "aws_iam_role" "codebuild_role" {
  name = "Vprofile-CodeBuild-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "codebuild.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# IAM Policy for ECR access (matches addToRolePolicy)
resource "aws_iam_role_policy" "codebuild_ecr_policy" {
  role = aws_iam_role.codebuild_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:*"]
        Resource = ["*"]
      }
    ]
  })
}

# CodeBuild CloudWatch Logs access
resource "aws_iam_role_policy" "codebuild_logs_policy" {
  role = aws_iam_role.codebuild_role.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "arn:aws:logs:eu-west-1:*:log-group:/codebuild/vprofile*"
    }]
  })
}


#### Attach s3 to code build for artifact
resource "aws_iam_role_policy" "codebuild_s3_policy" {
  role = aws_iam_role.codebuild_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "arn:aws:s3:::vprofile-artifact-bucket-my-2025/*"
      }
    ]
  })
}

//Create CodeBuild project that will be part of the pipeline
resource "aws_codebuild_project" "vprofile" {
  name         = "Vprofile-Project"
  service_role = aws_iam_role.codebuild_role.arn

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = aws_ecr_repository.image_repo.name
    }

    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }

    environment_variable {
      name  = "CONTAINER_NAME"
      value = "vprofileContainer"
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = "114725187682"
    }
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  source {
    type      = "GITHUB"                                      # ⚠ Change if using GitHub/Bitbucket/S3
    location  = "https://github.com/khadree/vprofile-project" # or your repo URL
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/codebuild/vprofile"
      stream_name = "build-log"
    }
  }
}



# ===== IAM Role for CodePipeline =====
resource "aws_iam_role" "codepipeline_role" {
  name = "Vprofile-CodePipeline-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "codepipeline.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# Basic policy allowing pipeline to use required services
resource "aws_iam_role_policy" "codepipeline_policy" {
  role = aws_iam_role.codepipeline_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:*"], Resource = ["*"] },
      { Effect = "Allow", Action = ["codebuild:*"], Resource = ["*"] },
      { Effect = "Allow", Action = ["ecs:*"], Resource = ["*"] },
      { Effect = "Allow", Action = ["codestar-connections:UseConnection"], Resource = ["*"] },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:Describe*",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.ecs_execution_role.arn,
          aws_iam_role.ecs_task_role.arn
        ]
      }
    ]
  })
}

# #######CodeDepoy ECS Role

# ===== CodePipeline Definition =====
resource "aws_codepipeline" "vprofile" {
  name     = "Vprofile-Pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.bucket.bucket
    type     = "S3"
  }

  # === SOURCE STAGE ===
  stage {
    name = "Source"
    action {
      name             = "Git_Repo_Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = "arn:aws:codeconnections:eu-west-1:114725187682:connection/279d25fe-aaff-4c22-a7c9-7f4c786df284"
        FullRepositoryId = "khadree/vprofile-project"
        BranchName       = "docker"
      }
    }
  }

  # === BUILD STAGE ===
  stage {
    name = "Build"
    action {
      name             = "CodeBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.vprofile.name
      }
    }
  }

  # === DEPLOY STAGE (ECS) ===
  stage {
    name = "Deploy"
    action {
      name            = "DeployAction"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["build_output"]
      configuration = {
        ClusterName = aws_ecs_cluster.ecs_vprofile.name
        ServiceName = aws_ecs_service.vprofile.name
      }
    }
  }
}

# main.tf - Kubernetes Cluster Infrastructure

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# AWS Provider Configuration
provider "aws" {
  region  = var.aws_region
  profile = "mzadmin"
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source for latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Random ID for cluster identification
resource "random_id" "cluster" {
  byte_length = 4
}

# Local values
locals {
  cluster_id = "${var.cluster_name}-${random_id.cluster.hex}"
  
  common_tags = {
    Environment = "learning"
    Project     = "kubernetes"
    Owner       = "yg"
    ManagedBy   = "terraform"
    ClusterName = var.cluster_name
    ClusterID   = local.cluster_id
  }
}

#===========================================
# VPC and Networking
#===========================================

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-vpc"
  })
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-igw"
  })
}

# Public Subnets
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)
  
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-public-subnet-${count.index + 1}"
    Type = "Public"
  })
}

# Route Table for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-public-rt"
  })
}

# Route Table Association for Public Subnets
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)
  
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

#===========================================
# Security Groups
#===========================================

# Security Group for Kubernetes Master Node
resource "aws_security_group" "k8s_master" {
  name_prefix = "${var.cluster_name}-master-sg"
  vpc_id      = aws_vpc.main.id

  # Allow all inbound traffic (for learning)
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All TCP traffic"
  }

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All UDP traffic"
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-master-sg"
    Type = "Master"
  })
}

# Security Group for Kubernetes Worker Nodes
resource "aws_security_group" "k8s_worker" {
  name_prefix = "${var.cluster_name}-worker-sg"
  vpc_id      = aws_vpc.main.id

  # Allow all inbound traffic (for learning)
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All TCP traffic"
  }

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All UDP traffic"
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-worker-sg"
    Type = "Worker"
  })
}

#===========================================
# Key Pair Management
#===========================================

# Generate Private Key
resource "tls_private_key" "k8s_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create AWS Key Pair
resource "aws_key_pair" "k8s_key" {
  key_name   = "${var.cluster_name}-key"
  public_key = tls_private_key.k8s_key.public_key_openssh

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-keypair"
  })
}

# Save Private Key to Local File
resource "local_file" "private_key" {
  content         = tls_private_key.k8s_key.private_key_pem
  filename        = "${path.module}/${var.cluster_name}-key.pem"
  file_permission = "0600"
}

#===========================================
# Parameter Store for Join Command
#===========================================

# Parameter Store for storing join command
resource "aws_ssm_parameter" "k8s_join_command" {
  name  = "/k8s/${local.cluster_id}/join-command"
  type  = "SecureString"
  value = "placeholder"

  lifecycle {
    ignore_changes = [value]
  }

  tags = merge(local.common_tags, {
    Name        = "${var.cluster_name}-join-command"
    Description = "Kubernetes cluster join command"
  })
}

#===========================================
# IAM Roles and Policies
#===========================================

# IAM Role for Kubernetes Nodes
resource "aws_iam_role" "k8s_nodes" {
  name = "${var.cluster_name}-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-nodes-role"
  })
}

# IAM Policy for SSM Parameter Store Access
resource "aws_iam_policy" "k8s_ssm_access" {
  name        = "${var.cluster_name}-ssm-access-policy"
  description = "Allow access to SSM Parameter Store for Kubernetes cluster"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/k8s/${local.cluster_id}/*"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-ssm-policy"
  })
}

# Attach SSM Policy to Role
resource "aws_iam_role_policy_attachment" "k8s_ssm_access" {
  role       = aws_iam_role.k8s_nodes.name
  policy_arn = aws_iam_policy.k8s_ssm_access.arn
}

# Instance Profile for EC2
resource "aws_iam_instance_profile" "k8s_nodes" {
  name = "${var.cluster_name}-nodes-profile"
  role = aws_iam_role.k8s_nodes.name

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-nodes-profile"
  })
}

#===========================================
# Kubernetes Master Node
#===========================================

# Kubernetes Master Node
resource "aws_instance" "k8s_master" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.master_instance_type
  key_name               = aws_key_pair.k8s_key.key_name
  vpc_security_group_ids = [aws_security_group.k8s_master.id]
  subnet_id              = aws_subnet.public[0].id
  iam_instance_profile   = aws_iam_instance_profile.k8s_nodes.name

  root_block_device {
    volume_size           = var.disk_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = false
  }

  metadata_options {
    http_tokens = "required"  # IMDSv2 only
  }

  user_data = base64encode(templatefile("${path.module}/scripts/k8s-master-init.sh", {
    cluster_id     = local.cluster_id
    parameter_name = aws_ssm_parameter.k8s_join_command.name
    aws_region     = var.aws_region
    cluster_name   = var.cluster_name
  }))

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-master"
    Type = "Master"
    Role = "ControlPlane"
  })
}

#===========================================
# Wait for Master Initialization Complete
#===========================================

# Wait for master node initialization to complete by monitoring Parameter Store
resource "null_resource" "wait_for_master_init" {
  depends_on = [aws_instance.k8s_master]

  provisioner "local-exec" {
    command = <<-EOT
      echo "=================================================="
      echo "마스터 노드 초기화 완료 대기 중..."
      echo "Parameter Store 경로: ${aws_ssm_parameter.k8s_join_command.name}"
      echo "모니터링 간격: 10초, 최대 대기 시간: 15분"
      echo "=================================================="
      
      for i in {1..90}; do
        echo "[$i/90] 마스터 노드 초기화 상태 확인 중... ($(date))"
        
        # Parameter Store에서 조인 명령어 확인
        JOIN_CMD=$(aws ssm get-parameter \
            --region ${var.aws_region} \
            --name "${aws_ssm_parameter.k8s_join_command.name}" \
            --with-decryption \
            --profile mzadmin \
            --query 'Parameter.Value' \
            --output text 2>/dev/null)
        
        # 조인 명령어 유효성 확인
        if [ $? -eq 0 ] && [ "$JOIN_CMD" != "placeholder" ] && [ ! -z "$JOIN_CMD" ] && echo "$JOIN_CMD" | grep -q "kubeadm join"; then
          echo "=================================================="
          echo "✅ 마스터 노드 초기화 완료 확인!"
          echo "✅ 조인 토큰이 Parameter Store에 저장되었습니다."
          echo "✅ 워커 노드 생성을 시작합니다..."
          echo "=================================================="
          exit 0
        elif [ $? -ne 0 ]; then
          echo "⏳ Parameter Store 접근 대기 중 (마스터 초기화 진행 중)"
        elif [ "$JOIN_CMD" = "placeholder" ]; then
          echo "⏳ Parameter Store에 placeholder 값 확인 (마스터 초기화 진행 중)"
        else
          echo "⏳ 조인 토큰 생성 대기 중 (마스터 초기화 진행 중)"
        fi
        
        # 마지막 시도가 아니면 10초 대기
        if [ $i -lt 90 ]; then
          echo "🕐 10초 후 다시 확인합니다..."
          sleep 10
        fi
      done
      
      echo "=================================================="
      echo "❌ 타임아웃: 15분 내에 마스터 초기화가 완료되지 않았습니다."
      echo "❌ 마스터 노드 로그를 확인하세요:"
      echo "   ssh -i ${var.cluster_name}-key.pem ec2-user@${aws_instance.k8s_master.public_ip}"
      echo "   tail -f /var/log/k8s-master-${local.cluster_id}.log"
      echo "=================================================="
      exit 1
    EOT
  }

  # 성공 시 완료 표시 파일 생성
  provisioner "local-exec" {
    when    = create
    command = "echo 'MASTER_INIT_COMPLETE' > ${path.module}/master-init-complete.txt"
  }
}

#===========================================
# Kubernetes Worker Nodes
#===========================================

# Data source to ensure workers wait for master init completion
data "local_file" "master_init_complete" {
  filename = "${path.module}/master-init-complete.txt"
  depends_on = [null_resource.wait_for_master_init]
}

# Kubernetes Worker Nodes
resource "aws_instance" "k8s_workers" {
  count = var.worker_count

  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.worker_instance_type
  key_name               = aws_key_pair.k8s_key.key_name
  vpc_security_group_ids = [aws_security_group.k8s_worker.id]
  subnet_id              = aws_subnet.public[count.index % length(aws_subnet.public)].id
  iam_instance_profile   = aws_iam_instance_profile.k8s_nodes.name

  root_block_device {
    volume_size           = var.disk_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = false
  }

  metadata_options {
    http_tokens = "required"  # IMDSv2 only
  }

  user_data = base64encode(templatefile("${path.module}/scripts/k8s-worker-join.sh", {
    cluster_id        = local.cluster_id
    parameter_name    = aws_ssm_parameter.k8s_join_command.name
    aws_region        = var.aws_region
    cluster_name      = var.cluster_name
    worker_index      = count.index + 1
    master_init_check = data.local_file.master_init_complete.content
  }))

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-worker-${count.index + 1}"
    Type = "Worker"
    Role = "DataPlane"
  })
}

#===========================================
# Real-time Log Monitoring
#===========================================

# 마스터 노드 로그 수집
resource "null_resource" "master_log_monitor" {
  depends_on = [aws_instance.k8s_master]

  # 주기적으로 마스터 로그 다운로드
  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ./logs
      
      # 마스터 노드 로그 수집 (백그라운드)
      (
        echo "📋 마스터 노드 로그 모니터링 시작..."
        for i in {1..900}; do  # 최대 30분간 모니터링 (2초 * 900 = 30분)
          sleep 2
          echo "[$i/900] 마스터 로그 수집 중... ($(date))"
          
          # SSH로 로그 파일 다운로드
          scp -i ${var.cluster_name}-key.pem \
              -o StrictHostKeyChecking=no \
              -o ConnectTimeout=10 \
              ec2-user@${aws_instance.k8s_master.public_ip}:/var/log/k8s-master-${local.cluster_id}.log \
              ./logs/master-${local.cluster_id}.log 2>/dev/null || true
              
          scp -i ${var.cluster_name}-key.pem \
              -o StrictHostKeyChecking=no \
              -o ConnectTimeout=10 \
              ec2-user@${aws_instance.k8s_master.public_ip}:/var/log/cloud-init-output.log \
              ./logs/master-cloud-init.log 2>/dev/null || true
          
          # cloud-init 완료 확인
          if [ -f "./logs/master-cloud-init.log" ]; then
            if grep -q "Cloud-init.*finished" ./logs/master-cloud-init.log; then
              echo "✅ 마스터 cloud-init 완료 감지! 로그 수집 중단합니다."
              break
            fi
          fi
          
          # 스크립트 완료 확인 (추가 체크)
          ssh -i ${var.cluster_name}-key.pem \
              -o StrictHostKeyChecking=no \
              -o ConnectTimeout=5 \
              ec2-user@${aws_instance.k8s_master.public_ip} \
              "test -f /tmp/master-init-status && echo 'SCRIPT_COMPLETE'" 2>/dev/null | grep -q "SCRIPT_COMPLETE" && {
            echo "✅ 마스터 스크립트 완료 감지! 로그 수집 중단합니다."
            break
          }
        done
        echo "마스터 로그 모니터링 완료"
      ) &
    EOT
  }
}

# 워커 노드 로그 수집
resource "null_resource" "worker_log_monitor" {
  count      = var.worker_count
  depends_on = [aws_instance.k8s_workers]

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ./logs
      
      # 워커 노드 로그 수집 (백그라운드)
      (
        echo "📋 워커-${count.index + 1} 노드 로그 모니터링 시작..."
        for i in {1..900}; do  # 최대 30분간 모니터링 (2초 * 900 = 30분)
          sleep 2
          echo "[$i/900] 워커-${count.index + 1} 로그 수집 중... ($(date))"
          
          # SSH로 로그 파일 다운로드
          scp -i ${var.cluster_name}-key.pem \
              -o StrictHostKeyChecking=no \
              -o ConnectTimeout=10 \
              ec2-user@${aws_instance.k8s_workers[count.index].public_ip}:/var/log/k8s-worker-${local.cluster_id}.log \
              ./logs/worker-${count.index + 1}-${local.cluster_id}.log 2>/dev/null || true
              
          scp -i ${var.cluster_name}-key.pem \
              -o StrictHostKeyChecking=no \
              -o ConnectTimeout=10 \
              ec2-user@${aws_instance.k8s_workers[count.index].public_ip}:/var/log/cloud-init-output.log \
              ./logs/worker-${count.index + 1}-cloud-init.log 2>/dev/null || true
          
          # cloud-init 완료 확인
          if [ -f "./logs/worker-${count.index + 1}-cloud-init.log" ]; then
            if grep -q "Cloud-init.*finished" ./logs/worker-${count.index + 1}-cloud-init.log; then
              echo "✅ 워커-${count.index + 1} cloud-init 완료 감지! 로그 수집 중단합니다."
              break
            fi
          fi
          
          # 스크립트 완료 확인 (추가 체크)
          ssh -i ${var.cluster_name}-key.pem \
              -o StrictHostKeyChecking=no \
              -o ConnectTimeout=5 \
              ec2-user@${aws_instance.k8s_workers[count.index].public_ip} \
              "test -f /tmp/worker-join-status && echo 'SCRIPT_COMPLETE'" 2>/dev/null | grep -q "SCRIPT_COMPLETE" && {
            echo "✅ 워커-${count.index + 1} 스크립트 완료 감지! 로그 수집 중단합니다."
            break
          }
        done
        echo "워커-${count.index + 1} 로그 모니터링 완료"
      ) &
    EOT
  }
}

# 로그 수집 안내
resource "null_resource" "log_collection_info" {
  depends_on = [
    null_resource.master_log_monitor,
    null_resource.worker_log_monitor
  ]

  provisioner "local-exec" {
    command = <<-EOT
      echo ""
      echo "=================================================="
      echo "📋 실시간 로그 수집 시작!"
      echo "=================================================="
      echo "로그 저장 위치: ./logs/"
      echo ""
      echo "📁 수집되는 로그 파일들:"
      echo "  🖥️  마스터 노드:"
      echo "     - ./logs/master-${local.cluster_id}.log"
      echo "     - ./logs/master-cloud-init.log"
      echo ""
      echo "  ⚙️  워커 노드들:"
      for i in {1..${var.worker_count}}; do
        echo "     - ./logs/worker-$i-${local.cluster_id}.log"
        echo "     - ./logs/worker-$i-cloud-init.log"
      done
      echo ""
      echo "🔍 실시간 로그 확인 방법:"
      echo "  tail -f ./logs/master-${local.cluster_id}.log"
      echo "  tail -f ./logs/worker-1-${local.cluster_id}.log"
      echo ""
      echo "💡 팁: 다른 터미널에서 위 명령어를 실행하세요!"
      echo "=================================================="
      echo ""
    EOT
  }
}

#===========================================
# SSH Commands File Generation
#===========================================

# SSH 접속 명령어를 파일로 자동 저장
resource "local_file" "ssh_commands" {
  depends_on = [
    aws_instance.k8s_master,
    aws_instance.k8s_workers
  ]

  filename = "${path.module}/ssh_commands.txt"
  content = <<-EOT
================================================================
🚀 Kubernetes Cluster SSH 접속 명령어
================================================================

📋 클러스터 정보:
- 클러스터 이름: ${var.cluster_name}
- 클러스터 ID: ${local.cluster_id}
- SSH 키 파일: ${var.cluster_name}-key.pem

================================================================
🖥️  마스터 노드 SSH 접속:
================================================================
ssh -i ${var.cluster_name}-key.pem ec2-user@${aws_instance.k8s_master.public_ip}

================================================================
⚙️  워커 노드 SSH 접속:
================================================================
%{for i, instance in aws_instance.k8s_workers~}
# 워커 노드 ${i + 1}
ssh -i ${var.cluster_name}-key.pem ec2-user@${instance.public_ip}

%{endfor~}
================================================================
📝 SSH Config 설정 (~/.ssh/config에 추가):
================================================================

# Kubernetes Cluster: ${var.cluster_name}
Host ${var.cluster_name}-master
    HostName ${aws_instance.k8s_master.public_ip}
    User ec2-user
    IdentityFile ${path.module}/${var.cluster_name}-key.pem
    
%{for i, instance in aws_instance.k8s_workers~}
Host ${var.cluster_name}-worker-${i + 1}
    HostName ${instance.public_ip}
    User ec2-user
    IdentityFile ${path.module}/${var.cluster_name}-key.pem
    
%{endfor~}

================================================================
🎯 사용 방법:
================================================================
1. SSH Config 설정 후:
   ssh ${var.cluster_name}-master
   ssh ${var.cluster_name}-worker-1

2. 직접 접속:
   위의 ssh 명령어 복사해서 사용

3. 클러스터 상태 확인 (마스터 노드에서):
   kubectl get nodes
   kubectl get pods -n kube-system

================================================================
생성일시: $(date)
================================================================
  EOT

  file_permission = "0644"
}

#===========================================
# Cleanup on Destroy
#===========================================
# Cleanup local files when destroying infrastructure
resource "null_resource" "cleanup_on_destroy" {
  # destroy 시에만 실행되는 정리 작업
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo ""
      echo "🧹 =============================================="
      echo "🧹 로컬 파일 정리 시작..."
      echo "🧹 =============================================="
      
      # 백그라운드 프로세스 종료 (로그 모니터링 프로세스들)
      echo "🔄 백그라운드 프로세스 종료 중..."
      pkill -f "scp.*logs" 2>/dev/null || echo "ℹ️  scp 프로세스가 실행 중이지 않습니다"
      pkill -f "ssh.*ec2-user" 2>/dev/null || echo "ℹ️  ssh 프로세스가 실행 중이지 않습니다"
      pkill -f "tail.*logs" 2>/dev/null || echo "ℹ️  tail 프로세스가 실행 중이지 않습니다"
      
      # 프로세스 종료 대기
      echo "⏳ 프로세스 종료 대기 중... (3초)"
      sleep 3
      
      # logs 폴더 삭제 (강제)
      if [ -d "./logs" ]; then
        echo "📁 logs 폴더 삭제 중..."
        # 파일 속성 변경 후 강제 삭제
        chmod -R 755 ./logs 2>/dev/null || true
        rm -rf ./logs 2>/dev/null || {
          echo "⚠️  일반 삭제 실패, 강제 삭제 시도 중..."
          sudo rm -rf ./logs 2>/dev/null || echo "❌ logs 폴더 삭제 실패 (수동 삭제 필요)"
        }
        
        if [ ! -d "./logs" ]; then
          echo "✅ logs 폴더 삭제 완료"
        else
          echo "⚠️  logs 폴더가 아직 존재합니다 (파일이 사용 중일 수 있음)"
        fi
      else
        echo "ℹ️  logs 폴더가 존재하지 않습니다"
      fi
      
      # 완료 파일 삭제
      if [ -f "./master-init-complete.txt" ]; then
        echo "📄 완료 파일 삭제 중..."
        rm -f ./master-init-complete.txt 2>/dev/null || echo "⚠️  완료 파일 삭제 실패"
        echo "✅ 완료 파일 삭제 완료"
      else
        echo "ℹ️  완료 파일이 존재하지 않습니다"
      fi
      
      # SSH 명령어 파일 삭제
      if [ -f "./ssh_commands.txt" ]; then
        echo "📄 SSH 명령어 파일 삭제 중..."
        rm -f ./ssh_commands.txt 2>/dev/null || echo "⚠️  SSH 명령어 파일 삭제 실패"
        echo "✅ SSH 명령어 파일 삭제 완료"
      else
        echo "ℹ️  SSH 명령어 파일이 존재하지 않습니다"
      fi
      
      # SSH 키 파일들 정리
      if ls ./*-key.pem 1> /dev/null 2>&1; then
        echo "🔑 SSH 키 파일 정리 중..."
        rm -f ./*-key.pem 2>/dev/null || echo "⚠️  SSH 키 파일 삭제 실패"
        echo "✅ SSH 키 파일 정리 완료"
      else
        echo "ℹ️  SSH 키 파일이 존재하지 않습니다"
      fi
      
      # 백업 파일들 정리
      if ls ./*.backup 1> /dev/null 2>&1; then
        echo "💾 백업 파일 정리 중..."
        rm -f ./*.backup 2>/dev/null || echo "⚠️  백업 파일 삭제 실패"
        echo "✅ 백업 파일 정리 완료"
      else
        echo "ℹ️  백업 파일이 존재하지 않습니다"
      fi
      
      # 임시 파일들 정리 (추가)
      echo "🗑️  임시 파일들 정리 중..."
      rm -f ./*.tmp 2>/dev/null || true
      rm -f ./*.log 2>/dev/null || true
      rm -f ./*.pid 2>/dev/null || true
      rm -f ./terraform.tfstate.backup* 2>/dev/null || true
      
      # 숨김 파일들 정리
      rm -f ./.terraform.lock.hcl.backup 2>/dev/null || true
      
      # 최종 확인
      echo "🔍 정리 결과 확인..."
      REMAINING_FILES=$(ls -la . 2>/dev/null | grep -E "(logs|\.log|\.tmp|key\.pem|ssh_commands\.txt|master-init-complete\.txt)" | wc -l)
      if [ "$REMAINING_FILES" -eq 0 ]; then
        echo "✅ 모든 대상 파일이 정리되었습니다"
      else
        echo "⚠️  일부 파일이 남아있습니다:"
        ls -la . 2>/dev/null | grep -E "(logs|\.log|\.tmp|key\.pem|ssh_commands\.txt|master-init-complete\.txt)" || true
        echo "💡 VSCode에서 파일을 열고 있거나 백그라운드 프로세스가 사용 중일 수 있습니다"
      fi
      
      echo ""
      echo "🎯 =============================================="
      echo "🎯 로컬 파일 정리 완료!"
      echo "🎯 =============================================="
      echo ""
    EOT
  }

}
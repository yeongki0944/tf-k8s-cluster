# terraform.tfvars

#===========================================
# AWS Configuration
#===========================================
aws_region = "ap-northeast-2"  # AWS 리전

#===========================================
# Cluster Configuration  
#===========================================
cluster_name = "test-cluster"  # 클러스터 이름 (리소스 명명에 사용)

#===========================================
# Network Configuration
#===========================================
vpc_cidr = "10.250.0.0/16"  # VPC CIDR 블록

# 퍼블릭 서브넷 CIDR (가용영역별로 생성)
public_subnet_cidrs = [
  "10.250.1.0/24",
  "10.250.2.0/24"
]

#===========================================
# EC2 Instance Configuration
#===========================================
master_instance_type = "t3.medium"  # 마스터 노드 인스턴스 타입
worker_instance_type = "t3.small"   # 워커 노드 인스턴스 타입
worker_count = 3                    # 워커 노드 개수
disk_size = 50                      # EBS 루트 볼륨 크기 (GB)

#===========================================
# System Configuration
#===========================================
timezone = "Asia/Seoul"  # 시스템 타임존

#===========================================
# Additional Tags
#===========================================
additional_tags = {}  # 추가 태그
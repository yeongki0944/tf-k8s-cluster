# Terraform Kubernetes Cluster on AWS

AWS EC2 인스턴스를 사용해 Kubernetes 클러스터를 자동으로 배포하는 Terraform 코드입니다.

## 🎯 목적

- **학습용**: Kubernetes 클러스터 구성 요소와 네트워킹 이해
- **실습환경**: kubeadm을 사용한 클러스터 구축 과정 학습
- **자동화**: Terraform을 통한 인프라 코드 관리 경험

## 🏗️ 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│                   VPC (10.250.0.0/16)                       │
├─────────────────────────────────────────────────────────────┤
│  Public Subnet 1        │  Public Subnet 2                  │
│  (10.250.1.0/24)        │  (10.250.2.0/24)                  │
│                         │                                   │
│  ┌─────────────────┐    │  ┌─────────────────┐              │
│  │  Master Node    │    │  │  Worker Node 1  │              │
│  │  (t3.medium)    │    │  │  (t3.small)     │              │
│  │  Control Plane  │    │  │                 │              │
│  └─────────────────┘    │  └─────────────────┘              │
│                         │                                   │
│                         │  ┌─────────────────┐              │
│                         │  │  Worker Node 2  │              │
│                         │  │  (t3.small)     │              │
│                         │  └─────────────────┘              │
│                         │                                   │
│                         │  ┌─────────────────┐              │
│                         │  │  Worker Node 3  │              │
│                         │  │  (t3.small)     │              │
│                         │  └─────────────────┘              │
└─────────────────────────────────────────────────────────────┘
```

## 📋 사전 요구사항

### 1. 필요한 도구
- [Terraform](https://www.terraform.io/downloads) (>= 1.0)
- [AWS CLI](https://aws.amazon.com/cli/) (>= 2.0)

### 2. AWS 자격증명 설정

#### 방법 1: IAM Role Anywhere (권장 - 현재 사용 중)
본 프로젝트에서는 IAM Role Anywhere와 사설 인증서를 사용하여 AWS 자격증명을 관리합니다.

#### 방법 2: Access Key 방식
```bash
# AWS CLI 설정
aws configure --profile mzadmin
# AWS Access Key ID 입력
# AWS Secret Access Key 입력
# Default region: ap-northeast-2
```

#### 방법 3: IAM Role 방식
EC2에서 실행 시 IAM Role을 인스턴스에 연결하여 사용 가능합니다.

## 🚀 사용 방법

### 1. 코드 클론 및 설정
```bash
git clone https://github.com/yeongki0944/tf-k8s-cluster.git
cd tf-k8s-cluster

# terraform.tfvars 파일 확인 및 수정
cp terraform.tfvars.example terraform.tfvars
```

### 2. 배포 실행
```bash
# Terraform 초기화
terraform init

# 배포 계획 확인
terraform plan

# 클러스터 배포 (10-15분 소요)
terraform apply
```

### 3. 클러스터 접속
```bash
# SSH 키 파일 권한 설정
chmod 600 test-cluster-key.pem

# 마스터 노드 접속
ssh -i test-cluster-key.pem ec2-user@<MASTER_PUBLIC_IP>

# 클러스터 상태 확인
kubectl get nodes
kubectl get pods -n kube-system
```

## 🔧 구성 요소

### 인프라 리소스
- **VPC**: 10.250.0.0/16 CIDR 블록
- **서브넷**: 2개 퍼블릭 서브넷 (Multi-AZ)
- **보안그룹**: 마스터/워커 노드용 (학습용으로 모든 포트 개방)
- **EC2 인스턴스**: 마스터 1개 + 워커 3개
- **IAM**: 노드용 Role 및 Parameter Store 접근 권한

### Kubernetes 구성
- **Container Runtime**: containerd
- **CNI**: Calico
- **Join Token**: AWS Parameter Store에 자동 저장
- **kubeconfig**: 마스터 노드 `/home/ec2-user/.kube/config`


## 📊 비용 예상 (ap-northeast-2 기준)

| 리소스 | 타입 | 시간당 | 월 예상 |
|--------|------|--------|---------|
| Master Node | t3.medium | ~$0.0416 | ~$30 |
| Worker Nodes | 3 x t3.small | ~$0.0624 | ~$45 |
| **총합** | | **~$0.104** | **~$75** |

*EBS 스토리지 비용 별도

## 📝 설정 변경

`terraform.tfvars` 파일에서 다음 값들을 수정할 수 있습니다:

```hcl
# 클러스터 설정
cluster_name = "my-cluster"      # 클러스터 이름
worker_count = 2                 # 워커 노드 개수

# 인스턴스 타입
master_instance_type = "t3.large"
worker_instance_type = "t3.medium"

# 네트워크 설정
vpc_cidr = "172.16.0.0/16"
public_subnet_cidrs = [
  "172.16.1.0/24",
  "172.16.2.0/24"
]
```

## 🔍 로그 모니터링

### 실시간 로그 확인
```bash
# 로컬에서 수집된 로그 확인
tail -f ./logs/master-<CLUSTER_ID>.log
tail -f ./logs/worker-1-<CLUSTER_ID>.log

# 인스턴스에서 직접 확인
ssh -i test-cluster-key.pem ec2-user@<IP>
tail -f /var/log/k8s-master-<CLUSTER_ID>.log
```

## 📡 실시간 로그 수집 메커니즘

### 로그 수집 메커니즘
```
┌─────────────────┐    scp (2초 간격)      ┌─────────────────┐
│   원격 서버       │ ────────────────────▶ │   로컬 머신       │
│                 │                       │                 │
│ /var/log/       │                       │ ./logs/         │
│ ├─ k8s-master-* │                       │ ├─ master-*.log │
│ ├─ k8s-worker-* │                       │ ├─ worker-*.log │
│ └─ cloud-init-* │                       │ └─ *cloud-init* │
└─────────────────┘                       └─────────────────┘
```

### 수집되는 로그 파일들

#### 마스터 노드
```bash
# 원격 경로 → 로컬 경로
/var/log/k8s-master-${cluster_id}.log → ./logs/master-${cluster_id}.log
/var/log/cloud-init-output.log → ./logs/master-cloud-init.log
```

#### 워커 노드들
```bash
# 각 워커별로 수집
/var/log/k8s-worker-${cluster_id}.log → ./logs/worker-N-${cluster_id}.log
/var/log/cloud-init-output.log → ./logs/worker-N-cloud-init.log
```

### 로그 수집 프로세스

#### 1. 백그라운드 실행
```bash
# null_resource 프로비저너가 백그라운드로 실행
(
  for i in {1..900}; do  # 최대 30분 모니터링
    sleep 2
    scp -i key.pem ec2-user@IP:/var/log/k8s-*.log ./logs/
  done
) &
```

#### 2. 종료 조건
- **cloud-init 완료**: `Cloud-init.*finished` 패턴 감지
- **스크립트 완료**: `/tmp/master-init-status` 또는 `/tmp/worker-join-status` 파일 확인
- **타임아웃**: 최대 30분 (900회 × 2초) 후 자동 종료

#### 3. 실시간 확인 방법
```bash
# 다른 터미널에서 실시간 모니터링
tail -f ./logs/master-${cluster_id}.log
tail -f ./logs/worker-1-${cluster_id}.log

# 수집 상태 확인
ls -la ./logs/
```

### 로그 수집 중단 및 정리

#### 자동 중단 조건
1. **정상 완료**: cloud-init finished 감지
2. **스크립트 완료**: 상태 파일 생성 확인  
3. **타임아웃**: 30분 경과

#### 수동 중단 방법
```bash
# 백그라운드 프로세스 확인
ps aux | grep -E "(scp|ssh).*ec2-user"

# 프로세스 종료
pkill -f "scp.*logs"
pkill -f "ssh.*ec2-user"
```

### 클러스터 상태 확인
```bash
# 노드 상태
kubectl get nodes -o wide

# 시스템 파드 상태
kubectl get pods -n kube-system

# 클러스터 정보
kubectl cluster-info
```

## 🔄 클러스터 조인 메커니즘

### 마스터-워커 노드 조인 과정
```
1. 마스터 노드 초기화
   ├── kubeadm init 실행
   ├── 조인 토큰 생성
   └── AWS Parameter Store에 조인 명령어 저장
      └── /k8s/<CLUSTER_ID>/join-command

2. Terraform 대기 프로세스
   ├── null_resource.wait_for_master_init 실행
   ├── Parameter Store 모니터링 (10초 간격, 최대 15분)
   ├── "kubeadm join" 명령어 감지 시 다음 단계 진행
   └── master-init-complete.txt 파일 생성

3. 워커 노드 조인
   ├── 마스터 초기화 완료 확인
   ├── Parameter Store에서 조인 명령어 조회
   └── kubeadm join 실행하여 클러스터 참여
```

### Parameter Store 기반 동기화
- **문제**: 워커 노드가 마스터 준비 전에 조인 시도하는 문제
- **해결**: AWS Parameter Store를 통한 조인 토큰 공유 및 대기 메커니즘
- **모니터링**: 90회 재시도 (10초 간격 = 최대 15분 대기)


## ⚠️ 보안 주의사항

**현재 설정은 학습용입니다:**
- 보안그룹이 모든 트래픽(0.0.0.0/0)을 허용
- 프로덕션 환경에서는 필요한 포트만 개방하세요

### 프로덕션용 보안 강화
```hcl
# 마스터 노드 보안그룹 예시
ingress {
  from_port   = 6443
  to_port     = 6443
  protocol    = "tcp"
  cidr_blocks = ["<YOUR_IP>/32"]  # API Server
}

ingress {
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["<YOUR_IP>/32"]  # SSH
}
```


## 🧹 리소스 정리

```bash
# 전체 인프라 삭제
terraform destroy

# 로컬 파일 정리 (자동 실행됨)
# - SSH 키 파일 (*.pem)
# - 로그 폴더 (./logs/)
# - 임시 파일들
```

## 📄 라이선스

이 프로젝트는 학습 목적으로 공개되었습니다.

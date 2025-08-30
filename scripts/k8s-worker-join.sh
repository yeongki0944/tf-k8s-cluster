#!/bin/bash
# k8s-worker-join.sh - Kubernetes Worker Node Join (수정된 버전)

# Terraform 변수들 (templatefile에서 전달받음)
CLUSTER_ID="${cluster_id}"
PARAMETER_NAME="${parameter_name}"
AWS_REGION="${aws_region}"
WORKER_INDEX="${worker_index}"

LOG_FILE="/var/log/k8s-worker-$CLUSTER_ID.log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "=== Kubernetes Worker Join Started at $(date) ==="
echo "Cluster ID: $CLUSTER_ID, Worker: $WORKER_INDEX"

#===========================================
# Phase 1: 시스템 기본 설정
#===========================================
echo "[PHASE 1] 시스템 기본 설정"

# 시간대 및 호스트명 설정
sudo timedatectl set-timezone Asia/Seoul
sudo hostnamectl set-hostname "k8s-worker-$WORKER_INDEX"

# 시스템 업데이트 및 기본 패키지 (curl 제외 - 이미 설치됨)
sudo dnf update -y
sudo dnf install -y wget vim git

# swap 비활성화
sudo swapoff -a

echo "[PHASE 1] 완료"

#===========================================
# Phase 2: containerd 설치
#===========================================
echo "[PHASE 2] containerd 설치"

sudo dnf install -y containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i "/SystemdCgroup = false/c\            SystemdCgroup = true" /etc/containerd/config.toml
sudo systemctl enable --now containerd

# containerd 상태 확인
if systemctl is-active --quiet containerd; then
    echo "[PHASE 2] containerd 실행 확인"
else
    echo "[ERROR] containerd 실행 실패"
    exit 1
fi

echo "[PHASE 2] 완료"

#===========================================
# Phase 3: 네트워크 설정
#===========================================
echo "[PHASE 3] 네트워크 설정"

# 커널 모듈
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# sysctl 설정
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "[PHASE 3] 완료"

#===========================================
# Phase 4: Kubernetes 설치
#===========================================
echo "[PHASE 4] Kubernetes 설치"

# Kubernetes 리포지토리
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.33/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.33/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

# SELinux 설정
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# Kubernetes 구성 요소 설치
sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
sudo systemctl enable kubelet

# 설치 확인
for cmd in kubelet kubeadm; do
    if command -v $cmd >/dev/null 2>&1; then
        echo "[PHASE 4] $cmd 설치 확인"
    else
        echo "[ERROR] $cmd 설치 실패"
        exit 1
    fi
done

echo "[PHASE 4] 완료"

#===========================================
# Phase 5: 로컬 IP 확인
#===========================================
echo "[PHASE 5] 로컬 IP 확인"

# 로컬 IP 확인 (IMDSv2)
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
LOCAL_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4)

if [[ ! $LOCAL_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[ERROR] IP 주소 확인 실패: $LOCAL_IP"
    exit 1
fi
echo "[PHASE 5] 워커 IP: $LOCAL_IP"

echo "[PHASE 5] 완료"

#===========================================
# Phase 6: 조인 토큰 대기
#===========================================
echo "[PHASE 6] 마스터 노드 조인 토큰 대기"

MAX_ATTEMPTS=30
SLEEP_INTERVAL=30

echo "[PHASE 6] 최대 대기 시간: 15분 ($MAX_ATTEMPTS번 시도)"

for attempt in $(seq 1 $MAX_ATTEMPTS); do
    echo "[PHASE 6] 조인 명령어 확인... ($attempt/$MAX_ATTEMPTS)"
    
    JOIN_CMD=$(aws ssm get-parameter \
        --region "$AWS_REGION" \
        --name "$PARAMETER_NAME" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text 2>/dev/null)
    
    # 조인 명령어 유효성 확인
    if [[ $JOIN_CMD == kubeadm\ join\ * ]] && [[ $JOIN_CMD =~ --token.*--discovery-token-ca-cert-hash ]]; then
        echo "[PHASE 6] 유효한 조인 명령어 수신!"
        break
    fi
    
    if [ $attempt -lt $MAX_ATTEMPTS ]; then
        echo "[PHASE 6] $SLEEP_INTERVAL초 후 재시도..."
        sleep $SLEEP_INTERVAL
    else
        echo "[ERROR] 조인 명령어 수신 실패"
        exit 1
    fi
done

echo "[PHASE 6] 완료"

#===========================================
# Phase 7: 클러스터 조인
#===========================================
echo "[PHASE 7] 클러스터 조인"

echo "[PHASE 7] 실행 명령어: $JOIN_CMD"

if eval "sudo $JOIN_CMD"; then
    echo "[PHASE 7] 클러스터 조인 성공"
else
    echo "[ERROR] 클러스터 조인 실패"
    exit 1
fi

# kubelet 상태 확인
sleep 10
if systemctl is-active --quiet kubelet; then
    echo "[PHASE 7] kubelet 실행 확인"
else
    echo "[ERROR] kubelet 실행 실패"
    sudo systemctl restart kubelet
    sleep 5
    if systemctl is-active --quiet kubelet; then
        echo "[PHASE 7] kubelet 재시작 성공"
    else
        echo "[ERROR] kubelet 재시작 실패"
    fi
fi

# 노드 등록 확인 (로그 기반)
echo "[PHASE 7] 노드 등록 확인..."
sleep 30
if sudo journalctl -u kubelet --since="2 minutes ago" | grep -q "Successfully registered\|Node join complete"; then
    echo "[PHASE 7] 노드 등록 확인"
else
    echo "[PHASE 7] 노드 등록 확인 불가 (마스터에서 확인 필요)"
fi

echo "[PHASE 7] 완료"

#===========================================
# 완료
#===========================================
echo ""
echo "=============================================="
echo "🎉 워커 노드 조인 완료!"
echo "=============================================="
echo "Cluster ID: $CLUSTER_ID"
echo "Worker: $WORKER_INDEX"
echo "Worker IP: $LOCAL_IP"
echo "Hostname: $(hostname)"
echo "kubelet: $(systemctl is-active kubelet)"
echo "containerd: $(systemctl is-active containerd)"
echo "=============================================="

# 완료 표시
echo "WORKER_JOIN_SUCCESS" > /tmp/worker-join-status
echo "=== Worker Join Completed at $(date) ==="
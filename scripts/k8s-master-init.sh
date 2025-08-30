#!/bin/bash
# k8s-master-init.sh - Kubernetes Master Node Initialization (수정된 버전)

# Terraform 변수들 (templatefile에서 전달받음)
CLUSTER_ID="${cluster_id}"
PARAMETER_NAME="${parameter_name}"
AWS_REGION="${aws_region}"
CLUSTER_NAME="${cluster_name}"

LOG_FILE="/var/log/k8s-master-$CLUSTER_ID.log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "=== Kubernetes Master Init Started at $(date) ==="
echo "Cluster ID: $CLUSTER_ID"

#===========================================
# Phase 1: 시스템 기본 설정
#===========================================
echo "[PHASE 1] 시스템 기본 설정"

# 시간대 및 호스트명 설정
sudo timedatectl set-timezone Asia/Seoul
sudo hostnamectl set-hostname k8s-master

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
for cmd in kubelet kubeadm kubectl; do
    if command -v $cmd >/dev/null 2>&1; then
        echo "[PHASE 4] $cmd 설치 확인"
    else
        echo "[ERROR] $cmd 설치 실패"
        exit 1
    fi
done

echo "[PHASE 4] 완료"

#===========================================
# Phase 5: 마스터 노드 초기화
#===========================================
echo "[PHASE 5] 마스터 노드 초기화"

# 로컬 IP 확인 (IMDSv2)
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)
LOCAL_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4)

if [[ ! $LOCAL_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[ERROR] IP 주소 확인 실패: $LOCAL_IP"
    exit 1
fi
echo "[PHASE 5] 로컬 IP: $LOCAL_IP"

# kubeadm init
echo "[PHASE 5] kubeadm init 실행..."
if sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=$LOCAL_IP; then
    echo "[PHASE 5] kubeadm init 성공"
else
    echo "[ERROR] kubeadm init 실패"
    exit 1
fi

# kubectl 설정 (root + ec2-user 둘 다 설정)
sleep 10
echo "[PHASE 5] kubectl 설정 파일 복사 중..."

# root용 kubectl 설정
KUBE_DIR="/root/.kube"
sudo mkdir -p $KUBE_DIR
sudo cp -i /etc/kubernetes/admin.conf $KUBE_DIR/config
sudo chown root:root $KUBE_DIR/config

# ec2-user용 kubectl 설정 추가
EC2_KUBE_DIR="/home/ec2-user/.kube"
sudo mkdir -p $EC2_KUBE_DIR
sudo cp -i /etc/kubernetes/admin.conf $EC2_KUBE_DIR/config
sudo chown ec2-user:ec2-user $EC2_KUBE_DIR/config

echo "[PHASE 5] kubectl 설정 파일 복사 완료"

# kubectl 작동 확인 (sudo kubectl 사용)
echo "[PHASE 5] kubectl 동작 확인 중..."
for i in {1..24}; do  # 최대 2분 (5초 × 24번)
    if sudo kubectl get nodes >/dev/null 2>&1; then
        echo "[PHASE 5] kubectl 설정 완료 ($i번째 시도에서 성공)"
        echo "[PHASE 5] 현재 노드 상태:"
        sudo kubectl get nodes
        echo "[PHASE 5] 클러스터 정보:"
        sudo kubectl cluster-info
        break
    else
        echo "[PHASE 5] kubectl 확인 실패... ($i/24) 5초 후 재시도"
        if [ $i -lt 24 ]; then
            sleep 5
        else
            echo "[ERROR] kubectl 설정 실패 - 2분 시도 후 포기"
            exit 1
        fi
    fi
done



#===========================================
# Phase 6: CNI 설치
#===========================================
echo "[PHASE 6] Calico CNI 설치"
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml

# Calico 파드 대기
echo "[PHASE 6] Calico 파드 시작 대기..."

for i in {1..24}; do
    sleep 5
    READY=$(kubectl get pods -n kube-system | grep calico | grep -c Running 2>/dev/null || echo "0")
    if [ "$READY" -ge 2 ]; then
        echo "[PHASE 6] Calico 파드 실행 확인 ($READY개)"
        break
    fi
    echo "[PHASE 6] 대기중... ($i/24)"
done

# 노드 상태 확인
sleep 15
NODE_STATUS=$(kubectl get nodes --no-headers | awk '{print $2}')
echo "[PHASE 6] 노드 상태: $NODE_STATUS"




echo "[PHASE 6] 완료"

#===========================================
# Phase 7: 조인 토큰 생성 및 저장
#===========================================
echo "[PHASE 7] 조인 토큰 생성"

# 조인 명령어 생성
JOIN_CMD=$(kubeadm token create --print-join-command --ttl=24h 2>/dev/null)
if [[ $JOIN_CMD == kubeadm\ join\ * ]]; then
    echo "[PHASE 7] 조인 명령어 생성 성공"
else
    echo "[ERROR] 조인 명령어 생성 실패"
    exit 1
fi

# Parameter Store 저장
if aws ssm put-parameter \
    --region "$AWS_REGION" \
    --name "$PARAMETER_NAME" \
    --value "$JOIN_CMD" \
    --type "SecureString" \
    --overwrite; then
    echo "[PHASE 7] Parameter Store 저장 성공"
else
    echo "[ERROR] Parameter Store 저장 실패"
fi

echo "[PHASE 7] 완료"

#===========================================
# 완료
#===========================================
echo ""
echo "=============================================="
echo "🎉 마스터 노드 초기화 완료!"
echo "=============================================="
echo "Cluster ID: $CLUSTER_ID"
echo "Master IP: $LOCAL_IP"
echo "Node Status: $(kubectl get nodes --no-headers | awk '{print $2}' 2>/dev/null)"
echo "Join Command: $JOIN_CMD"
echo "=============================================="

# 상태 확인
kubectl get nodes
kubectl get pods -n kube-system

# 완료 표시
echo "MASTER_INIT_SUCCESS" > /tmp/master-init-status
echo "=== Master Init Completed at $(date) ==="
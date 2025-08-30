#!/bin/bash
# k8s-common-setup.sh - Common Setup for All Kubernetes Nodes
# Phase 1-4: 마스터/워커 노드 공통 설정
# This script is used by both master and worker nodes

# Set timezone (passed from Terraform)
TIMEZONE="Asia/Seoul"

# 로그 설정
LOG_FILE="/var/log/k8s-common-setup.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# 로그 함수들
log_info() {
    echo "[INFO]  [$1] $2" | tee -a $LOG_FILE
}

log_success() {
    echo "[SUCCESS] [$1] $2" | tee -a $LOG_FILE
}

log_error() {
    echo "[ERROR] [$1] $2" | tee -a $LOG_FILE
}

log_phase() {
    echo "" | tee -a $LOG_FILE
    echo "===========================================" | tee -a $LOG_FILE
    echo "[$1] $2" | tee -a $LOG_FILE
    echo "===========================================" | tee -a $LOG_FILE
}

# 스크립트 시작
echo "Kubernetes Common Setup Started at $TIMESTAMP" | tee $LOG_FILE

#===========================================
# Phase 1: 시스템 기본 설정
#===========================================
log_phase "PHASE 1" "시스템 기본 설정"

# 1-1. 시간대 설정
log_info "PHASE 1" "시간대를 $TIMEZONE으로 설정..."
sudo timedatectl set-timezone $TIMEZONE
log_success "PHASE 1" "시간대 설정 완료: $(timedatectl | grep 'Time zone')"

# 1-2. 시스템 업데이트
log_info "PHASE 1" "시스템 업데이트 중..."
if sudo dnf update -y >> $LOG_FILE 2>&1; then
    log_success "PHASE 1" "시스템 업데이트 완료"
else
    log_error "PHASE 1" "시스템 업데이트 실패"
fi

# 1-3. swap 비활성화 확인
log_info "PHASE 1" "swap 비활성화 확인..."
sudo swapoff -a
log_success "PHASE 1" "swap 비활성화 완료"

# 1-4. 필수 패키지 설치 (있는지 확인 후 설치)
log_info "PHASE 1" "필수 패키지 확인 및 설치..."

# curl 확인
if command -v curl >/dev/null 2>&1; then
    log_success "PHASE 1" "curl: 이미 설치됨 ($(curl --version | head -n1))"
else
    log_info "PHASE 1" "curl 설치 중..."
    sudo dnf install -y curl >> $LOG_FILE 2>&1
    log_success "PHASE 1" "curl 설치 완료"
fi

# wget 확인
if command -v wget >/dev/null 2>&1; then
    log_success "PHASE 1" "wget: 이미 설치됨"
else
    log_info "PHASE 1" "wget 설치 중..."
    sudo dnf install -y wget >> $LOG_FILE 2>&1
    log_success "PHASE 1" "wget 설치 완료"
fi

# vim 확인
if command -v vim >/dev/null 2>&1; then
    log_success "PHASE 1" "vim: 이미 설치됨"
else
    log_info "PHASE 1" "vim 설치 중..."
    sudo dnf install -y vim >> $LOG_FILE 2>&1
    log_success "PHASE 1" "vim 설치 완료"
fi

# git 확인
if command -v git >/dev/null 2>&1; then
    log_success "PHASE 1" "git: 이미 설치됨"
else
    log_info "PHASE 1" "git 설치 중..."
    sudo dnf install -y git >> $LOG_FILE 2>&1
    log_success "PHASE 1" "git 설치 완료"
fi

log_success "PHASE 1" "시스템 기본 설정 완료"

#===========================================
# Phase 2: Container Runtime 설치 (containerd)
#===========================================
log_phase "PHASE 2" "containerd 설치"

# 2-1. containerd 설치
log_info "PHASE 2" "containerd 설치 중..."
if sudo dnf install -y containerd >> $LOG_FILE 2>&1; then
    log_success "PHASE 2" "containerd 설치 완료"
else
    log_error "PHASE 2" "containerd 설치 실패"
    exit 1
fi

# 2-2. containerd 기본 설정 생성
log_info "PHASE 2" "containerd 기본 설정 생성..."
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >> $LOG_FILE
log_success "PHASE 2" "containerd 기본 설정 생성 완료"

# 2-3. SystemdCgroup 활성화 (cgroup v2 지원)
log_info "PHASE 2" "SystemdCgroup 설정 확인 및 추가..."
if ! grep -q "SystemdCgroup" /etc/containerd/config.toml; then
    log_info "PHASE 2" "SystemdCgroup 설정 추가 중..."
    sudo sed -i "/ShimCgroup = ''/a\\            SystemdCgroup = true" /etc/containerd/config.toml
    log_success "PHASE 2" "SystemdCgroup = true 추가 완료"
else
    log_success "PHASE 2" "SystemdCgroup 설정이 이미 존재함"
fi

# 2-4. containerd 서비스 시작
log_info "PHASE 2" "containerd 서비스 활성화 및 시작..."
sudo systemctl enable containerd >> $LOG_FILE 2>&1
sudo systemctl start containerd >> $LOG_FILE 2>&1

# 2-5. 서비스 상태 및 버전 확인
log_info "PHASE 2" "containerd 상태 확인..."
if systemctl is-active --quiet containerd; then
    log_success "PHASE 2" "containerd 서비스 실행 중"
    log_success "PHASE 2" "containerd 버전: $(containerd --version)"
    
    if [ -S /run/containerd/containerd.sock ]; then
        log_success "PHASE 2" "containerd 소켓 파일 확인: /run/containerd/containerd.sock"
        log_success "PHASE 2" "containerd 설치 및 설정 완료"
    else
        log_error "PHASE 2" "containerd 소켓 파일이 존재하지 않음"
        exit 1
    fi
else
    log_error "PHASE 2" "containerd 서비스가 실행되지 않음"
    sudo systemctl status containerd --no-pager | tee -a $LOG_FILE
    exit 1
fi

#===========================================
# Phase 3: 네트워크 및 커널 모듈 설정
#===========================================
log_phase "PHASE 3" "네트워크 및 커널 모듈 설정"

# 3-1. 브릿지 네트워크 설정을 위한 모듈 로드
log_info "PHASE 3" "커널 모듈 설정 파일 생성..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
log_success "PHASE 3" "/etc/modules-load.d/k8s.conf 생성 완료"

# 3-2. 모듈 즉시 로드
log_info "PHASE 3" "overlay 모듈 로드..."
sudo modprobe overlay
log_info "PHASE 3" "br_netfilter 모듈 로드..."
sudo modprobe br_netfilter

# 3-3. 모듈 로드 확인
log_info "PHASE 3" "커널 모듈 로드 확인..."
if lsmod | grep -q overlay; then
    log_success "PHASE 3" "overlay 모듈 로드 확인"
else
    log_error "PHASE 3" "overlay 모듈 로드 실패"
fi

if lsmod | grep -q br_netfilter; then
    log_success "PHASE 3" "br_netfilter 모듈 로드 확인"
else
    log_error "PHASE 3" "br_netfilter 모듈 로드 실패"
fi

# 3-4. sysctl 파라미터 설정
log_info "PHASE 3" "sysctl 파라미터 설정..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
log_success "PHASE 3" "/etc/sysctl.d/k8s.conf 생성 완료"

# 3-5. sysctl 설정 적용
log_info "PHASE 3" "sysctl 설정 적용 중..."
sudo sysctl --system >> $LOG_FILE 2>&1
log_success "PHASE 3" "sysctl 설정 적용 완료"

# 3-6. 설정 적용 확인
log_info "PHASE 3" "네트워크 및 커널 모듈 설정 확인..."

# 커널 모듈 확인
if lsmod | grep -q overlay; then
    log_success "PHASE 3" "overlay 모듈 로드 확인"
else
    log_error "PHASE 3" "overlay 모듈 로드 실패"
    exit 1
fi

if lsmod | grep -q br_netfilter; then
    log_success "PHASE 3" "br_netfilter 모듈 로드 확인"
else
    log_error "PHASE 3" "br_netfilter 모듈 로드 실패"
    exit 1
fi

# sysctl 파라미터 확인
if [ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" = "1" ]; then
    log_success "PHASE 3" "bridge-nf-call-iptables = 1 적용 확인"
else
    log_error "PHASE 3" "bridge-nf-call-iptables 설정 실패"
    exit 1
fi

if [ "$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null)" = "1" ]; then
    log_success "PHASE 3" "bridge-nf-call-ip6tables = 1 적용 확인"
else
    log_error "PHASE 3" "bridge-nf-call-ip6tables 설정 실패"
    exit 1
fi

if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; then
    log_success "PHASE 3" "ip_forward = 1 적용 확인"
else
    log_error "PHASE 3" "ip_forward 설정 실패"
    exit 1
fi

# 설정 파일 확인
if [ -f "/etc/modules-load.d/k8s.conf" ] && [ -f "/etc/sysctl.d/k8s.conf" ]; then
    log_success "PHASE 3" "설정 파일 생성 확인"
    log_success "PHASE 3" "네트워크 및 커널 모듈 설정 완료"
else
    log_error "PHASE 3" "설정 파일 생성 실패"
    exit 1
fi

#===========================================
# Phase 4: Kubernetes 구성 요소 설치
#===========================================
log_phase "PHASE 4" "Kubernetes 구성 요소 설치"

# 4-1. Kubernetes 리포지토리 추가
log_info "PHASE 4" "Kubernetes 리포지토리 설정 중..."
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.33/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.33/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
log_success "PHASE 4" "Kubernetes 리포지토리 설정 완료"

# 4-2. SELinux permissive 모드 설정
log_info "PHASE 4" "SELinux 상태 확인 및 설정..."
current_selinux=$(getenforce)
log_info "PHASE 4" "현재 SELinux 상태: $current_selinux"

if [ "$current_selinux" != "Permissive" ] && [ "$current_selinux" != "Disabled" ]; then
    log_info "PHASE 4" "SELinux를 permissive 모드로 설정 중..."
    sudo setenforce 0
    sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
    log_success "PHASE 4" "SELinux permissive 모드 설정 완료"
else
    log_success "PHASE 4" "SELinux가 이미 permissive 또는 disabled 상태"
fi

# 4-3. kubeadm, kubelet, kubectl 설치
log_info "PHASE 4" "Kubernetes 구성 요소 설치 중..."
if sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes >> $LOG_FILE 2>&1; then
    log_success "PHASE 4" "Kubernetes 구성 요소 설치 완료"
else
    log_error "PHASE 4" "Kubernetes 구성 요소 설치 실패"
    exit 1
fi

# 4-4. kubelet 서비스 활성화
log_info "PHASE 4" "kubelet 서비스 활성화 중..."
if sudo systemctl enable kubelet >> $LOG_FILE 2>&1; then
    log_success "PHASE 4" "kubelet 서비스 활성화 완료"
else
    log_error "PHASE 4" "kubelet 서비스 활성화 실패"
    exit 1
fi

# 4-5. 설치 확인
log_info "PHASE 4" "Kubernetes 구성 요소 설치 확인..."

# kubeadm 버전 확인
if command -v kubeadm >/dev/null 2>&1; then
    KUBEADM_VERSION=$(kubeadm version --output=short 2>/dev/null || kubeadm version | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+')
    log_success "PHASE 4" "kubeadm 설치 확인: $KUBEADM_VERSION"
else
    log_error "PHASE 4" "kubeadm 설치 실패"
    exit 1
fi

# kubelet 버전 확인
if command -v kubelet >/dev/null 2>&1; then
    KUBELET_VERSION=$(kubelet --version | cut -d' ' -f2)
    log_success "PHASE 4" "kubelet 설치 확인: $KUBELET_VERSION"
else
    log_error "PHASE 4" "kubelet 설치 실패"
    exit 1
fi

# kubectl 버전 확인
if command -v kubectl >/dev/null 2>&1; then
    KUBECTL_VERSION=$(kubectl version --client --output=json 2>/dev/null | grep -o '"gitVersion":"[^"]*' | cut -d'"' -f4 || kubectl version --client | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+')
    log_success "PHASE 4" "kubectl 설치 확인: $KUBECTL_VERSION"
else
    log_error "PHASE 4" "kubectl 설치 실패"
    exit 1
fi

# kubelet 서비스 상태 확인
if systemctl is-enabled --quiet kubelet; then
    log_success "PHASE 4" "kubelet 서비스 enabled 상태 확인"
    log_success "PHASE 4" "Kubernetes 구성 요소 설치 완료"
else
    log_error "PHASE 4" "kubelet 서비스가 enabled 상태가 아님"
    exit 1
fi

#===========================================
# 공통 설정 완료
#===========================================
log_phase "COMPLETE" "공통 설정 완료"
log_success "COMPLETE" "모든 공통 설정이 완료되었습니다."

# 설치된 구성 요소 요약
echo "" | tee -a $LOG_FILE
echo "===========================================" | tee -a $LOG_FILE
echo "설치된 구성 요소 요약" | tee -a $LOG_FILE
echo "===========================================" | tee -a $LOG_FILE
echo "시간대: $(timedatectl | grep 'Time zone' | awk '{print $3}')" | tee -a $LOG_FILE
echo "containerd: $(containerd --version | cut -d' ' -f3)" | tee -a $LOG_FILE
echo "kubeadm: $KUBEADM_VERSION" | tee -a $LOG_FILE
echo "kubelet: $KUBELET_VERSION" | tee -a $LOG_FILE  
echo "kubectl: $KUBECTL_VERSION" | tee -a $LOG_FILE
echo "===========================================" | tee -a $LOG_FILE
echo "이제 마스터는 kubeadm init을, 워커는 kubeadm join을 실행할 준비가 되었습니다." | tee -a $LOG_FILE
echo "===========================================" | tee -a $LOG_FILE
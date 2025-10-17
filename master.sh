#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive

# 필수 패키지 설치
apt-get update -y
apt-get install -y curl awscli docker.io apt-transport-https ca-certificates gnupg jq || true

# Docker 활성화
systemctl enable docker
systemctl start docker

# Kubernetes apt repo 등록
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg -o /tmp/k8s-key.gpg || true
install -o root -g root -m 644 /tmp/k8s-key.gpg /usr/share/keyrings/kubernetes-archive-keyring.gpg || true
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y || true
apt-get install -y kubelet kubeadm kubectl || true
apt-mark hold kubelet kubeadm kubectl || true

# swap 비활성화 (kubeadm 요구사항)
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# kubeadm init (single master, default pod-network-cidr: Calico용)
kubeadm init --pod-network-cidr=192.168.0.0/16

# kubectl config 설정 (일반 사용자 접근용)
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# CNI 플러그인 설치 (Calico)
curl https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml -O
kubectl apply -f calico.yaml

# (옵션) 마스터 노드에서도 Pod 스케줄 가능하게 (테스트용)
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

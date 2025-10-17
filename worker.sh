#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl awscli docker.io apt-transport-https ca-certificates gnupg jq || true
# k8s repo & install (같은 방식)
# S3에서 join_cmd.sh 받아 실행
for i in $(seq 1 30); do
  if aws s3 cp s3://${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/join_cmd.sh /root/join_cmd.sh --no-progress; then
    chmod +x /root/join_cmd.sh
    bash /root/join_cmd.sh && break
  fi
  sleep 10
done
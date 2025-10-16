provider "aws" {
  region = var.aws_region
}

resource "aws_security_group" "default" {
  name        = "devops-cd-sg"
  description = "devops-cd-sg"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API (if you deploy a master)
  ingress {
    from_port   = 6443
    to_port     = 6443
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

# arogoCD
resource "aws_instance" "argo_server" {
  ami                   = data.aws_ami.ubuntu.id
  instance_type         = var.instance_type
  key_name              = var.aws_key_name
  subnet_id             = var.subnet_id
  vpc_security_group_ids = [aws_security_group.default.id]
  iam_instance_profile  = aws_iam_instance_profile.argo_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    export DEBIAN_FRONTEND=noninteractive

    retry() { n=0; until [ $n -ge 5 ]; do "$@" && break; n=$((n+1)); sleep 5; done }

    apt-get update -y
    retry apt-get install -y docker.io curl apt-transport-https ca-certificates gnupg jq awscli || true
    systemctl enable --now docker || true

    # robust K8s apt install: keyring + signed-by, with fallback to kubectl binary
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg -o /tmp/k8s-key.gpg || true
    if [ -s /tmp/k8s-key.gpg ]; then
      install -o root -g root -m 644 /tmp/k8s-key.gpg /usr/share/keyrings/kubernetes-archive-keyring.gpg || true
      echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
      apt-get update -y || true
      retry apt-get install -y kubelet kubeadm kubectl || true
      apt-mark hold kubelet kubeadm kubectl || true
    else
      echo "Failed to download K8s apt key; attempting kubectl fallback" >&2
      KUBEV=$$(curl -fsSL https://dl.k8s.io/release/stable.txt || echo "")
      if [ -n "$${KUBEV}" ]; then
        curl -fsSL "https://dl.k8s.io/release/$${KUBEV}/bin/linux/amd64/kubectl" -o /tmp/kubectl || true
        install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl || true
      fi
    fi

    # kubeadm init (single control-plane) with retry
    retry kubeadm init --pod-network-cidr=10.244.0.0/16 | tee /root/kubeadm-init.out || true

    # setup kubeconfig for ubuntu user if admin.conf exists
    if [ -f /etc/kubernetes/admin.conf ]; then
      mkdir -p /home/ubuntu/.kube
      cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
      chown -R ubuntu:ubuntu /home/ubuntu/.kube
      chmod 600 /home/ubuntu/.kube/config
    fi

    # install Flannel CNI (or your CNI)
    su - ubuntu -c "kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml" || true

    # wait best-effort
    su - ubuntu -c "kubectl wait --for=condition=Ready nodes --all --timeout=300s" || true

    # create serviceaccount for ArgoCD and bind (narrow permissions in prod)
    su - ubuntu -c "kubectl create serviceaccount argocd-manager -n kube-system || true"
    su - ubuntu -c "kubectl create clusterrolebinding argocd-manager-binding --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager || true"

    # build kubeconfig for the SA
    SA_SECRET=$$(su - ubuntu -c "kubectl -n kube-system get sa argocd-manager -o jsonpath='{.secrets[0].name}'" || echo "")
    if [ -n "$${SA_SECRET}" ]; then
      SA_TOKEN=$$(su - ubuntu -c "kubectl -n kube-system get secret $${SA_SECRET} -o jsonpath='{.data.token}' | base64 -d" || echo "")
      APISERVER=$$(su - ubuntu -c "kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'" || echo "")
      KUBECONFIG_OUT="/home/ubuntu/argocd-kubeconfig"
      su - ubuntu -c "kubectl config set-cluster argocd-cluster --server=$${APISERVER} --certificate-authority=/etc/kubernetes/pki/ca.crt --embed-certs=true --kubeconfig=$${KUBECONFIG_OUT}" || true
      su - ubuntu -c "kubectl config set-credentials argocd-manager --token='$${SA_TOKEN}' --kubeconfig=$${KUBECONFIG_OUT}" || true
      su - ubuntu -c "kubectl config set-context argocd-context --cluster=argocd-cluster --user=argocd-manager --kubeconfig=$${KUBECONFIG_OUT}" || true
      su - ubuntu -c "kubectl config use-context argocd-context --kubeconfig=$${KUBECONFIG_OUT}" || true
      chown ubuntu:ubuntu $${KUBECONFIG_OUT} || true
      chmod 600 $${KUBECONFIG_OUT} || true

      # upload kubeconfigs to S3 (master role must have PutObject) with retries
      for i in 1 2 3 4; do
        aws s3 cp /home/ubuntu/.kube/config s3://${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/admin.conf --no-progress && break || sleep 5
      done
      for i in 1 2 3 4; do
        aws s3 cp /home/ubuntu/argocd-kubeconfig s3://${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/argocd-kubeconfig --no-progress && break || sleep 5
      done
    fi

    # save join command (for workers) if present and upload
    if [ -f /root/kubeadm-init.out ]; then
      grep "kubeadm join" -A 2 /root/kubeadm-init.out > /root/join_cmd.sh || true
      chmod +x /root/join_cmd.sh || true
      for i in 1 2 3; do
        aws s3 cp /root/join_cmd.sh s3://${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/join_cmd.sh --no-progress && break || sleep 5
      done
    fi

    # collect logs
    journalctl -u kubelet --no-pager -n 200 > /var/log/kubelet-start.log || true
    journalctl -u docker --no-pager -n 200 > /var/log/docker-start.log || true
  EOF

  tags = {
    Name = "argocd-server"
  }
}

resource "aws_instance" "k8s_master" {
  ami                   = data.aws_ami.ubuntu.id
  instance_type         = var.instance_type
  key_name              = var.aws_key_name
  subnet_id             = var.subnet_id
  vpc_security_group_ids = [aws_security_group.default.id]
  iam_instance_profile  = aws_iam_instance_profile.master_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    export DEBIAN_FRONTEND=noninteractive

    retry() { n=0; until [ $n -ge 5 ]; do "$@" && break; n=$((n+1)); sleep 5; done }

    apt-get update -y
    retry apt-get install -y docker.io curl apt-transport-https ca-certificates gnupg jq awscli || true
    systemctl enable --now docker || true

    # robust K8s apt install like master
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg -o /tmp/k8s-key.gpg || true
    if [ -s /tmp/k8s-key.gpg ]; then
      install -o root -g root -m 644 /tmp/k8s-key.gpg /usr/share/keyrings/kubernetes-archive-keyring.gpg || true
      echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
      apt-get update -y || true
      retry apt-get install -y kubelet kubeadm kubectl || true
      apt-mark hold kubelet kubeadm kubectl || true
    else
      echo "Failed to fetch K8s apt key; attempting kubectl only fallback" >&2
      KUBEV=$$(curl -fsSL https://dl.k8s.io/release/stable.txt || echo "")
      if [ -n "$${KUBEV}" ]; then
        curl -fsSL "https://dl.k8s.io/release/$${KUBEV}/bin/linux/amd64/kubectl" -o /tmp/kubectl || true
        install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl || true
      fi
    fi

    # Try to download join command from S3 (master must upload join_cmd.sh to same bucket/prefix)
    JOIN_FILE="/root/join_cmd.sh"
    for i in $(seq 1 30); do
      if aws s3 cp s3://${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/join_cmd.sh $${JOIN_FILE} --no-progress; then
        chmod +x $${JOIN_FILE}
        bash $${JOIN_FILE} && break
      fi
      echo "join_cmd.sh not available yet, retrying ($${i}/30)..."
      sleep 10
    done

    # If join failed, write log for debugging
    if ! grep -q "kubeadm join" $${JOIN_FILE} 2>/dev/null; then
      echo "WARN: join command not applied or missing. Check master uploaded join_cmd.sh to S3 and IAM permissions." > /var/log/k8s-worker-join.log
      journalctl -u kubelet --no-pager > /var/log/kubelet.log || true
    fi
  EOF

  tags = {
    Name = "k8s-master"
  }
}

resource "aws_instance" "k8s_worker" {
  ami                   = data.aws_ami.ubuntu.id
  instance_type         = var.instance_type
  key_name              = var.aws_key_name
  subnet_id             = var.subnet_id
  vpc_security_group_ids = [aws_security_group.default.id]
  iam_instance_profile  = aws_iam_instance_profile.argo_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get install -y docker.io curl
    systemctl enable --now docker

    mkdir -p /opt/prometheus

    cat > /opt/prometheus/prometheus.yml <<'PROMYAML'
    global:
      scrape_interval: 15s

    scrape_configs:
      - job_name: 'prometheus'
        static_configs:
          - targets: ['localhost:9090']

      - job_name: 'k8s-nodes'
        static_configs:
          - targets: ['${aws_eip.k8s_master_eip.public_ip}:9100','${aws_eip.k8s_worker_eip.public_ip}:9100']
    PROMYAML

    docker run -d --name prometheus --restart unless-stopped \
      -p 9090:9090 \
      -v /opt/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
      prom/prometheus:latest

    docker run -d --name grafana --restart unless-stopped \
      -p 3000:3000 \
      grafana/grafana:latest
  EOF

  tags = {
    Name = "k8s-worker"
  }
}

#prometheus + grafana
resource "aws_instance" "monitor" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.aws_key_name
  subnet_id     = var.subnet_id
  vpc_security_group_ids = [aws_security_group.default.id]

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get install -y docker.io curl
    systemctl enable --now docker

    # create prometheus config dir
    mkdir -p /opt/prometheus

    # write a minimal Prometheus config (scrapes prometheus itself + kube node exporters)
    cat > /opt/prometheus/prometheus.yml <<'PROMYAML'
    global:
      scrape_interval: 15s

    scrape_configs:
      - job_name: 'prometheus'
        static_configs:
          - targets: ['localhost:9090']

      - job_name: 'k8s-nodes'
        static_configs:
          - targets: ['${aws_eip.k8s_master_eip.public_ip}:9100','${aws_eip.k8s_worker_eip.public_ip}:9100']
    PROMYAML

    # run Prometheus container (mount config)
    docker run -d --name prometheus \
      -p 9090:9090 \
      -v /opt/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
      prom/prometheus:latest

    # run Grafana
    docker run -d --name grafana \
      -p 3000:3000 \
      grafana/grafana:latest

    # enable simple restart on reboot
    docker update --restart unless-stopped prometheus grafana || true
  EOF

  tags = {
    Name = "prom-grafana"
  }
}

resource "aws_eip" "argo_server_eip" {
  instance = aws_instance.argo_server.id
}

resource "aws_eip" "k8s_master_eip" {
  instance = aws_instance.k8s_master.id
}

resource "aws_eip" "k8s_worker_eip" {
  instance = aws_instance.k8s_worker.id
}

resource "aws_eip" "monitor_eip" {
  instance = aws_instance.monitor.id
}
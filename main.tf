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

    apt-get update -y
    apt-get install -y docker.io awscli jq
    systemctl enable --now docker

    KUBEDIR="/home/ubuntu/.kube"
    mkdir -p $${KUBEDIR}
    # fetch argocd serviceaccount kubeconfig from S3 (requires argo role with GetObject)
    aws s3 cp s3://${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/argocd-kubeconfig $${KUBEDIR}/config
    chown -R ubuntu:ubuntu $${KUBEDIR}
    chmod 600 $${KUBEDIR}/config || true
    export KUBECONFIG=$${KUBEDIR}/config

    # run ArgoCD components as containers (simple/dev setup)
    docker pull argoproj/argocd:v2.9.7

    docker run -d --name argocd-repo-server argoproj/argocd:v2.9.7 argocd-repo-server

    docker run -d --name argocd-application-controller \
      -v $${KUBEDIR}/config:/root/.kube/config:ro \
      argoproj/argocd:v2.9.7 argocd-application-controller

    docker run -d --name argocd-server \
      -p 8080:8080 -p 443:443 \
      -v $${KUBEDIR}/config:/root/.kube/config:ro \
      argoproj/argocd:v2.9.7 argocd-server

    # NOTE: initial admin password is stored inside a Kubernetes secret (admin in cluster),
    # for container-mode you may need to extract secret via kubectl using the admin kubeconfig.
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

    apt-get update -y
    apt-get install -y docker.io curl apt-transport-https ca-certificates gnupg jq awscli
    systemctl enable --now docker

    # kube packages
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -y
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl

    # kubeadm init (single control-plane)
    kubeadm init --pod-network-cidr=10.244.0.0/16 | tee /root/kubeadm-init.out

    # setup kubeconfig for ubuntu user
    mkdir -p /home/ubuntu/.kube
    cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
    chown -R ubuntu:ubuntu /home/ubuntu/.kube
    chmod 600 /home/ubuntu/.kube/config

    # install Flannel CNI (or choose your CNI)
    su - ubuntu -c "kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"

    # wait (best-effort)
    su - ubuntu -c "kubectl wait --for=condition=Ready nodes --all --timeout=300s" || true

    # create serviceaccount for ArgoCD and bind (example uses cluster-admin -> narrow in production)
    su - ubuntu -c "kubectl create serviceaccount argocd-manager -n kube-system || true"
    su - ubuntu -c "kubectl create clusterrolebinding argocd-manager-binding --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager || true"

    # build kubeconfig for the SA
    SA_SECRET=$$(su - ubuntu -c "kubectl -n kube-system get sa argocd-manager -o jsonpath='{.secrets[0].name}'")
    SA_TOKEN=$$(su - ubuntu -c "kubectl -n kube-system get secret $${SA_SECRET} -o jsonpath='{.data.token}' | base64 -d")
    APISERVER=$$(su - ubuntu -c "kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'")

    KUBECONFIG_OUT="/home/ubuntu/argocd-kubeconfig"
    su - ubuntu -c "kubectl config set-cluster argocd-cluster --server=$${APISERVER} --certificate-authority=/etc/kubernetes/pki/ca.crt --embed-certs=true --kubeconfig=$${KUBECONFIG_OUT}"
    su - ubuntu -c "kubectl config set-credentials argocd-manager --token='$${SA_TOKEN}' --kubeconfig=$${KUBECONFIG_OUT}"
    su - ubuntu -c "kubectl config set-context argocd-context --cluster=argocd-cluster --user=argocd-manager --kubeconfig=$${KUBECONFIG_OUT}"
    su - ubuntu -c "kubectl config use-context argocd-context --kubeconfig=$${KUBECONFIG_OUT}"
    chown ubuntu:ubuntu $${KUBECONFIG_OUT}
    chmod 600 $${KUBECONFIG_OUT}

    # upload kubeconfigs to S3 (master role must have PutObject)
    aws s3 cp /home/ubuntu/.kube/config s3://${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/admin.conf --acl private
    aws s3 cp /home/ubuntu/argocd-kubeconfig s3://${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/argocd-kubeconfig --acl private

    # save join command (for workers)
    grep "kubeadm join" -A 2 /root/kubeadm-init.out > /root/join_cmd.sh || true
    chmod +x /root/join_cmd.sh || true
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
    apt-get install -y docker.io curl apt-transport-https ca-certificates gnupg jq awscli
    systemctl enable --now docker

    # kube packages
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -y
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl

    # Try to download join command from S3 (master must upload join_cmd.sh to same bucket/prefix)
    JOIN_FILE="/root/join_cmd.sh"
    for i in $(seq 1 30); do
      if aws s3 cp s3://${var.kubeconfig_s3_bucket}/${var.kubeconfig_s3_key_prefix}/join_cmd.sh $${JOIN_FILE}; then
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
  tags = {
    Name = "prom-grafana"
  }
}
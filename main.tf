provider "aws" {
  region = var.aws_region
}

# Ubuntu AMI (Canonical)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_security_group" "default" {
  name        = "jenkind-cd-sg"
  description = "jenkins-cd-sg"
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

  # Jenkins agent inbound (JNLP)
  ingress {
    from_port   = 50000
    to_port     = 50000
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

# jenkins server(CD)
resource "aws_instance" "jenkins_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.aws_key_name
  subnet_id     = var.subnet_id
  vpc_security_group_ids = [aws_security_group.default.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-11-jdk curl gnupg2
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io.key | apt-key add -
    sh -c 'echo deb https://pkg.jenkins.io/debian-stable binary/ > /etc/apt/sources.list.d/jenkins.list'
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y jenkins
    systemctl enable --now jenkins
  EOF

  tags = {
    Name = "jenkins-server"
  }
}

# jenkins agent server
resource "aws_instance" "jenkins_agent" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.aws_key_name
  subnet_id     = var.subnet_id
  vpc_security_group_ids = [aws_security_group.default.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y docker.io curl
    systemctl enable --now docker
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
  EOF

  tags = {
    Name = "jenkins-agent"
  }
}

# prometheus server
resource "aws_instance" "prometheus" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.aws_key_name
  subnet_id     = var.subnet_id
  vpc_security_group_ids = [aws_security_group.default.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y docker.io
    systemctl enable --now docker
    # run Prometheus & Grafana containers (simple startup; replace with proper config)
    docker run -d --name prometheus -p 9090:9090 prom/prometheus
    docker run -d --name grafana -p 3000:3000 grafana/grafana
  EOF

  tags = {
    Name = "prometheus-server"
  }
}

# Elastic IPs for each server
resource "aws_eip" "jenkins_server_eip" {
  instance = aws_instance.jenkins_server.id
}

resource "aws_eip" "jenkins_agent_eip" {
  instance = aws_instance.jenkins_agent.id
}

resource "aws_eip" "prometheus_eip" {
  instance = aws_instance.prometheus.id
}
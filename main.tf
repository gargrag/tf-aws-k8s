terraform {
  required_providers {
    aws = {
      version = ">= 3.21.0"
      source  = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

resource "random_string" "token_id" {
  length  = 6
  special = false
  upper   = false
}

resource "random_string" "token_secret" {
  length  = 16
  special = false
  upper   = false
}

locals {
  tags  = merge(var.tags, { "terraform-kubeadm:cluster" = var.cluster_name })
  token = "${random_string.token_id.result}.${random_string.token_secret.result}"
  kubeconfig_file = var.kubeconfig_file != null ? abspath(pathexpand(var.kubeconfig_file)) : "${abspath(pathexpand(var.kubeconfig_dir))}/${var.cluster_name}.conf"

}

resource "aws_key_pair" "generated_key" {
  key_name_prefix = "${var.cluster_name}-"
  public_key      = file(var.public_key_file)
}

resource "aws_instance" "master" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3a.small"
  key_name      = aws_key_pair.generated_key.key_name

  vpc_security_group_ids = [
    aws_security_group.egress.id,
    aws_security_group.ingress_internal.id,
    aws_security_group.ingress_k8s.id,
    aws_security_group.ingress_ssh.id
  ]
  tags = merge(local.tags, { "Name" = "master" })

  user_data = <<-EOF
  #!/bin/bash
  # Install kubeadm and Docker
  apt-get update
  apt-get install -y apt-transport-https curl
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
  echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list
  apt-get update
  apt-get install -y docker.io kubeadm
  # Run kubeadm
  kubeadm init \
    --token "${local.token}" \
    --token-ttl 15m \
    --apiserver-cert-extra-sans "${aws_eip.master.public_ip}" \
  %{if var.pod_network_cidr_block != null~}
    --pod-network-cidr "${var.pod_network_cidr_block}" \
  %{endif~}
    --node-name master
  # Prepare kubeconfig file for download to local machine
  cp /etc/kubernetes/admin.conf /home/ubuntu
  sudo chown -R ubuntu:ubuntu /home/ubuntu/admin.conf
  # Install CNI plugin
  kubectl --kubeconfig /home/ubuntu/admin.conf apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
  kubectl --kubeconfig /home/ubuntu/admin.conf config set-cluster kubernetes --server https://${aws_eip.master.public_ip}:6443
  # Indicate completion of bootstrapping on this node
  touch /home/ubuntu/done
  EOF
}

resource "aws_instance" "nodes" {
  count         = length(var.nodes)
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.generated_key.key_name

  vpc_security_group_ids = [
    aws_security_group.egress.id,
    aws_security_group.ingress_internal.id,
    aws_security_group.ingress_k8s.id,
    aws_security_group.ingress_ssh.id
  ]
  tags      = merge(local.tags, { "Name" = var.nodes[count.index] })
  user_data = <<-EOF
  #!/bin/bash
  # Install kubeadm and Docker
  apt-get update
  apt-get install -y apt-transport-https curl
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
  echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list
  apt-get update
  apt-get install -y docker.io kubeadm
  # Run kubeadm
  kubeadm join ${aws_instance.master.private_ip}:6443 \
    --token ${local.token} \
    --discovery-token-unsafe-skip-ca-verification \
    --node-name ${var.nodes[count.index]}
  # Indicate completion of bootstrapping on this node
  touch /home/ubuntu/done
  EOF
}

resource "null_resource" "wait_for_bootstrap_to_finish" {
  provisioner "local-exec" {
    command = <<-EOF
    alias ssh='ssh -q -i ${var.private_key_file} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
    while true; do
      sleep 2
      ! ssh ubuntu@${aws_eip.master.public_ip} [[ -f /home/ubuntu/done ]] >/dev/null && continue
      %{for worker_public_ip in aws_instance.nodes[*].public_ip~}
      ! ssh ubuntu@${worker_public_ip} [[ -f /home/ubuntu/done ]] >/dev/null && continue
      %{endfor~}
      break
    done
    EOF
  }
  triggers = {
    instance_ids = join(",", concat([aws_instance.master.id], aws_instance.nodes[*].id))
  }
}

resource "null_resource" "download_kubeconfig_file" {
  provisioner "local-exec" {
    command = <<-EOF
    alias scp='scp -q -i ${var.private_key_file} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
    scp ubuntu@${aws_eip.master.public_ip}:/home/ubuntu/admin.conf ${local.kubeconfig_file} >/dev/null
    EOF
  }
  triggers = {
    wait_for_bootstrap_to_finish = null_resource.wait_for_bootstrap_to_finish.id
  }
}
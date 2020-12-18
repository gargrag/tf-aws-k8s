data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}


variable "private_key_file" {
  type        = string
}

variable "public_key_file" {
  type        = string
}


variable "kubeconfig_dir" {
  type        = string
  default     = "."
}

variable "kubeconfig_file" {
  type        = string
  default     = null
}

variable "cluster_name" {
  type    = string
}

variable "tags" {
  type    = map(any)
  default = {}
}

variable "pod_network_cidr_block" {
  type    = string
  default = null
}

variable "allowed_ssh_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "allowed_k8s_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "vpc_id" {
  type    = string
  default = null
}

variable "nodes" {
  type = list(any)
  default = [
    "node0",
    "node1"
  ]
}
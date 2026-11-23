variable "region" {
  description = "AWS region for every resource."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix and Project tag."
  type        = string
  default     = "iac-class"
}

variable "instance_type" {
  description = "EC2 instance type. k3s + Docker build need ~4 GB of RAM."
  type        = string
  default     = "t3.medium"
}

variable "my_ip_cidr" {
  description = "Your public IP as a /32, e.g. 203.0.113.10/32. Only this IP can SSH and reach the Kubernetes API."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key to install on the instance."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

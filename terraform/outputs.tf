output "public_ip" {
  description = "Elastic IP of the instance."
  value       = module.compute.public_ip
}

output "public_dns" {
  description = "Public DNS name of the instance (CloudFront origin)."
  value       = module.compute.public_dns
}

output "instance_id" {
  value = module.compute.instance_id
}

output "cloudfront_url" {
  description = "Public HTTPS URL of the API."
  value       = "https://${module.cdn.domain_name}"
}

output "ssh_command" {
  value = "ssh ec2-user@${module.compute.public_ip}"
}

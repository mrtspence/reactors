output "reactor_ecr_repository_url" {
  description = "The URL of the reactor ECR repository"
  value       = aws_ecr_repository.reactor.repository_url
}

output "aws_route53_subdomain_name_servers" {
  description = "Name servers for the aws route 53 subdomain"
  value = [for name_server in aws_route53_zone.play.name_servers : name_server]
}

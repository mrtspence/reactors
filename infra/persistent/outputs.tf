output "reactor_ecr_repository_url" {
  description = "The URL of the reactor ECR repository"
  value       = aws_ecr_repository.reactor.repository_url
}

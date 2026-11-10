resource "aws_ecr_repository" "reactor" {
  name                 = "reactor"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  force_delete = false
}

output "reactor_ecr_repository_url" {
  description = "The URL of the reactor ECR repository"
  value       = aws_ecr_repository.reactor.repository_url
}

resource "aws_ecr_lifecycle_policy" "reactor" {
  repository = aws_ecr_repository.reactor.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["git-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

locals {
  budget_alerts = [
    { threshold = 25, notification_type = "ACTUAL", threshold_type = "PERCENTAGE" },
    { threshold = 50, notification_type = "ACTUAL", threshold_type = "PERCENTAGE" },
    { threshold = 75, notification_type = "ACTUAL", threshold_type = "PERCENTAGE" },
    { threshold = 100, notification_type = "FORECASTED", threshold_type = "PERCENTAGE" }
  ]
}

resource "aws_budgets_budget" "reactor_monthly" {
  account_id        = data.aws_caller_identity.current.account_id
  budget_type       = "COST"
  limit_amount      = "20.0"
  limit_unit        = "USD"
  name              = "reactor-monthly"
  time_period_start = "2026-11-01_00:00"
  time_unit         = "MONTHLY"

  dynamic "notification" {
    for_each = local.budget_alerts
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.notification_type
      subscriber_email_addresses = var.budget_notification_emails
      threshold                  = notification.value.threshold
      threshold_type             = notification.value.threshold_type
    }
  }
}

moved {
  from = aws_budgets_budget.reactor-monthly
  to = aws_budgets_budget.reactor_monthly
}

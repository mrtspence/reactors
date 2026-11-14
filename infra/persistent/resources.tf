resource "aws_ecr_repository" "reactor" {
  name                 = "reactor"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  force_delete = false
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


### CLOUDFLARE - RELATED RESOURCES - TODO: SPLIT OUT
data "cloudflare_zone" "root" {
  filter = {
    name = "reactor-game.dev"
  }
}

resource "aws_route53_zone" "play" {
  name = "play.reactor-game.dev"
  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "play_ns" {
  count = 4 # route53 always makes 4 name servers, so we can use this to get output at plantime

  zone_id = data.cloudflare_zone.root.zone_id
  name    = "play"
  type    = "NS"
  content = aws_route53_zone.play.name_servers[count.index]
  ttl     = 300
  proxied = false
}

resource "cloudflare_dns_record" "root_dummy" {
  zone_id = data.cloudflare_zone.root.zone_id
  name    = "@"
  type    = "A"
  content = "192.0.2.1"
  ttl     = 1
  proxied = true
}

resource "cloudflare_ruleset" "root_to_play_redirect" {
  zone_id     = data.cloudflare_zone.root.zone_id
  name        = "Redirect root to play subdomain"
  description = "redirect from reactor-game.dev to play.reactor-game.dev"
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules = [
    {
      ref         = "redirect_apex_to_play"
      description = "Redirect reactor-game.dev to https://play.reactor-game.dev"
      expression  = "(http.host eq \"reactor-game.dev\")"
      action      = "redirect"
      enabled     = true

      action_parameters = {
        from_value = {
          status_code = 301
          target_url = {
            expression = "concat(\"https://play.reactor-game.dev\", http.request.uri.path)"
          }
          preserve_query_string = true
        }
      }
    }
  ]
}

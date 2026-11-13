locals {
  acl_list = concat(
    [
      for topic in var.produce_topics : {
        resource_name = topic
        resource_type = "TOPIC",
        operation     = "WRITE"
      }
    ],
    [
      for topic in var.consume_topics : {
        resource_name = topic
        resource_type = "TOPIC",
        operation     = "READ"
      }
    ],
    [
      for topic in var.consumer_groups : {
        resource_name = topic
        resource_type = "GROUP",
        operation     = "READ"
      }
    ]
  )

  acl_map = {
    for acl in local.acl_list :
    "${acl.resource_type}:${acl.operation}:${acl.resource_name}" => acl
  }
}


resource "confluent_service_account" "this" {
  display_name = "reactor_${var.environment_name}_${var.name}"
  description  = var.description
}

resource "confluent_api_key" "this" {
  display_name = "reactor_${var.environment_name}_${var.name}_api_key"
  description  = "api key for ${var.environment_name}_${var.name}"

  owner {
    id          = confluent_service_account.this.id
    api_version = confluent_service_account.this.api_version
    kind        = confluent_service_account.this.kind
  }

  managed_resource {
    id          = var.cluster.id
    api_version = var.cluster.api_version
    kind        = var.cluster.kind

    environment {
      id = var.cluster.environment[0].id
    }
  }
}

resource "confluent_kafka_acl" "this" {
  for_each = local.acl_map

  kafka_cluster {
    id = var.cluster.id
  }

  resource_type = each.value.resource_type
  resource_name = each.value.resource_name
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.this.id}"
  host          = "*"
  operation     = each.value.operation
  permission    = "ALLOW"
  rest_endpoint = var.cluster.rest_endpoint

  credentials {
    key    = var.admin_credentials.key
    secret = var.admin_credentials.secret
  }
}

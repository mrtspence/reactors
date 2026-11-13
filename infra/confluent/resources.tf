resource "confluent_environment" "reactor" {
  display_name = "production"
  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_kafka_cluster" "reactor" {
  display_name = "reactor_cluster"
  availability = "SINGLE_ZONE"
  cloud        = "AWS"
  region       = "us-east-2"
  basic {}

  lifecycle {
    prevent_destroy = true
  }

  environment {
    id = confluent_environment.reactor.id
  }
}

resource "confluent_service_account" "reactor_cluster_manager" {
  display_name = "reactor_${confluent_environment.reactor.display_name}_cluster_manager"
  description  = "Service Account for the reactor cluster"
}

resource "confluent_role_binding" "reactor_cluster_manager" {
  principal   = "User:${confluent_service_account.reactor_cluster_manager.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.reactor.rbac_crn
}

resource "confluent_api_key" "reactor_cluster_manager" {
  display_name = "${confluent_service_account.reactor_cluster_manager.display_name}_api_key"
  description  = "Kafka API Key owned by the reactor cluster manager account"
  owner {
    id          = confluent_service_account.reactor_cluster_manager.id
    api_version = confluent_service_account.reactor_cluster_manager.api_version
    kind        = confluent_service_account.reactor_cluster_manager.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.reactor.id
    api_version = confluent_kafka_cluster.reactor.api_version
    kind        = confluent_kafka_cluster.reactor.kind

    environment {
      id = confluent_environment.reactor.id
    }
  }

  depends_on = [confluent_role_binding.reactor_cluster_manager]

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_kafka_topic" "commands" {
  kafka_cluster {
    id = confluent_kafka_cluster.reactor.id
  }
  topic_name       = "match.commands"
  rest_endpoint    = confluent_kafka_cluster.reactor.rest_endpoint
  partitions_count = 6
  config = {
    "retention.ms" = "604800000"
  }
  credentials {
    key    = confluent_api_key.reactor_cluster_manager.id
    secret = confluent_api_key.reactor_cluster_manager.secret
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_kafka_topic" "events" {
  kafka_cluster {
    id = confluent_kafka_cluster.reactor.id
  }
  topic_name       = "match.events"
  rest_endpoint    = confluent_kafka_cluster.reactor.rest_endpoint
  partitions_count = 6
  config = {
    "retention.ms" = "604800000"
  }
  credentials {
    key    = confluent_api_key.reactor_cluster_manager.id
    secret = confluent_api_key.reactor_cluster_manager.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

# TODO: first writer is runner snapshotting (docs/architecture.md §6)
resource "confluent_kafka_topic" "snapshots" {
  kafka_cluster {
    id = confluent_kafka_cluster.reactor.id
  }
  topic_name       = "match.snapshots"
  rest_endpoint    = confluent_kafka_cluster.reactor.rest_endpoint
  partitions_count = 6
  config = {
    "cleanup.policy" = "compact"
  }
  credentials {
    key    = confluent_api_key.reactor_cluster_manager.id
    secret = confluent_api_key.reactor_cluster_manager.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

# TODO: first writer is likely matchmaker (docs/architecture.md §6)
resource "confluent_kafka_topic" "lifecycle" {
  kafka_cluster {
    id = confluent_kafka_cluster.reactor.id
  }
  topic_name       = "match.lifecycle"
  rest_endpoint    = confluent_kafka_cluster.reactor.rest_endpoint
  partitions_count = 6
  config = {
    "retention.ms" = "604800000"
  }
  credentials {
    key    = confluent_api_key.reactor_cluster_manager.id
    secret = confluent_api_key.reactor_cluster_manager.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  kafka_principals = {
    web = {
      description    = "web tier"
      produce_topics = ["match.commands"]
    },
    match_runner = {
      description     = "match runner tier"
      produce_topics  = ["match.events"]
      consume_topics  = ["match.commands"]
      consumer_groups = ["match-runners"]
    },
    events = {
      description     = "events tier"
      consume_topics  = ["match.events"]
      consumer_groups = ["progression", "incidents"]
    }
  }
}

module "principals" {
  source   = "./modules/kafka_principal"
  for_each = local.kafka_principals

  environment_name = confluent_environment.reactor.display_name
  name             = each.key
  description      = each.value.description
  produce_topics   = lookup(each.value, "produce_topics", [])
  consume_topics   = lookup(each.value, "consume_topics", [])
  consumer_groups  = lookup(each.value, "consumer_groups", [])

  cluster = confluent_kafka_cluster.reactor

  admin_credentials = {
    key    = confluent_api_key.reactor_cluster_manager.id
    secret = confluent_api_key.reactor_cluster_manager.secret
  }
}

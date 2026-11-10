resource "confluent_environment" "reactor_production" {
  display_name = "production"
  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_kakfa_cluster" "reactor" {
  display_name = "reactor"
  availability = "SINGLE_ZONE"
  cloud        = "AWS"
  region       = "us-east-2"
  basic {}
  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_service_account" "reactor_cluster_manager" {
  display_name = "kafka_cluster_manager"
  description  = "Service Account for the reactor cluster"
}

resource "confluent_role_binding" "reactor_cluster_manager" {
  principal   = "User:${confluent_service_account.reactor_cluster_manager.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.reactor.rbac_crn
}

resource "confluent_api_key" "reactor_cluster_manager" {
  display_name = "reactor_cluster_manager_api_key"
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
      id = confluent_environment.reactor_production.id
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_kafka_topic" "commands" {
  kafka_cluster {
    id = confluent_kafka_cluster.reactor.id
  }
  topic_name    = "match.commands"
  rest_endpoint = confluent_kafka_cluster.reactor.rest_endpoint
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
  topic_name    = "match.events"
  rest_endpoint = confluent_kafka_cluster.reactor.rest_endpoint
  credentials {
    key    = confluent_api_key.reactor_cluster_manager.id
    secret = confluent_api_key.reactor_cluster_manager.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

# TODO: Not yet in use
resource "confluent_kafka_topic" "snapshots" {
  kafka_cluster {
    id = confluent_kafka_cluster.reactor.id
  }
  topic_name    = "match.snapshots"
  rest_endpoint = confluent_kafka_cluster.reactor.rest_endpoint
  credentials {
    key    = confluent_api_key.reactor_cluster_manager.id
    secret = confluent_api_key.reactor_cluster_manager.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

# TODO: Not yet in use
resource "confluent_kafka_topic" "lifecycle" {
  kafka_cluster {
    id = confluent_kafka_cluster.reactor.id
  }
  topic_name    = "match.lifecycle"
  rest_endpoint = confluent_kafka_cluster.reactor.rest_endpoint
  credentials {
    key    = confluent_api_key.reactor_cluster_manager.id
    secret = confluent_api_key.reactor_cluster_manager.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_service_account" "web" {
  display_name = "web_service_account"
  description  = "Service Account for the web tier"
}

resource "confluent_api_key" "web" {
  display_name = "web_api_key"
  description  = "API Key owned by web tier service account"
  owner {
    id          = confluent_service_account.web.id
    api_version = confluent_service_account.web.api_version
    kind        = confluent_service_account.web.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.reactor.id
    api_version = confluent_kafka_cluster.reactor.api_version
    kind        = confluent_kafka_cluster.reactor.kind

    environment {
      id = confluent_environment.reactor_production.id
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_service_account" "match_runner" {
  display_name = "match_runner_service_account"
  description  = "Service Account for the match runner tier"
}

resource "confluent_api_key" "match_runner" {
  display_name = "match_runner_api_key"
  description  = "API Key owned by match runner service account"
  owner {
    id          = confluent_service_account.match_runner.id
    api_version = confluent_service_account.match_runner.api_version
    kind        = confluent_service_account.match_runner.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.reactor.id
    api_version = confluent_kafka_cluster.reactor.api_version
    kind        = confluent_kafka_cluster.reactor.kind

    environment {
      id = confluent_environment.reactor_production.id
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_service_account" "events" {
  display_name = "events_service_account"
  description  = "Service Account for the events tier"
}

resource "confluent_api_key" "events" {
  display_name = "events_api_key"
  description  = "API Key owned by events service account"
  owner {
    id          = confluent_service_account.events.id
    api_version = confluent_service_account.events.api_version
    kind        = confluent_service_account.events.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.reactor.id
    api_version = confluent_kafka_cluster.reactor.api_version
    kind        = confluent_kafka_cluster.reactor.kind

    environment {
      id = confluent_environment.reactor_production.id
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

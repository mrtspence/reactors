output "confluent_principal_api_keys" {
  value     = { for k, mod in module.principals : k => mod.api_key }
  sensitive = true
}

output "confluent_kafka_cluster_bootstrap_endpoint" {
  description = "Bootstrap endpoint for the kafka cluster"
  value = confluent_kafka_cluster.reactor.bootstrap_endpoint
}

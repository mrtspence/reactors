output "confluent_principal_api_keys" {
  value     = { for k, mod in module.principals : k => mod.api_key }
  sensitive = true
}

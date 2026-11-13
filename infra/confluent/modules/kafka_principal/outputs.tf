output "api_key" {
  description = "The service account API key for the kafka principal"
  value = {
    key    = confluent_api_key.this.id
    secret = confluent_api_key.this.secret
  }
  sensitive = true
}

variable "environment_name" {
  type        = string
  description = "deployment environment name"
}

variable "name" {
  type        = string
  description = "unique identifier for principal"
}

variable "description" {
  type        = string
  description = "human-readable description of the principal"
}

variable "cluster" {
  type = object({
    id            = string
    api_version   = string
    kind          = string
    environment   = list(object({ id = string }))
    rest_endpoint = string
  })
}

variable "produce_topics" {
  type        = list(string)
  default     = []
  description = "list of topic names this principal is allowed to write to."
}

variable "consume_topics" {
  type        = list(string)
  default     = []
  description = "list of topic names this principal is allowed to read from."
}

variable "consumer_groups" {
  type        = list(string)
  default     = []
  description = "List of consumer group IDs this principal can join."
}

variable "admin_credentials" {
  type = object({
    key    = string
    secret = string
  })
}

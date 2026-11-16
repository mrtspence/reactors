variable "restore_rds_snapshot" {
  description = "Whether to build the rds instance from a restore snapshot"
  type        = bool
  default     = true
}

variable "admin_cidrs" {
  description = "The ip address allowed to access the eks cluster and ALB"
  type        = list(string)
  validation {
    condition     = !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "Must pass a specific address. Get using curl -s https://checkip.amazonaws.com (then add /32)"
  }
}

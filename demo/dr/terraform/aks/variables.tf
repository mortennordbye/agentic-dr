variable "subscription_id" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "node_count" {
  type    = number
  default = 3
}

# The source root pins a cluster-admin principal id in code. Its DR equivalent is not derivable
# from anything in the source, so it is deferred to the Orchestrator rather than invented.
# Left null, the role assignment is simply not created.
variable "cluster_admin_principal_id" {
  type    = string
  default = null
}

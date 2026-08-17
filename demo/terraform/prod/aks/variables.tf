variable "subscription_id" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "node_count" {
  type    = number
  default = 3
}

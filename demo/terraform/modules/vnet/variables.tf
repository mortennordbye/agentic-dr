variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "address_space" { type = list(string) }
variable "subnets" {
  type = map(object({ prefixes = list(string) }))
}
variable "tags" {
  type    = map(string)
  default = {}
}

# The trap described in the profile's identity.md: this defaults to the SOURCE pipeline identity.
# A DR root that omits the variable silently binds a source identity, and a token grep cannot see it
# because the value lives here, not in the root. Hence the lint's presence check.
variable "network_contributor_principal_id" {
  type        = string
  default     = "00000000-0000-0000-0000-0000000000a1"
  description = "Principal granted Network Contributor on the VNet."
}

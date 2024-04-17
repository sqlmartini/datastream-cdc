variable "project_id" {
  type        = string
  description = "project id required"
}
variable "project_number" {
 type        = string
 description = "project number"
}
variable "gcp_account_name" {
 type        = string    
 description = "lab user's FQN"
}
variable "gcp_region" {
 type        = string    
 description = "The GCP region you want to use"
}
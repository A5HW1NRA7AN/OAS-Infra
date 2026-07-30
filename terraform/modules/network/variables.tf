variable "name_prefix" {
  description = "Prefix for resource names/tags (e.g. oas-uat)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the OAS VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across (2 for future HA; instances live in azs[0] for now)."
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per AZ."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "app_subnet_cidrs" {
  description = "App (k8s) subnet CIDRs, one per AZ."
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "data_subnet_cidrs" {
  description = "Data (DB host) subnet CIDRs, one per AZ."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

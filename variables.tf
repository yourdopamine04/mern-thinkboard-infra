variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "project_id" {
  type    = string
  default = "gcp-devops-lab-514504"
}

variable "github_repository" {
  type        = string
  description = "GitHub repository in owner/repository format"
  default     = "yourdopamine04/mern-thinkboard"
}

variable "artifact_repository_id" {
  type    = string
  default = "mern-thinkboard"
}


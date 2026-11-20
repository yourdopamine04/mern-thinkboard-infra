resource "google_artifact_registry_repository" "repo_thinkboard" {
  location      = var.region
  repository_id = var.artifact_repository_id
  description   = "Docker images for mern-thinkboard"
  format        = "DOCKER"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent-images"
    action = "KEEP"
    condition {
      tag_state             = "TAGGED"
      package_name_prefixes = ["backend", "frontend"]
    }
  }

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "300s"
    }
  }
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "attribute.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_actions" {
  account_id   = "github-actions"
  display_name = "GitHub Actions deployer"
}

resource "google_project_iam_member" "github_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_project_iam_member" "github_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_project_iam_member" "github_service_account_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_service_account_iam_member" "github_workload_identity" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

resource "google_secret_manager_secret" "mongo_uri" {
  secret_id = "MONGO_URI"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "redis_token" {
  secret_id = "UPSTASH_REDIS_REST_TOKEN"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "redis_url" {
  secret_id = "UPSTASH_REDIS_REST_URL"

  replication {
    auto {}
  }
}

resource "google_cloud_run_v2_service" "backend" {
  name     = "thinkboard-backend"
  location = var.region
  deletion_protection = false
  template {
    scaling {
      # max instance 2 agar tidak bisa di spam bot dan membengkak cost
      max_instance_count = 2
    }
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"
      # menyuntikan environment variable dari secret manager 
      env {
        name = "MONGO_URI"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.mongo_uri.secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "UPSTASH_REDIS_REST_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.redis_token.secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "UPSTASH_REDIS_REST_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.redis_url.secret_id
            version = "latest"
          }
        }
      }
    }
  }
  depends_on = [
    google_secret_manager_secret_iam_member.secret_accessor_mongo,
    google_secret_manager_secret_iam_member.secret_accessor_redis,
    google_secret_manager_secret_iam_member.secret_accessor_redis_url,
  ]
  #  untuk mencegah terraform menimpa image baru dari cicd
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
    ]
  }
}

# Mengambil informasi Project ID dari metadata
data "google_project" "project" {}

# Memberikan izin cloudrun akses ke service account untuk mengakses secret Mongo URI
resource "google_secret_manager_secret_iam_member" "secret_accessor_mongo" {
  secret_id = google_secret_manager_secret.mongo_uri.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}
# Memberikan izin cloudrun akses ke service account untuk mengakses secret Redis Token
resource "google_secret_manager_secret_iam_member" "secret_accessor_redis" {
  secret_id = google_secret_manager_secret.redis_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

resource "google_secret_manager_secret_iam_member" "secret_accessor_redis_url" {
  secret_id = google_secret_manager_secret.redis_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# agar cloudrun backend bisa diakses di public atau untuk Frontend, kita perlu menambahkan resource ini agar bisa diakses publik
resource "google_cloud_run_v2_service_iam_member" "backend_public" {
  name     = google_cloud_run_v2_service.backend.name
  location = google_cloud_run_v2_service.backend.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service" "frontend" {
  name     = "thinkboard-frontend"
  location = var.region
  deletion_protection = false
  template {
    scaling {
      # max instance 2 agar tidak bisa di spam bot dan membengkak cost
      max_instance_count = 2
    }
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"
      ports {
        container_port = 80
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
    ]
  }
}

# agar cloudrun frontend bisa diakses di public 
resource "google_cloud_run_v2_service_iam_member" "frontend_public" {
  name     = google_cloud_run_v2_service.frontend.name
  location = google_cloud_run_v2_service.frontend.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
}

output "github_actions_service_account" {
  value = google_service_account.github_actions.email
}


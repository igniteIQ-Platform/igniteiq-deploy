# igniteiq-deploy — customer-run Terraform that provisions an IgniteIQ Depot
# ingestion stack inside the customer's own GCP project. The customer runs this
# as themselves (Owner/Editor); IgniteIQ never receives their credentials and
# holds only the write-only + data-plane grants this module creates. See the
# design: igniteiq-docs/docs/engineering/self-serve-onboarding.md.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.40, < 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.40, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {
  project_id = var.project_id
}

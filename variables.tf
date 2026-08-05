# ── Customer inputs (the wizard fills terraform.tfvars) ──────────────────────

variable "project_id" {
  type        = string
  description = "The customer's GCP project ID — where the entire Depot stack is provisioned."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "GCP region for all regional resources."
}

variable "slug" {
  type        = string
  description = "Short lowercase tenant identifier (matches the Studio subdomain). Used to name secrets and resources."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}$", var.slug))
    error_message = "slug must be lowercase alphanumeric/hyphen, starting with a letter."
  }
}

variable "servicetitan_tenant_id" {
  type        = string
  description = "The customer's ServiceTitan tenant ID (numeric)."
}

variable "igniteiq_org_id" {
  type        = string
  description = "The IgniteIQ organization ID this deployment belongs to (used by the completion callbacks)."
}

variable "provisioning_token" {
  type        = string
  sensitive   = true
  description = "Short-lived, single-use, org-scoped token minted by the Studio wizard. The only credential in tfvars; authorizes the two completion callbacks and grants nothing else."
}

# ── IgniteIQ endpoints + identities (wizard supplies; sane defaults) ─────────

variable "callback_base_url" {
  type        = string
  default     = "https://api.igniteiq.com"
  description = "IgniteIQ Platform base URL for the connector-push and infra-ready callbacks."
}

variable "igniteiq_platform_sa" {
  type        = string
  default     = "1020933832935-compute@developer.gserviceaccount.com"
  description = "IgniteIQ Platform runtime SA. Granted WRITE-ONLY secret access (secretVersionAdder) so Studio can vault ServiceTitan credentials into this project. Cannot read secrets back."
}

variable "igniteiq_forge_sa" {
  type        = string
  default     = "forge-runner@igniteiq-core.iam.gserviceaccount.com"
  description = "IgniteIQ Forge (transform) SA. Granted BigQuery transform access on this project."
}

variable "igniteiq_vault_sa" {
  type        = string
  default     = "vault-sa@igniteiq-dev.iam.gserviceaccount.com"
  description = "IgniteIQ Vault (query engine) SA. Granted read-only BigQuery access to the ontology dataset."
}

variable "igniteiq_publisher_sa" {
  type        = string
  default     = "connector-publisher@igniteiq-dev.iam.gserviceaccount.com"
  description = "IgniteIQ SA that pushes the pinned Depot connector image into this project's depot-connectors repository (write-only on that repo). See the connector-push callback."
}

# ── Depot ingestion runtime artifacts (IgniteIQ-published, in-project) ───────
# Both the connector image AND the ingestion Helm chart are OCI artifacts that
# IgniteIQ publishes into THIS project's depot-connectors repository (via the
# connector-push callback). The cluster pulls both from in-project — no public
# Helm repo, no cross-project pull. Nothing vendor-named appears anywhere here.

variable "depot_chart_name" {
  type        = string
  default     = "depot-ingest"
  description = "Depot ingestion chart artifact name inside this project's depot-connectors repository (OCI Helm chart, published by IgniteIQ alongside the connector image)."
}

variable "depot_chart_version" {
  type        = string
  default     = "1.8.5"
  description = "Pinned Depot ingestion chart version."
}

variable "connector_image_name" {
  type        = string
  default     = "servicetitan"
  description = "Connector image name inside this project's depot-connectors repository (pushed by IgniteIQ via the connector-push callback)."
}

variable "connector_image_tag" {
  type        = string
  description = "Pinned connector image tag (e.g. v0.5.0). The wizard supplies the current release; see igniteiq-depot manifest.json."
}

variable "workload_k8s_sa" {
  type        = string
  default     = "airbyte-admin"
  description = "Cluster-internal Kubernetes service account the ingestion launcher gives connector pods (upstream JOB_KUBE_SERVICEACCOUNT — not chart-overridable, kubectl-only, never customer-facing). The module pre-creates this SA and binds Workload Identity to it; the name must match the runtime exactly."
}

# ── Sizing (sensible defaults; overridable) ──────────────────────────────────

variable "sql_tier" {
  type        = string
  default     = "db-custom-1-3840"
  description = "Cloud SQL machine tier for the Depot config database."
}

variable "igniteiq_auditor_sa" {
  type        = string
  default     = "tenant-auditor@igniteiq-dev.iam.gserviceaccount.com"
  description = "IgniteIQ read-only posture auditor. Granted a project-level custom role that can read IAM bindings, org-policy settings and secret NAMES — and cannot read this project's data, cannot read secret payloads, and cannot modify anything (ENG-433). Deliberately a separate identity from every other grant here so that claim stays true."
}

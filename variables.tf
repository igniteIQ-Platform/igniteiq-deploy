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

# VESTIGIAL — declared for compatibility, consumed by nothing in this module.
#
# 🔴 It is NOT known at apply time and must not be presented as a required input.
# The ServiceTitan tenant id is a required ServiceTitan *credential*, so it only
# becomes known when the customer connects ServiceTitan in Studio — which happens
# AFTER this deploy completes. The platform captures it at that point onto the
# org's default division, and that division row is what the query engine's tenant
# registry and the transform layer's `servicetitan_tenant_id` var actually read.
#
# Leaving this variable required meant a greenfield deploy appeared blocked on an
# input that cannot exist yet. Defaulted to empty so it never gates an apply;
# grep shows no other reference in this module, so a real value changes nothing.
# Safe to delete outright once no caller passes it.
variable "servicetitan_tenant_id" {
  type        = string
  default     = ""
  description = "Deprecated/unused. The ServiceTitan tenant id is captured when the customer connects ServiceTitan in Studio, after this deploy. Do not treat as a prerequisite."
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
  type = string
  # The wizard supplies the real value per tenant; this default is the public entry point
  # a customer would use. Paired with ONBOARDING_CALLBACK_BASE in igniteiq-platform,
  # which IS tracked there as a real tier-scoped violation.
  default     = "https://api.igniteiq.com" # bare-host-ok: customer-facing public endpoint
  description = "IgniteIQ Platform base URL for the connector-push and infra-ready callbacks."
}

variable "igniteiq_platform_sa" {
  type        = string
  default     = "1020933832935-compute@developer.gserviceaccount.com"
  description = "IgniteIQ Platform runtime SA. Granted WRITE-ONLY secret access (secretVersionAdder) so Studio can vault ServiceTitan credentials into this project. Cannot read secrets back."
}

# ⚠️ SETS, not strings. There is one Forge and one Vault per ENVIRONMENT, and
# each is a distinct service account. Typed as a single string the declaration
# can only ever name one of them, so every additional environment has to be
# granted by hand outside this module — which puts a privileged command in the
# hands of whoever owns the project instead of in the apply. The environment
# set belongs in the declaration: adding one is then a value change this module
# carries on its own.
variable "igniteiq_forge_sas" {
  type = set(string)
  default = [
    "forge-runner@igniteiq-core.iam.gserviceaccount.com",
    "forge-runner@igniteiq-prod.iam.gserviceaccount.com",
  ]
  description = "IgniteIQ Forge (transform) SAs, one per environment. Granted BigQuery transform access on this project."
}

variable "igniteiq_vault_sas" {
  type = set(string)
  default = [
    "vault-sa@igniteiq-dev.iam.gserviceaccount.com",
    "vault-sa@igniteiq-qa.iam.gserviceaccount.com",
    "vault-sa@igniteiq-prod.iam.gserviceaccount.com",
  ]
  description = "IgniteIQ Vault (query engine) SAs, one per environment. Granted read-only BigQuery access to the ontology dataset."
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

# ── Which ingestion runtimes this project runs ───────────────────────────────────
# The three supported shapes:
#   v1 only   depot_v1_enabled = true,  depot_v2_enabled = false   (the default; every tenant today)
#   both      depot_v1_enabled = true,  depot_v2_enabled = true    (v2 beside the running Depot)
#   v2 only   depot_v1_enabled = false, depot_v2_enabled = true    (a new tenant with no v1)
# At least one must be on (gke.tf).
variable "depot_v1_enabled" {
  type        = bool
  default     = true
  description = "Install the first-generation ingestion runtime. Set false only on a NEW project that runs Depot v2 alone. ⚠️ Turning it off where v1 is installed is not a supported teardown: it removes v1's database and identity binding from Terraform but leaves the runtime in the cluster."
}

# ── Depot v2, ENG-1021 — off by default ──────────────────────────────────────────
variable "depot_v2_enabled" {
  type        = bool
  default     = false
  description = "Stand up the second-generation ingestion runtime, beside the running Depot or (with depot_v1_enabled = false) on its own. Additive; false creates nothing."
}

variable "depot_v2_chart_name" {
  type        = string
  default     = "depot-ingest-v2"
  description = "Depot v2 ingestion chart artifact name inside this project's depot-connectors repository."
}

variable "depot_v2_chart_version" {
  type        = string
  default     = "0.3.0"
  description = "Depot v2 ingestion chart version the bootstrap installs. After install the operator applies the version the IgniteIQ platform holds for this tenant, without an apply. A re-apply never moves the chart back: when the running version is newer than this value, the bootstrap keeps it. Raise this only for a release that needs an apply."
}

variable "depot_v2_engine_image_repo" {
  type        = string
  default     = ""
  description = "Registry path holding depot-v2-server, depot-v2-control-plane and depot-v2-worker, to pull the Depot v2 engine from instead of its public registry. Empty (the default) uses the chart's own image paths. Set only where those images have been mirrored; nothing publishes them into depot-connectors."
}

variable "depot_operator_chart_name" {
  type        = string
  default     = "depot-operator"
  description = "Depot operator chart artifact name inside this project's depot-connectors repository."
}

variable "depot_operator_chart_version" {
  type        = string
  default     = "0.1.0"
  description = "Depot operator chart version to install beside Depot v2. Empty installs no operator: the engine runs, and nothing in this project can change its version until one is set."
}

variable "depot_operator_image_digest" {
  type        = string
  default     = "sha256:c5a51c65fb6da3d4d8abaac790e471dd3d1fe3866f9391bc3e623c883e93c87d"
  description = "sha256 digest of the operator image in this project's depot-connectors repository, pinned so the running operator is exactly the one IgniteIQ published. Required when depot_operator_chart_version is set."
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

# ── Generated-password shape ─────────────────────────────────────────────────
# 🔴 THESE EXIST FOR IMPORTS, NOT FOR PREFERENCE. `length` and `special` are force-new on
# random_password, so a tenant whose live secret was generated with a different shape plans
# as a REPLACEMENT -- which rotates the password on a running database, or writes a secret
# version nothing has read.
#
# Measured on tapps, 2026-10-22, the first tenant imported rather than built:
#   depot-sql-root-password    24 chars WITH specials   (harness said special = false)
#   depot-relay-secret-tapps   64 chars WITH specials   (harness said 48, special = false)
# Both were made by hand in July. Overriding these two in tapps' tfvars takes its plan from
# "4 to destroy" to "0 to destroy" without touching the live credentials.
#
# ⚠️ DEFAULTS ARE THE FLEET'S CURRENT SHAPE AND MUST NOT DRIFT TO SUIT ONE TENANT. airworks,
# caddies and airtemp had theirs generated to exactly these values; changing a default here
# would propose rotating all three on their next apply.
#
# 🔴 A plan that replaces random_password.depot_sql_root is a STOP, not a diff: it changes
# the live root password, nothing reads it back, and deletion_protection now rules out
# recreating the instance to recover.

variable "sql_root_password_length" {
  type        = number
  default     = 24
  description = "Length of the generated Cloud SQL root password. Override only to match a tenant whose secret predates this harness."
}

variable "sql_root_password_special" {
  type        = bool
  default     = false
  description = "Whether the generated Cloud SQL root password may contain special characters. Override only to match an imported tenant."
}

variable "relay_secret_length" {
  type        = number
  default     = 48
  description = "Length of the generated relay shared secret. Override only to match a tenant whose secret predates this harness."
}

variable "relay_secret_special" {
  type        = bool
  default     = false
  description = "Whether the generated relay shared secret may contain special characters. Override only to match an imported tenant."
}

# igniteiq-deploy

Customer-run Terraform that provisions an IgniteIQ **Depot** ingestion stack
inside the customer's **own** GCP project. Launched from the IgniteIQ Studio
onboarding wizard via "Deploy to Google Cloud" (Cloud Shell). The customer runs
it as themselves — **IgniteIQ never receives their credentials** and holds only
the write-only + data-plane grants this module creates, all visible in their own
IAM.

Design: `igniteiq-docs/docs/engineering/self-serve-onboarding.md`. Runbook this
transcribes: `igniteiq-docs/docs/runbooks/depot-gke-deployment.md`.
Tracked as **ENG-252** (self-serve onboarding project).

## What it provisions (all in the customer project)
- Depot ingestion cluster (GKE Autopilot) + `depot-sa` + Workload Identity
- Depot config database (Cloud SQL Postgres, private IP) — preserves cursor state
- `depot-connectors` Artifact Registry repo (IgniteIQ pushes the pinned image in)
- BigQuery datasets: `depot_raw`, `depot_internal`, `forge_staging`, `forge_intermediate`, `ontology`
- ServiceTitan credential **secret shells** (values written later, self-serve, in Studio)
- IgniteIQ data-plane grants: `forge-runner` (transform), `vault-sa` (read) — least-privilege, dataset-scoped
- Write-only secret path for Studio credential vaulting (`secretVersionAdder`)
- Depot ingestion runtime + connector registration + BigQuery destination + relay
- Two completion callbacks to IgniteIQ (connector-push pre-flight, infra-ready)

## Nomenclature
This is a **customer-facing** artifact, so it contains **no vendor names** —
everything is Depot/Forge/Vault. The ingestion runtime is delivered as an
**IgniteIQ-hosted, Depot-branded Helm chart** and connector image (see
Prerequisites) precisely so the vendor never appears in the repo, the commands,
or the running resources.

## Prerequisites (IgniteIQ-hosted — must exist before this module can apply)
> These are IgniteIQ-side artifacts the module references via variables. They
> are their own workstream (tracked separately).
- **Depot ingestion Helm chart** at `var.depot_chart_repo` (`charts.igniteiq.com`)
  exposing Depot-branded values (`auth.enabled`, `database.*`, `serviceAccount.name`,
  `bundledPostgres.enabled`) and mapping its job service-account to `depot-ingest`.
- **`connector-publisher@igniteiq-dev`** SA (or override) that the connector-push
  callback uses to write into the customer's `depot-connectors` repo.
- **`depot-relay` image** available to pull into the customer project, and the
  relay reading `DEPOT_INTERNAL_URL` (not the legacy vendor env var).
- Platform endpoints `POST /api/onboarding/connector-push` and
  `POST /api/onboarding/infra-ready` (ENG-254 / ENG-259).

## Status
Module written 2026-07-13; `terraform validate` clean. **NOT yet applied** —
end-to-end validation against throwaway projects is **ENG-258** (expect the
three ordering traps — PSA→SQL, k8s-SA→chart, auth-off→register→auth-on — to
need real-apply shakeout). Do not point a real customer at this until ENG-258
passes.

## Usage (normally the wizard drives this)
```bash
# 1. wizard generates terraform.tfvars (see terraform.tfvars.example)
bash scripts/bootstrap_state.sh   # create the customer-owned state bucket (D3)
terraform init
terraform plan
terraform apply                    # ~15–20 min
# → infra-ready callback fires → Studio detects → Connect ServiceTitan
```

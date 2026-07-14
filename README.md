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
This is a **customer-facing** artifact: everything you configure and every
resource that lands in your project is Depot/Forge/Vault-branded — no vendor
names in the variables, the commands, the tfvars, or the GCP console. The one
exception is a handful of **cluster-internal, kubectl-only names** inside
`scripts/depot_bootstrap.sh` (the ingestion runtime's workload service account
`airbyte-admin` and the chart-generated `airbyte-auth-secrets`) — these are
fixed by the upstream chart and never surface in anything you set or see in the
console. See the "boundary P" note in the design doc.

## Prerequisites (IgniteIQ-hosted — referenced by the module/callbacks)
> IgniteIQ-side artifacts the module + callbacks rely on. Nothing for you to set up.
- **Depot ingestion runtime** (connector image, Helm chart, and relay image) is
  delivered as **in-project OCI artifacts**: the `connector-push` callback copies
  all three into your own `depot-connectors` repo (nothing pulled from a public
  registry). The bootstrap installs the chart via `oci://<project>/depot-connectors/depot-ingest`.
- **`connector-publisher@igniteiq-dev`** SA that the connector-push callback uses
  to write those artifacts into your `depot-connectors` repo (write-only).
- Platform callbacks `POST /api/onboarding/connector-push` and
  `POST /api/onboarding/infra-ready`, then `onboarding-finalize` (ENG-259 / 254 / 255).

## Status
`terraform validate` clean and **applied end-to-end on a real project** — the
full chain (module → connector-push → GKE + Cloud SQL bootstrap → infra-ready)
passed in the ENG-258 sandbox validation (2026-07-13). The three ordering traps
(PSA→SQL, WI-binding→cluster, auth-off→register→auth-on) are handled.

## Launch it (normally the Studio wizard drives this)
The wizard shows a **"Deploy to Google Cloud"** button — a Cloud Shell deep link
that clones this repo in the customer's account and opens the tutorial:
```
https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/igniteIQ-Platform/igniteiq-deploy&cloudshell_tutorial=tutorial.md
```
Manual (from a clone with `terraform.tfvars` in place):
```bash
bash scripts/bootstrap_state.sh    # create the customer-owned state bucket (D3)
bash scripts/ensure_terraform.sh   # install Terraform if Cloud Shell lacks it
terraform init && terraform apply  # ~15–20 min
# → connector-push + infra-ready callbacks fire → Studio detects → Connect ServiceTitan
```

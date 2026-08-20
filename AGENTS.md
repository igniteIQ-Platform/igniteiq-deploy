# igniteiq-deploy — Agent Notes

> `CLAUDE.md` in this repo is a symlink to this file. Checked in — shared with cloud sessions, CI agents, and teammates.

## Overview

Customer-run Terraform that provisions an IgniteIQ **Depot** ingestion stack inside the **customer's own** GCP project. Launched from the Studio onboarding wizard's "Deploy to Google Cloud" button, which opens Cloud Shell on `tutorial.md`. The customer runs it as themselves — **IgniteIQ never receives their credentials** and holds only the write-only and data-plane grants this module creates, all visible in their own IAM.

Design: `igniteiq-docs/docs/engineering/self-serve-onboarding.md`. Runbook it transcribes: `igniteiq-docs/docs/runbooks/depot-gke-deployment.md`. Tracked as ENG-252.

## ⚠️ Read first: three things that make this repo unlike the others

**1. This repo is PUBLIC.** Everything committed here is world-readable and permanent. Do not add customer identifiers, project ids, service-account emails, internal hostnames, or quoted internal decisions. Check what you are about to commit against that, every time — `parity-exceptions.json` already carries more of this than it should (see Housekeeping).

**2. The default branch is `master`, not `main`.** Scripts, docs and muscle memory that assume `main` will silently target nothing here.

**3. It runs on someone else's machine, in someone else's project, as someone else.** You cannot reproduce a customer's failure locally, and you have no access to the project it runs in. Cloud Shell's toolchain is not your laptop's — see the portability trap below.

## Layout

Flat Terraform at the root — `network.tf`, `cloudsql.tf`, `gke.tf`, `iam.tf`, `secrets.tf`, `bigquery.tf`, `artifactregistry.tf`, `bootstrap.tf`. Imperative steps live in `scripts/`. `tutorial.md` is what the customer actually reads in Cloud Shell.

## Common commands

```bash
bash scripts/fetch_config.sh <code>   # writes terraform.tfvars from the wizard
bash scripts/preflight.sh             # catches the #1 blocker before a 20-min apply
bash scripts/bootstrap_state.sh       # customer-owned state bucket; REWRITES backend.tf
bash scripts/ensure_terraform.sh      # Cloud Shell may not ship Terraform
terraform init && terraform apply     # ~15-20 min
python3 scripts/check_provision_parity.py --self-test
python3 scripts/check_provision_parity.py --project <proj> --slug <slug>
```

## 🔴 The three ordering traps

All three are already encoded in `depends_on` or script sequence. They surfaced in the ENG-258 sandbox apply. If you refactor, preserve them — each fails in a way that does not name its cause.

1. **PSA range + peering before the SQL instance.** Without it the instance never gets a private IP. `network.tf` states it; the `depends_on` is on the instance in `cloudsql.tf`.
2. **Workload Identity binding after the cluster.** The `<project>.svc.id.goog` identity pool that `local.wi_member` references does not exist until a WI-enabled cluster does. `iam.tf` `depot_wi` depends on `google_container_cluster.depot`.
3. **Auth off → register the connector → auth on.** The runtime chart installs with auth disabled, the connector is registered over a port-forward, then auth comes on for the relay. Reordering leaves either an unregistered connector or an unreachable relay.

## Traps where the tooling lies

- **`backend.tf` is deliberately a commented-out block.** State belongs in the customer's project (D3) and the bucket must exist before `terraform init`, so `bootstrap_state.sh` **rewrites the file**. It is left commented so the module validates and inits with local state during development. It is not an oversight — do not "fix" it, and do not hand-edit it expecting the edit to survive.
- **`\s` is a GNU extension, and Cloud Shell is not your laptop.** `grep -E '^\s*project_id'` matched nothing there, so `preflight.sh` read an empty project id and reported **"no Organization"** — a confident, wrong diagnosis of the exact blocker it exists to catch. Fixed in `5400c32` (2026-08-17) by using `[[:space:]]`. Every script here runs in the customer's shell: assume POSIX, and prefer character classes over shorthand.
- **There is no CI in this repo.** Nothing stands between an edit and a customer running it. `terraform validate` and the parity check are hand-run; care substitutes for tooling.

## The parity check is the model to copy

`scripts/check_provision_parity.py` (ENG-433) answers "does this project actually look provisioned?" and is worth reading before you write any other guard here. Two deliberate choices:

- **It compares against the Terraform, not against a reference tenant.** A tenant inherits its own mistakes — that is how a project-level grant, wider than this module declares, propagated by being copied from a "known-good" tenant. The Terraform is the specification; a tenant is a copy of one.
- **Expectations are derived by parsing the `.tf` files, not from a hand-written list.** Add a `google_project_iam_member` to `iam.tf` and the next run covers it with no edit here. A hand list shares the blind spot of the thing it checks.

It has `--self-test`. Run it before trusting a green result.

## `parity-exceptions.json`

An entry does **not** hide a finding — the check still prints it, marked ACCEPTED with its reason, and only stops it failing the run. Every entry needs a reason, a date and an owner; an exception with no reason is indistinguishable from a bug someone gave up on. Standing rule from Ryan: **additive only, no IAM revokes without his approval.**

## Do not

- Don't commit customer identifiers, project ids or SA emails — this repo is public.
- Don't introduce vendor names into anything a customer configures or sees. The only exception is cluster-internal, kubectl-only names fixed by the upstream chart inside `depot_bootstrap.sh`.
- Don't commit `terraform.tfvars` (gitignored) or any state file.
- Don't make the runtime pull from a public registry — the connector-push callback copies all three OCI artifacts into the customer's own `depot-connectors` repo by design.
- Don't revoke an IAM binding to satisfy the parity check. Add the correct grant; record the wider one as an exception.

## Housekeeping

- `scripts/__pycache__/check_provision_parity.cpython-314.pyc` is **tracked**, and `__pycache__/` is not in `.gitignore`. A compiled artifact in a public repo should be neither.
- `parity-exceptions.json` publishes six customer project ids, service-account emails and quoted internal decisions. That is a disclosure question, not a style one — raise it rather than adding to it.
- **One exception entry is stale.** The abctl-VM entry describes a tenant with no `depot-sa`, ingesting from a VM on a service-account key. That tenant was cut over to Depot-on-GKE on 2026-08-17: it now has `depot-sa` with Workload Identity, and the key was deleted. The entry's own review note says to DELETE it on ENG-281 completion rather than update it. Verified 2026-08-20 against `igniteiq-docs/docs/customers/<tenant>/depot-gke-migration-2026-08-17.md`.

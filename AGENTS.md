# igniteiq-deploy — Agent Notes

> `CLAUDE.md` in this repo is a symlink to this file. Checked in — shared with cloud sessions, CI agents, and teammates.


## ⚠️ Read first: you may not be alone in this checkout

Ten repos live in one shared directory and several agent sessions run against them at once,
so the checkout you find is not necessarily yours. This has gone wrong twice, and both times
it looked like success:

- **2026-08-27** — a commit meant for `main` landed and pushed onto *another session's*
  feature branch, because the shared checkout was on that branch. `git log -1` showed the
  commit and read exactly like confirmation.
- **2026-08-31** — `igniteiq-docs` carried another session's uncommitted change for a full
  working day. `git add -A` would have swept it into an unrelated commit.

**Prefer your own worktree.** Sessions that write code should work in one rather than in the
shared checkout.

**If you are in the shared checkout:**
- stage explicit paths — never `git add -A`
- verify a push by reading `origin/<branch>`, never the local log
- check before you commit:

```
python3 ~/Development/GitHub/igniteiq-docs/scripts/check_worktree_isolation.py          # this repo
python3 ~/Development/GitHub/igniteiq-docs/scripts/check_worktree_isolation.py --fleet  # all ten
```

Worktrees are created at `.claude/worktrees/<name>` inside the repo and are gitignored.

## Overview

Customer-run Terraform provisioning an IgniteIQ **Depot** ingestion stack inside the **customer's own** GCP project. Launched from the onboarding wizard's "Deploy to Google Cloud" button, which opens Cloud Shell on `tutorial.md`. The customer runs it as themselves — **IgniteIQ never receives their credentials** and holds only the write-only and data-plane grants this module creates, all visible in their own IAM.

Design: `igniteiq-docs/docs/engineering/self-serve-onboarding.md`; runbook it transcribes: `docs/runbooks/depot-gke-deployment.md`. ENG-252.

## ⚠️ Read first: three things that make this repo unlike the others

**1. This repo is PUBLIC — deliberately, and it must stay that way.** Org policy is that no IgniteIQ repo is public; this is the one exception, because the onboarding wizard builds a Cloud Shell URL with `cloudshell_git_repo` and the **customer's** shell clones this repo **as the customer**, who has no access to our org. Making it private breaks the "Deploy to Google Cloud" button (Darren, 2026-08-21). Do not "fix" the visibility.

Consequence: everything committed here is world-readable and permanent. No customer identifiers, project ids, SA emails, internal hostnames or quoted internal decisions. Check every commit against that; `parity-exceptions.json` already carries more than it should — ENG-589, and see Housekeeping.

**2. The default branch is `master`, not `main`.** Anything assuming `main` silently targets nothing here.

**3. It runs on someone else's machine, in someone else's project, as someone else.** You cannot reproduce a customer failure locally and have no access to the project. Cloud Shell's toolchain is not your laptop's — see the portability trap.

## Layout

Flat Terraform at the root — `network.tf`, `cloudsql.tf`, `gke.tf`, `iam.tf`, `secrets.tf`, `bigquery.tf`, `artifactregistry.tf`, `bootstrap.tf`. Imperative steps live in `scripts/`. `tutorial.md` is what the customer actually reads in Cloud Shell.

## Common commands

```bash
bash scripts/fetch_config.sh <code>  # terraform.tfvars from the wizard
bash scripts/preflight.sh            # catches the #1 blocker pre-apply
bash scripts/bootstrap_state.sh      # state bucket; REWRITES backend.tf
bash scripts/ensure_terraform.sh     # Cloud Shell may lack Terraform
terraform init && terraform apply    # ~15-20 min
python3 scripts/check_provision_parity.py --self-test
python3 scripts/check_provision_parity.py --project <proj> --slug <slug>
```

## 🔴 The three ordering traps

All three are encoded in `depends_on` or script sequence, and surfaced in the ENG-258 sandbox apply. If you refactor, preserve them — each fails without naming its cause.

1. **PSA range + peering before the SQL instance**, or the instance never gets a private IP. `network.tf` states it; the `depends_on` is on the instance in `cloudsql.tf`.
2. **Workload Identity binding after the cluster.** The `<project>.svc.id.goog` pool that `local.wi_member` references does not exist until a WI-enabled cluster does. `iam.tf` `depot_wi` depends on `google_container_cluster.depot`.
3. **Auth off → register the connector → auth on.** The chart installs with auth disabled, the connector is registered over a port-forward, then auth comes on for the relay. Reordering leaves an unregistered connector or an unreachable relay.

## Traps where the tooling lies

- **`backend.tf` is deliberately commented out.** State belongs in the customer's project (D3) and the bucket must exist before `terraform init`, so `bootstrap_state.sh` **rewrites the file**. Left commented so the module validates and inits locally in development. Not an oversight — do not "fix" it, and do not hand-edit expecting it to survive.
- **`\s` is a GNU extension, and Cloud Shell is not your laptop.** `grep -E '^\s*project_id'` matched nothing there, so `preflight.sh` read an empty project id and reported **"no Organization"** — a confident, wrong diagnosis of the very blocker it exists to catch. Fixed in `5400c32` via `[[:space:]]`. Every script runs in the customer's shell: assume POSIX, prefer character classes.
- ~~**There is no CI here.**~~ Fixed 2026-08-30: `checks.yml` now runs `terraform fmt -check` + `validate` (with `-backend=false`, which is required — see below), `shellcheck -S error` over `scripts/`, the parity-check self-test, and the bare-hostname rule. **It reports; it does not gate** — this repo still has no branch protection, so read the run rather than trusting the merge button.

## The parity check is the model to copy

`scripts/check_provision_parity.py` (ENG-433) answers "does this project actually look provisioned?" — read it before writing any other guard here. Two deliberate choices:

- **It compares against the Terraform, not a reference tenant.** A tenant inherits its own mistakes: that is how a project-level grant wider than this module declares propagated, by being copied from a "known-good" tenant. The Terraform is the specification; a tenant is a copy of one.
- **Expectations are parsed from the `.tf` files, not a hand-written list.** Add a `google_project_iam_member` to `iam.tf` and the next run covers it with no edit here. A hand list shares the blind spot of the thing it checks.

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
- **One exception entry is stale and should be DELETED, not updated** — the abctl-VM entry, whose tenant was cut over to Depot-on-GKE on 2026-08-17 (now `depot-sa` + Workload Identity, key deleted). Its own review note says delete on ENG-281 completion; ENG-281 closed 2026-08-19.

#!/usr/bin/env bash
# Installs Depot v2, creates its BigQuery sink, and points the tenant's one relay at
# it: updating the relay the running Depot's bootstrap deployed, or, on a project
# with no running Depot (DEPLOY_RELAY=1), deploying it. Then registers the engine
# with infra-ready. Registering is not switching: a tenant already on the running
# Depot stays on it, and only a tenant that never registered starts on v2.
#
# Secret values are never passed as arguments, logged or written to disk.
# They are piped to each tool on stdin.
set -euo pipefail

log() { echo "[depot-v2-bootstrap] $*"; }
die() { echo "[depot-v2-bootstrap] $*" >&2; exit 1; }
secret() { gcloud secrets versions access latest --secret="$1" --project="${PROJECT_ID}"; }
k8s_secret() { # reads KEY=VALUE lines from stdin
  kubectl create secret generic "$1" -n "${NAMESPACE}" --from-env-file=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
}

VALUES="$(mktemp)"
IMAGES="$(mktemp)"
PF_PID=""
trap 'rm -f "${VALUES}" "${IMAGES}"; if [[ -n "${PF_PID}" ]]; then kill "${PF_PID}" 2>/dev/null || true; fi' EXIT

gcloud container clusters get-credentials "${CLUSTER_NAME:-depot-cluster}" \
  --project="${PROJECT_ID}" --region="${REGION}" >/dev/null
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Create the three Kubernetes Secrets the chart expects. Each value is checked
# first, because kubectl will happily store an empty value.
SQL_PW="$(secret "${SQL_ROOT_SECRET}")"
CLIENT_SECRET="$(secret "depot-v2-client-secret-${SLUG}")"
ADMIN_PW="$(secret "depot-v2-admin-password-${SLUG}")"
IDP_ADMIN_PW="$(secret "depot-v2-idp-admin-password-${SLUG}")"
AUTH_CLIENT_SECRET="$(secret "depot-v2-auth-client-secret-${SLUG}")"
for v in SQL_PW CLIENT_SECRET ADMIN_PW IDP_ADMIN_PW AUTH_CLIENT_SECRET; do
  [[ -n "${!v}" ]] || die "${v} read back empty; refusing to install"
done

printf 'PERSISTENCE_DSN=postgres://postgres:%s@%s:5432/db-depot-v2?sslmode=disable\nNATS_URL=nats://depot-v2-nats.%s.svc.cluster.local:4222\n' \
  "${SQL_PW}" "${SQL_PRIVATE_IP}" "${NAMESPACE}" | k8s_secret depot-v2-runtime
printf 'password=%s\n' "${SQL_PW}" | k8s_secret depot-v2-db-auth
printf 'AUTH_CLIENT_SECRET=%s\nAUTH_ADMIN_PASSWORD=%s\nAUTH_BOOTSTRAP_CLIENT_SECRET=%s\nAUTH_BOOTSTRAP_ADMIN_PASSWORD=%s\n' \
  "${AUTH_CLIENT_SECRET}" "${IDP_ADMIN_PW}" "${CLIENT_SECRET}" "${ADMIN_PW}" | k8s_secret depot-v2-idp-auth
unset SQL_PW ADMIN_PW IDP_ADMIN_PW AUTH_CLIENT_SECRET # CLIENT_SECRET is still needed below

# Install the chart. Only per-tenant values are set here; the defaults live in
# the chart.
gcloud auth print-access-token \
  | helm registry login "${REGION}-docker.pkg.dev" -u oauth2accesstoken --password-stdin >/dev/null

cat >"${VALUES}" <<YAML
ingest:
  secrets:
    prefix: "${SECRET_PREFIX}"
    gcp:
      projectId: "${PROJECT_ID}"
      region: "${REGION}"
  auth:
    bootstrap:
      tenant: "${SLUG}"
  keycloak:
    database:
      hostname: "${SQL_PRIVATE_IP}"
  server:
    serviceAccount:            # shared by every component
      annotations:
        iam.gke.io/gcp-service-account: "${DEPOT_SA}"
YAML

# The engine images come from their public registry, the chart's defaults, as the running
# Depot's runtime images do; only IgniteIQ-built artifacts (the charts, the operator, the
# relay) are copied into this project. ENGINE_IMAGE_REPO repoints them at a mirror that
# already holds depot-v2-{server,control-plane,worker}; nothing publishes them there today.
if [[ -n "${ENGINE_IMAGE_REPO:-}" ]]; then
  cat >"${IMAGES}" <<YAML
ingest:
  server: { image: { repository: "${ENGINE_IMAGE_REPO}/depot-v2-server" } }
  controlPlane: { image: { repository: "${ENGINE_IMAGE_REPO}/depot-v2-control-plane" } }
  worker: { image: { repository: "${ENGINE_IMAGE_REPO}/depot-v2-worker" } }
YAML
fi

# With an operator, IgniteIQ moves the chart's version after install, so the running release
# may be newer than depot_v2_chart_version. A re-apply then upgrades at the RUNNING version: the
# values below still apply, and the version never goes back. The operator refuses downgrades
# for the same reason a re-apply must not make one: the engine's migrations only move forward.
# A depot_v2_chart_version newer than the running one still upgrades, as before (ENG-1169).
VERSION="${CHART_VERSION}"
if [[ -n "${OPERATOR_CHART_VERSION:-}" ]]; then
  RUNNING="$(helm list -n "${NAMESPACE}" --filter '^depot-v2$' -o json \
    | python3 -c 'import sys,json; r=json.load(sys.stdin); print(r[0]["chart"].rsplit("-",1)[1] if r else "")')"
  if [[ -n "${RUNNING}" ]] && python3 -c 'import sys; v=[tuple(map(int,s.split("."))) for s in sys.argv[1:]]; sys.exit(0 if v[0]<v[1] else 1)' "${CHART_VERSION}" "${RUNNING}"; then
    log "chart ${RUNNING} is running, newer than depot_v2_chart_version ${CHART_VERSION}; keeping ${RUNNING}"
    VERSION="${RUNNING}"
  fi
fi

# No --wait: database migrations run as a post-install hook, and Helm already
# waits for that hook to finish.
log "installing chart ${VERSION}"
helm upgrade --install depot-v2 "${CHART_OCI_REF}" --version "${VERSION}" \
  -n "${NAMESPACE}" -f "${VALUES}" -f "${IMAGES}" --timeout 15m
kubectl rollout status deployment/depot-v2-server -n "${NAMESPACE}" --timeout=10m

# The operator: its own release in its own namespace, never part of the engine's (an
# operator inside the release it upgrades is replaced mid-upgrade and leaves the release
# pending). It starts idle: the platform answers 404 until IgniteIQ sets a desired version
# for this tenant, and the operator does nothing on a 404.
if [[ -n "${OPERATOR_CHART_VERSION:-}" ]]; then
  [[ -n "${OPERATOR_IMAGE_DIGEST:-}" ]] || die "OPERATOR_IMAGE_DIGEST is required with OPERATOR_CHART_VERSION; the operator image is pinned by digest"
  log "installing operator chart ${OPERATOR_CHART_VERSION}"
  helm upgrade --install depot-operator "${OPERATOR_CHART_OCI_REF}" --version "${OPERATOR_CHART_VERSION}" \
    -n "${OPERATOR_NAMESPACE}" --create-namespace --wait --timeout 5m \
    --set "image.repository=${IMAGE_REPO:?IMAGE_REPO is needed for the operator image}/depot-operator" \
    --set "image.digest=${OPERATOR_IMAGE_DIGEST}" \
    --set "platformUrl=${PLATFORM_URL}" \
    --set "chart=${CHART_OCI_REF}" \
    --set "engine.release=depot-v2" --set "engine.namespace=${NAMESPACE}" \
    --set "serviceAccount.gcpServiceAccount=${DEPOT_SA}"
else
  log "no OPERATOR_CHART_VERSION: no operator installed; this project's Depot v2 changes only by re-apply"
fi

# Create the BigQuery sink. The engine is only reachable inside the VPC, so this
# goes through a port-forward. Creating the sink also confirms the engine can use
# depot-sa, since it runs a test query.
API=http://localhost:18080
forward() { # restart the port-forward if the server pod restarted
  if [[ -z "${PF_PID}" ]] || ! kill -0 "${PF_PID}" 2>/dev/null; then
    kubectl port-forward -n "${NAMESPACE}" svc/depot-v2-server 18080:8080 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 2
  fi
}

TOKEN=""
for _ in $(seq 1 30); do # the server restarts until the identity provider is ready
  forward
  TOKEN="$(printf '{"clientId":"depot-relay","clientSecret":"%s"}' "${CLIENT_SECRET}" \
    | curl -s --max-time 10 "${API}/auth.v1.AuthService/GetToken" -H 'Content-Type: application/json' -d @- \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null || true)"
  [[ -n "${TOKEN}" ]] && break
  sleep 10
done
unset CLIENT_SECRET
[[ -n "${TOKEN}" ]] || die "no token as depot-relay after 5 minutes; check the server and identity provider logs"

api() { # api <method> <json body>
  printf 'Authorization: Bearer %s\n' "${TOKEN}" \
    | curl -sS --fail-with-body --max-time 120 "${API}/ingestion.v1.IngestionService/$1" \
        -H @- -H 'Content-Type: application/json' -d "$2"
}

SINKS="$(api ListConnections '{"kind":"CONNECTOR_KIND_SINK"}')" || die "listing sinks failed: ${SINKS}"
if python3 -c 'import sys,json; sys.exit(0 if any(c.get("name")=="bigquery" for c in json.load(sys.stdin).get("connections",[])) else 1)' <<<"${SINKS}"; then
  log "BigQuery sink exists"
else
  OUT="$(api CreateConnection "{\"kind\":\"CONNECTOR_KIND_SINK\",\"name\":\"bigquery\",\"connector\":\"bigquery\",\"config\":{\"project_id\":\"${PROJECT_ID}\",\"location\":\"${BQ_LOCATION}\"}}")" \
    || die "creating the BigQuery sink failed: ${OUT}"
  log "BigQuery sink created"
fi
unset TOKEN
kill "${PF_PID}" 2>/dev/null || true
PF_PID=""

# Wait for the internal load balancer, then teach the relay where it is.
ILB_IP=""
for _ in $(seq 1 30); do
  ILB_IP="$(kubectl get svc depot-v2-server -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${ILB_IP}" ]] && break
  sleep 10
done
[[ -n "${ILB_IP}" ]] || die "internal load balancer never got an address"
log "internal load balancer ${ILB_IP}"

if [[ "${SKIP_RELAY:-0}" == "1" ]]; then
  log "SKIP_RELAY=1: the relay was not updated and the engine was not registered"
  exit 0
fi

# There is ONE relay per tenant. The same image serves both engines: it forwards v2 paths
# to the engine and everything else to the running Depot, and runs with either alone. Its
# URL and RELAY_SECRET are the tenant's, whichever engine is behind it, which is why no
# second relay secret exists for v2. The engine's client secret is mounted as a FILE: the
# relay exchanges it for the engine's token and never logs it, and a file keeps it out of
# the service's environment and its revision description. The relay reads it from Secret
# Manager itself; this only checks it exists.
[[ "$(gcloud secrets versions describe latest --secret="depot-v2-client-secret-${SLUG}" \
  --project="${PROJECT_ID}" --format='value(state)')" == "ENABLED" ]] || die "depot-v2-client-secret-${SLUG} has no enabled version"
V2_ENV="DEPOT_V2_INTERNAL_URL=http://${ILB_IP}:8080,DEPOT_V2_CLIENT_SECRET_FILE=/secrets/client-secret"
V2_SECRETS="/secrets/client-secret=depot-v2-client-secret-${SLUG}:latest"

if gcloud run services describe depot-relay --project="${PROJECT_ID}" --region="${REGION}" --format='value(name)' >/dev/null 2>&1; then
  # Beside the running Depot: depot_bootstrap.sh deployed it, so ADD the v2 settings and set
  # the image. A relay built before v2 routing sends v2 paths to the running Depot, which
  # answers 200 with HTML (ENG-1119); RELAY_IMAGE is the copy connector_push just refreshed.
  gcloud run services update depot-relay --project="${PROJECT_ID}" --region="${REGION}" \
    --image="${RELAY_IMAGE}" \
    --update-env-vars="${V2_ENV}" --update-secrets="${V2_SECRETS}" --quiet >/dev/null
elif [[ "${DEPLOY_RELAY:-0}" == "1" ]]; then
  # v2 only: nothing deployed it. The flags are depot_bootstrap.sh's, with RELAY_SECRET
  # mounted from Secret Manager rather than written into the environment.
  # 🔴 --service-account is LOAD-BEARING, as in depot_bootstrap.sh: the default compute SA
  # cannot read secrets (ENG-739).
  log "deploying the relay"
  gcloud run deploy depot-relay --project="${PROJECT_ID}" --region="${REGION}" \
    --image="${RELAY_IMAGE}" \
    --service-account="${DEPOT_SA}" \
    --set-env-vars="${V2_ENV}" \
    --set-secrets="RELAY_SECRET=${RELAY_SECRET_NAME}:latest,${V2_SECRETS}" \
    --allow-unauthenticated --no-cpu-throttling --min-instances=1 \
    --network=default --subnet=default --vpc-egress=all-traffic --quiet >/dev/null
else
  die "no depot-relay service: with v1 on, the running Depot's bootstrap deploys it, and this only updates it"
fi
RELAY_URL="$(gcloud run services describe depot-relay --project="${PROJECT_ID}" --region="${REGION}" --format='value(status.url)')"
[[ -n "${RELAY_URL}" ]] || die "the relay has no URL"
log "relay ${RELAY_URL}"

RESP="$(mktemp)"
trap 'rm -f "${VALUES}" "${IMAGES}" "${RESP}"; if [[ -n "${PF_PID}" ]]; then kill "${PF_PID}" 2>/dev/null || true; fi' EXIT

# Check the relay reaches the engine before registering it. A 200 alone proves nothing: a
# relay without v2 routing answers a v2 path with 200 and HTML (ENG-1119), so the check is
# on the content type. Retried, since a fresh revision has been seen to fail once on its
# first requests. The relay secret is piped as a header, never passed as an argument.
log "checking the relay forwards to Depot v2"
PROBE=""
for _ in 1 2 3 4 5 6; do
  PROBE="$(secret "${RELAY_SECRET_NAME}" | sed 's/^/x-relay-secret: /' \
    | curl -s -o "${RESP}" -w '%{http_code} %{content_type}' --max-time 60 -X POST \
        "${RELAY_URL}/ingestion.v1.IngestionService/ListConnections" \
        -H @- -H 'Content-Type: application/json' --data '{}' || echo 000)"
  [[ "${PROBE}" == "200 application/json"* ]] && break
  sleep 10
done
[[ "${PROBE}" == "200 application/json"* ]] || die "the relay does not forward to Depot v2 (got ${PROBE}); is its image older than v2 routing?"

# Register the engine. The body carries the installed chart version, which seeds the
# operator's rollout row and must be a release IgniteIQ published (422 otherwise), and the
# region the chart's registry is in, where a rollout from the platform copies the next one.
# The relay secret is piped, never passed as an argument.
log "registering Depot v2 with IgniteIQ"
CODE="$(secret "${RELAY_SECRET_NAME}" \
  | python3 -c 'import sys,json; print(json.dumps({"orgId":sys.argv[1],"engine":"V2","relayUrl":sys.argv[2],"relaySecret":sys.stdin.read(),"chartVersion":sys.argv[3],"region":sys.argv[4]}))' \
      "${ORG_ID}" "${RELAY_URL}" "${VERSION}" "${REGION}" \
  | curl -s -o "${RESP}" -w '%{http_code}' --max-time 60 -X POST "${CALLBACK_BASE_URL}/api/onboarding/infra-ready" \
      -H "Authorization: Bearer ${PROVISIONING_TOKEN}" -H 'Content-Type: application/json' --data @- || echo 000)"
[[ "${CODE}" == "200" ]] || die "infra-ready returned HTTP ${CODE}: $(cat "${RESP}")"
log "registered: $(python3 -c 'import sys,json; r=json.load(open(sys.argv[1])); print("engine", r.get("engine"), "rollout", r.get("rollout"))' "${RESP}")"
log "Depot v2 is up behind ${RELAY_URL}."

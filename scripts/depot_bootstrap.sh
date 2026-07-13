#!/usr/bin/env bash
# Depot runtime bootstrap. Runs after all declarative infra exists. Brings up
# the ingestion control plane on the cluster, registers the connector, wires the
# BigQuery destination, exposes the relay, and reports completion to IgniteIQ.
#
# Transcribed from docs/runbooks/depot-gke-deployment.md §3–6. Ordering traps
# are encoded here (auth-off for connector registration → auth-on for the relay
# token flow). NOT yet validated end-to-end — ENG-258 gates that.
set -euo pipefail

log() { echo "[depot-bootstrap] $*"; }

# ── Cluster credentials ──────────────────────────────────────────────────────
log "fetching cluster credentials"
gcloud container clusters get-credentials depot-cluster \
  --project="${PROJECT_ID}" --region="${REGION}" >/dev/null

# ── Namespace + ingestion workload SA (pre-create before the chart) ──────────
# The workload SA + its Role/RoleBinding must exist before the chart's
# pre-install hook runs (ordering trap). Its name (${K8S_SA}) is set by the
# runtime's internal launcher config and is a cluster-internal identity only.
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount "${K8S_SA}" -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount "${K8S_SA}" -n "${NAMESPACE}" \
  "iam.gke.io/gcp-service-account=${DEPOT_SA}" --overwrite
kubectl create role "${K8S_SA}-role" -n "${NAMESPACE}" \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=configmaps,endpoints,jobs,pods,pods/log,pods/exec,pods/attach,secrets \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create rolebinding "${K8S_SA}-binding" -n "${NAMESPACE}" \
  --role="${K8S_SA}-role" --serviceaccount="${NAMESPACE}:${K8S_SA}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Config-DB password → in-cluster secret ──────────────────────────────────
SQL_PW="$(gcloud secrets versions access latest --secret="${SQL_ROOT_SECRET}" --project="${PROJECT_ID}")"
kubectl create secret generic depot-db-secret -n "${NAMESPACE}" \
  --from-literal=database-password="${SQL_PW}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Helm: install the Depot ingestion chart, auth OFF ────────────────────────
# Auth is off for the one-time connector registration (the internal config API
# is open with no token); flipped on afterward for the relay's token flow.
helm repo add depot "${CHART_REPO}" >/dev/null
helm repo update depot >/dev/null

cat >/tmp/depot-values.yaml <<YAML
auth:
  enabled: false
serviceAccount:
  create: false
  name: "${K8S_SA}"
database:
  host: "${SQL_PRIVATE_IP}"
  port: "5432"
  name: "${SQL_DB}"
  user: "postgres"
  passwordSecret: "depot-db-secret"
  passwordSecretKey: "database-password"
bundledPostgres:
  enabled: false
YAML

log "installing Depot ingestion runtime (auth off)"
helm upgrade --install depot depot/"${CHART_NAME#depot/}" \
  --version "${CHART_VERSION}" -n "${NAMESPACE}" -f /tmp/depot-values.yaml --wait --timeout 20m

# ── Register the connector (auth off) via a port-forward ─────────────────────
log "registering connector"
# Find the ingestion server service by label (avoids hardcoding a resource name).
SERVER_SVC="$(kubectl get svc -n "${NAMESPACE}" -l app.kubernetes.io/name=server -o jsonpath='{.items[0].metadata.name}')"
kubectl port-forward -n "${NAMESPACE}" "svc/${SERVER_SVC}" 8001:8001 >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 6

WORKSPACE_ID="$(curl -s http://localhost:8001/api/public/v1/workspaces \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["workspaceId"])')"
log "workspace ${WORKSPACE_ID}"

SOURCE_DEF_ID="$(curl -s -X POST http://localhost:8001/api/v1/source_definitions/create_custom \
  -H 'Content-Type: application/json' --max-time 200 \
  -d "{\"workspaceId\":\"${WORKSPACE_ID}\",\"sourceDefinition\":{\"name\":\"ServiceTitan\",\"dockerRepository\":\"${CONNECTOR_IMAGE%:*}\",\"dockerImageTag\":\"${CONNECTOR_IMAGE##*:}\",\"documentationUrl\":\"https://igniteiq.com\"}}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["sourceDefinitionId"])')"
log "connector registered (${SOURCE_DEF_ID})"

# BigQuery destination — ADC via Workload Identity (no credentials_json); raw
# working set lands in depot_internal, not the vendor default.
curl -s -X POST http://localhost:8001/api/v1/destinations/create -H 'Content-Type: application/json' \
  -d "{\"workspaceId\":\"${WORKSPACE_ID}\",\"name\":\"BigQuery\",\"destinationDefinitionId\":\"22f6c74f-5699-40ff-833c-4a879ea40133\",\"connectionConfiguration\":{\"project_id\":\"${PROJECT_ID}\",\"dataset_id\":\"${RAW_DATASET}\",\"dataset_location\":\"US\",\"raw_data_dataset\":\"${INTERNAL_DATASET}\",\"loading_method\":{\"method\":\"Standard\"}}}" >/dev/null
log "BigQuery destination created"

kill ${PF_PID} 2>/dev/null || true
trap - EXIT

# NOTE: the ServiceTitan SOURCE and the sync CONNECTION are created later,
# self-serve, in Studio → Connect ServiceTitan (ENG-205). The runtime here is
# left ready with the connector definition + destination in place.

# ── Helm: flip auth ON (relay token flow needs it) ───────────────────────────
ADMIN_PW="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
kubectl create secret generic depot-config-secrets -n "${NAMESPACE}" \
  --from-literal=instance-admin-email="ops@igniteiq.com" \
  --from-literal=instance-admin-password="${ADMIN_PW}" \
  --dry-run=client -o yaml | kubectl apply -f -
# stash admin creds for support
printf '%s' "${ADMIN_PW}" | gcloud secrets create "depot-admin-password-${SLUG}" \
  --data-file=- --project="${PROJECT_ID}" --replication-policy=automatic 2>/dev/null \
  || printf '%s' "${ADMIN_PW}" | gcloud secrets versions add "depot-admin-password-${SLUG}" --data-file=- --project="${PROJECT_ID}"

log "enabling auth"
helm upgrade depot depot/"${CHART_NAME#depot/}" --version "${CHART_VERSION}" \
  -n "${NAMESPACE}" -f /tmp/depot-values.yaml --set auth.enabled=true --wait --timeout 15m

# The chart publishes client_credentials creds in an auth secret.
CLIENT_ID="$(kubectl get secret depot-auth-secrets -n "${NAMESPACE}" -o jsonpath='{.data.instance-admin-client-id}' | base64 -d)"
CLIENT_SECRET="$(kubectl get secret depot-auth-secrets -n "${NAMESPACE}" -o jsonpath='{.data.instance-admin-client-secret}' | base64 -d)"
printf '%s' "${CLIENT_ID}"     | gcloud secrets create "depot-client-id-${SLUG}"     --data-file=- --project="${PROJECT_ID}" --replication-policy=automatic 2>/dev/null || true
printf '%s' "${CLIENT_SECRET}" | gcloud secrets create "depot-client-secret-${SLUG}" --data-file=- --project="${PROJECT_ID}" --replication-policy=automatic 2>/dev/null || true

# ── Internal LB → reachable by the relay (Cloud Run, VPC egress) ─────────────
log "exposing the ingestion server on an internal load balancer"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: depot-server-ilb
  namespace: ${NAMESPACE}
  annotations:
    networking.gke.io/load-balancer-type: "Internal"
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/instance: depot
    app.kubernetes.io/name: server
  ports:
    - { name: http, port: 8001, targetPort: 8001 }
YAML

for i in $(seq 1 30); do
  ILB_IP="$(kubectl get svc depot-server-ilb -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${ILB_IP}" ]] && break
  sleep 10
done
[[ -n "${ILB_IP:-}" ]] || { echo "[depot-bootstrap] internal LB never got an IP" >&2; exit 1; }
log "internal LB ${ILB_IP}"

# ── Deploy the relay (Cloud Run) ─────────────────────────────────────────────
RELAY_SECRET="$(gcloud secrets versions access latest --secret="${RELAY_SECRET_NAME}" --project="${PROJECT_ID}")"
gcloud run deploy depot-relay --project="${PROJECT_ID}" --region="${REGION}" \
  --image="${REGION}-docker.pkg.dev/${PROJECT_ID}/depot-connectors/depot-relay:latest" \
  --set-env-vars="DEPOT_INTERNAL_URL=http://${ILB_IP}:8001,RELAY_SECRET=${RELAY_SECRET}" \
  --allow-unauthenticated --no-cpu-throttling --min-instances=1 \
  --network=default --subnet=default --vpc-egress=all-traffic --quiet >/dev/null
RELAY_URL="$(gcloud run services describe depot-relay --project="${PROJECT_ID}" --region="${REGION}" --format='value(status.url)')"
log "relay ${RELAY_URL}"

# ── infra-ready callback ─────────────────────────────────────────────────────
log "reporting infra-ready to IgniteIQ"
curl -s --max-time 30 -X POST "${CALLBACK_BASE_URL}/api/onboarding/infra-ready" \
  -H "Authorization: Bearer ${PROVISIONING_TOKEN}" -H "Content-Type: application/json" \
  -d "{\"orgId\":\"${ORG_ID}\",\"workspaceId\":\"${WORKSPACE_ID}\",\"relayUrl\":\"${RELAY_URL}\",\"relaySecret\":\"${RELAY_SECRET}\",\"clientId\":\"${CLIENT_ID}\",\"clientSecret\":\"${CLIENT_SECRET}\"}" >/dev/null

log "done — Depot ingestion live. Connect ServiceTitan in Studio to start syncing."

#!/usr/bin/env bash
# Connector-push pre-flight (D1/C2). Asks IgniteIQ to publish the pinned Depot
# runtime OCI artifacts — the connector image, the ingestion Helm chart, the relay,
# and with Depot v2 its chart and operator — into this project's depot-connectors
# repository, to which this project's Terraform has already granted the IgniteIQ
# publisher SA write access. IgniteIQ holds no read access to the customer project
# and reads only its own source artifacts — bytes flow IgniteIQ → customer,
# authorized by a grant the customer made on their own repo.
set -euo pipefail

# shellcheck source=scripts/provisioning_token.sh
source "$(dirname "$0")/provisioning_token.sh"
PROVISIONING_TOKEN="$(provisioning_token)"

RESP="$(mktemp)"
trap 'rm -f "${RESP}"' EXIT

echo "[connector-push] requesting Depot runtime artifacts → ${REGION}-docker.pkg.dev/${PROJECT_ID}/${TARGET_REPO}/"
echo "[connector-push]   image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "[connector-push]   chart: ${CHART_NAME}:${CHART_VERSION}"

body="{\"orgId\":\"${ORG_ID}\",\"projectId\":\"${PROJECT_ID}\",\"region\":\"${REGION}\",\"targetRepo\":\"${TARGET_REPO}\",\"imageName\":\"${IMAGE_NAME}\",\"imageTag\":\"${IMAGE_TAG}\",\"chartName\":\"${CHART_NAME}\",\"chartVersion\":\"${CHART_VERSION}\""

# Depot v2: the engine chart, and the operator chart with the image digest it runs, into the
# same repository. Each group is sent only when set, so a tenant without v2 makes exactly the
# request it made before. The platform refuses a half-specified group.
if [[ -n "${V2_CHART_NAME:-}" ]]; then
  echo "[connector-push]   v2 chart: ${V2_CHART_NAME}:${V2_CHART_VERSION:-}"
  body="${body},\"v2ChartName\":\"${V2_CHART_NAME}\",\"v2ChartVersion\":\"${V2_CHART_VERSION:-}\""
fi
if [[ -n "${OPERATOR_CHART_NAME:-}" ]]; then
  echo "[connector-push]   operator: ${OPERATOR_CHART_NAME}:${OPERATOR_CHART_VERSION:-} image@${OPERATOR_IMAGE_DIGEST:-}"
  body="${body},\"operatorChartName\":\"${OPERATOR_CHART_NAME}\",\"operatorChartVersion\":\"${OPERATOR_CHART_VERSION:-}\",\"operatorImageDigest\":\"${OPERATOR_IMAGE_DIGEST:-}\""
fi
body="${body}}"

# Retry — the publisher copy is fast, but AR/network can hiccup.
# curl prints 000 itself when it gets no response, so no fallback is echoed.
attempts=5
for attempt in $(seq 1 "${attempts}"); do
  code="$(curl -s -o "${RESP}" -w "%{http_code}" --max-time 120 \
    -X POST "${CALLBACK_BASE_URL}/api/onboarding/connector-push" \
    -H "Authorization: Bearer ${PROVISIONING_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${body}" || true)"
  if [[ "${code}" == "200" ]]; then
    echo "[connector-push] runtime artifacts published into ${TARGET_REPO}."
    exit 0
  fi
  # A rejected token is rejected the same way every time: stop, and say how to get a new one.
  if [[ "${code}" == "401" ]]; then
    echo "[connector-push] FAILED: HTTP 401: $(cat "${RESP}")" >&2
    echo "[connector-push] The provisioning token was rejected; it is short-lived and single-use." >&2
    echo "[connector-push] Regenerate the config in the Studio wizard, run scripts/fetch_config.sh <code>, then re-run terraform apply." >&2
    exit 1
  fi
  if [[ "${attempt}" -lt "${attempts}" ]]; then
    echo "[connector-push] attempt ${attempt} → HTTP ${code}; retrying..."
    sleep $((attempt * 10))
  fi
done

echo "[connector-push] FAILED after ${attempts} attempts. Last response: HTTP ${code}: $(cat "${RESP}")" >&2
echo "[connector-push] The image was not published; the ingestion runtime cannot start. Contact IgniteIQ." >&2
exit 1

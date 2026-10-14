#!/usr/bin/env bash
# Connector-push pre-flight (D1/C2). Asks IgniteIQ to publish the pinned Depot
# runtime OCI artifacts — the connector image, the ingestion Helm chart, the relay,
# and with Depot v2 its chart and operator — into this project's depot-connectors
# repository, to which this project's Terraform has already granted the IgniteIQ
# publisher SA write access. IgniteIQ holds no read access to the customer project
# and reads only its own source artifacts — bytes flow IgniteIQ → customer,
# authorized by a grant the customer made on their own repo.
set -euo pipefail

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
for attempt in 1 2 3 4 5; do
  code=$(curl -s -o /tmp/connector_push_resp.json -w "%{http_code}" --max-time 120 \
    -X POST "${CALLBACK_BASE_URL}/api/onboarding/connector-push" \
    -H "Authorization: Bearer ${PROVISIONING_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${body}" || echo "000")
  if [[ "${code}" == "200" ]]; then
    echo "[connector-push] runtime artifacts published into ${TARGET_REPO}."
    exit 0
  fi
  echo "[connector-push] attempt ${attempt} → HTTP ${code}; retrying..."
  sleep $((attempt * 10))
done

echo "[connector-push] FAILED after retries. The image was not published; the ingestion runtime cannot start. Contact IgniteIQ." >&2
exit 1

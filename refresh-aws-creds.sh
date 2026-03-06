#!/usr/bin/env bash
# refresh-aws-creds.sh
# - Assumes the staging role with a fresh 1-hour STS session
# - Exports AWS creds for this shell process
# - Recreates LiteLLM bedrock-proxy so it picks up fresh env vars

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
if [[ -f "${ROOT_DIR}/.env" ]]; then
	set -a
	source "${ROOT_DIR}/.env"
	set +a
fi
AWS_SOURCE_PROFILE="${AWS_SOURCE_PROFILE:-default}"
AWS_ROLE_ARN="${AWS_ROLE_ARN:-arn:aws:iam::123456789012:role/ai-role}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SESSION_NAME="kilroy-bedrock-$(date +%s)"
DURATION_SECONDS=3600

for cmd in aws jq docker curl; do
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		echo "Error: required command not found: ${cmd}" >&2
		exit 1
	fi
done

if [[ ! -f "${COMPOSE_FILE}" ]]; then
	echo "Error: docker compose file not found: ${COMPOSE_FILE}" >&2
	exit 1
fi

echo "Assuming role ${AWS_ROLE_ARN} via source profile ${AWS_SOURCE_PROFILE} (${DURATION_SECONDS}s)..."

CREDS_JSON="$(aws sts assume-role \
	--profile "${AWS_SOURCE_PROFILE}" \
	--role-arn "${AWS_ROLE_ARN}" \
	--role-session-name "${SESSION_NAME}" \
	--duration-seconds "${DURATION_SECONDS}" \
	--output json)"

export AWS_ACCESS_KEY_ID="$(printf '%s' "${CREDS_JSON}" | jq -r '.Credentials.AccessKeyId')"
export AWS_SECRET_ACCESS_KEY="$(printf '%s' "${CREDS_JSON}" | jq -r '.Credentials.SecretAccessKey')"
export AWS_SESSION_TOKEN="$(printf '%s' "${CREDS_JSON}" | jq -r '.Credentials.SessionToken')"
export AWS_REGION_NAME="${AWS_REGION}"

EXPIRATION="$(printf '%s' "${CREDS_JSON}" | jq -r '.Credentials.Expiration')"
echo "Credentials valid until ${EXPIRATION}"

aws sts get-caller-identity --no-cli-pager --region "${AWS_REGION}" 2>/dev/null \
	| jq -r '"  Account: \(.Account)\n  Arn:     \(.Arn)"'

echo ""
echo "Starting bedrock-proxy (and litellm-db if needed)..."
docker compose -f "${COMPOSE_FILE}" up -d --force-recreate bedrock-proxy

echo ""
echo "Waiting for LiteLLM health endpoint..."
LITELLM_KEY="${LITELLM_MASTER_KEY:-sk-local-dev-master-key}"
for _ in $(seq 1 30); do
	if curl -fsS -H "Authorization: Bearer ${LITELLM_KEY}" "http://127.0.0.1:4000/health" >/dev/null 2>&1; then
		echo "LiteLLM proxy is healthy."
		exit 0
	fi
	sleep 2
done

echo "Warning: LiteLLM did not become healthy within 60s. Check logs with:" >&2
echo "  docker compose -f ${COMPOSE_FILE} logs bedrock-proxy" >&2
exit 1

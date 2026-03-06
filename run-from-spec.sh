#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
	set -a
	source "${ROOT_DIR}/.env"
	set +a
fi

KILROY_DIR="${ROOT_DIR}/kilroy"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
MODELDB_PATH="${KILROY_DIR}/internal/attractor/modeldb/pinned/openrouter_models.json"

SPEC_FILE=""
TARGET_REPO=""
GRAPH_IN=""
GRAPH_OUT=""
OUTPUT_BRANCH="${OUTPUT_BRANCH:-generated-output}"
USE_BEDROCK=true

usage() {
	cat <<'EOF'
Usage:
	./run-from-spec.sh --spec <spec.md|dir> --target <path> [options]
	./run-from-spec.sh --graph <pipeline.dot> --target <path> [options]

Examples:
	./run-from-spec.sh --spec ./spec.md --target ../my-new-project
	./run-from-spec.sh --spec ./specs/features --target ../my-new-project
	./run-from-spec.sh --graph ./pipeline.dot --target ../my-new-project

What this script does:
	1) Starts CXDB
	2) Builds kilroy
	3) If --spec: ingests markdown into a DOT pipeline (Claude CLI)
		 If --graph: uses the provided DOT file directly
	4) Validates graph and retries repair up to 3 times with ingest feedback
	5) Runs the pipeline and checks out generated output branch

Options:
	--spec <file|dir>   Markdown spec file or directory
	--graph <file.dot>  Pre-existing DOT graph
	--target <path>     Target repository path
	--graph-out <path>  Where to write the working DOT graph
	--output-branch <b> Output branch name in target repo (default: generated-output)
	--bedrock           Route LLM calls through LiteLLM proxy (default)
	--no-bedrock        Use local CLI providers (anthropic/openai/google)
EOF
}

abs_path() {
	local path="$1"
	if [[ "${path}" = /* ]]; then
		printf '%s\n' "${path}"
		return
	fi
	printf '%s/%s\n' "$(cd "$(dirname "${path}")" && pwd)" "$(basename "${path}")"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--spec)
			SPEC_FILE="${2:-}"
			shift 2
			;;
		--graph)
			GRAPH_IN="${2:-}"
			shift 2
			;;
		--target)
			TARGET_REPO="${2:-}"
			shift 2
			;;
		--graph-out)
			GRAPH_OUT="${2:-}"
			shift 2
			;;
		--output-branch)
			OUTPUT_BRANCH="${2:-}"
			shift 2
			;;
		--bedrock)
			USE_BEDROCK=true
			shift
			;;
		--no-bedrock)
			USE_BEDROCK=false
			shift
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			echo "Error: unknown argument '$1'" >&2
			usage >&2
			exit 1
			;;
	esac
done

if [[ -z "${SPEC_FILE}" && -z "${GRAPH_IN}" ]]; then
	echo "Error: --spec or --graph is required." >&2
	usage >&2
	exit 1
fi

if [[ -n "${SPEC_FILE}" && -n "${GRAPH_IN}" ]]; then
	echo "Error: --spec and --graph are mutually exclusive." >&2
	exit 1
fi

if [[ -z "${TARGET_REPO}" ]]; then
	echo "Error: --target is required." >&2
	usage >&2
	exit 1
fi

TARGET_REPO="$(abs_path "${TARGET_REPO}")"

if [[ -n "${SPEC_FILE}" ]]; then
	SPEC_FILE="$(abs_path "${SPEC_FILE}")"
	if [[ ! -f "${SPEC_FILE}" && ! -d "${SPEC_FILE}" ]]; then
		echo "Error: spec path not found (file or directory): ${SPEC_FILE}" >&2
		exit 1
	fi
fi

if [[ -n "${GRAPH_IN}" ]]; then
	GRAPH_IN="$(abs_path "${GRAPH_IN}")"
	if [[ ! -f "${GRAPH_IN}" ]]; then
		echo "Error: graph file not found: ${GRAPH_IN}" >&2
		exit 1
	fi
fi

if [[ ! -d "${KILROY_DIR}" ]]; then
	echo "Error: expected kilroy checkout at ${KILROY_DIR}" >&2
	exit 1
fi

if [[ ! -f "${MODELDB_PATH}" ]]; then
	echo "Error: missing modeldb file at ${MODELDB_PATH}" >&2
	exit 1
fi

for cmd in docker go git curl; do
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		echo "Error: ${cmd} is required." >&2
		exit 1
	fi
done

mkdir -p "${TARGET_REPO}"

if [[ ! -d "${TARGET_REPO}/.git" ]]; then
	echo "Initializing git repository at ${TARGET_REPO}..."
	git -C "${TARGET_REPO}" init >/dev/null
fi

if ! git -C "${TARGET_REPO}" rev-parse --verify HEAD >/dev/null 2>&1; then
	echo "Creating initial commit in ${TARGET_REPO}..."
	git -C "${TARGET_REPO}" commit --allow-empty -m "Initial commit" >/dev/null
fi

mkdir -p "${TARGET_REPO}/.kilroy"

if [[ -z "${GRAPH_OUT}" ]]; then
	GRAPH_OUT="${TARGET_REPO}/.kilroy/pipeline.dot"
else
	GRAPH_OUT="$(abs_path "${GRAPH_OUT}")"
	mkdir -p "$(dirname "${GRAPH_OUT}")"
fi

RUN_CONFIG_PATH="${TARGET_REPO}/.kilroy/run.yaml"

echo "[1/6] Starting CXDB..."
docker compose -f "${COMPOSE_FILE}" up -d cxdb

echo "[2/6] Waiting for CXDB health endpoint..."
until curl -fsS "http://127.0.0.1:9010/v1/contexts?limit=1" >/dev/null 2>&1; do
	sleep 1
done

pushd "${KILROY_DIR}" >/dev/null

echo "[3/6] Building kilroy binary..."
KILROY_REV="$(git rev-parse HEAD)"
go build -ldflags "-X main.embeddedBuildRevision=${KILROY_REV}" -o ./kilroy ./cmd/kilroy

MAX_VALIDATE_RETRIES=3
VALIDATE_ATTEMPT=0

if [[ -n "${GRAPH_IN}" ]]; then
	echo "[4/6] Using provided DOT graph: ${GRAPH_IN}"
	cp "${GRAPH_IN}" "${GRAPH_OUT}"
	SPEC_TEXT="$(cat "${GRAPH_IN}")"
else
	echo "[4/6] Generating DOT graph from markdown spec..."
	if [[ -d "${SPEC_FILE}" ]]; then
		SPEC_TEXT=""
		while IFS= read -r -d '' md_file; do
			SPEC_TEXT+="$(cat "${md_file}")"
			SPEC_TEXT+=$'\n\n'
		done < <(find "${SPEC_FILE}" -name '*.md' -type f -print0 | sort -z)

		if [[ -z "${SPEC_TEXT}" ]]; then
			echo "Error: no .md files found in directory: ${SPEC_FILE}" >&2
			exit 1
		fi
		echo "  Concatenated $(find "${SPEC_FILE}" -name '*.md' -type f | wc -l | tr -d ' ') .md files from ${SPEC_FILE}"
	else
		SPEC_TEXT="$(cat "${SPEC_FILE}")"
		if [[ -z "${SPEC_TEXT}" ]]; then
			echo "Error: spec file is empty: ${SPEC_FILE}" >&2
			exit 1
		fi
	fi

	./kilroy attractor ingest --repo "${TARGET_REPO}" -o "${GRAPH_OUT}" "${SPEC_TEXT}"
fi

echo "[5/6] Validating graph..."
while true; do
	VALIDATE_OUTPUT="$(./kilroy attractor validate --graph "${GRAPH_OUT}" 2>&1)" && break

	VALIDATE_ATTEMPT=$((VALIDATE_ATTEMPT + 1))
	if [[ ${VALIDATE_ATTEMPT} -ge ${MAX_VALIDATE_RETRIES} ]]; then
		echo "Error: graph failed validation after ${MAX_VALIDATE_RETRIES} repair attempts:" >&2
		echo "${VALIDATE_OUTPUT}" >&2
		exit 1
	fi

	echo "  Validation failed (attempt ${VALIDATE_ATTEMPT}/${MAX_VALIDATE_RETRIES}), feeding errors back to ingest..."
	echo "  Errors: ${VALIDATE_OUTPUT}"

	REPAIR_PROMPT="The following DOT graph failed kilroy attractor validation. Fix the graph so it passes validation.

VALIDATION ERRORS:
${VALIDATE_OUTPUT}

CURRENT GRAPH:
$(cat "${GRAPH_OUT}")

ORIGINAL REQUIREMENTS:
${SPEC_TEXT}

Produce a corrected DOT graph that resolves all validation errors while preserving the original intent."

	./kilroy attractor ingest --repo "${TARGET_REPO}" -o "${GRAPH_OUT}" "${REPAIR_PROMPT}"
done
echo "  Graph validated successfully."

CONFIG_TEMPLATE="${ROOT_DIR}/run-config.template.yaml"
if [[ ! -f "${CONFIG_TEMPLATE}" ]]; then
	echo "Error: config template not found: ${CONFIG_TEMPLATE}" >&2
	exit 1
fi

sed \
	-e "s|__TARGET_REPO__|${TARGET_REPO}|g" \
	-e "s|__MODELDB_PATH__|${MODELDB_PATH}|g" \
	"${CONFIG_TEMPLATE}" > "${RUN_CONFIG_PATH}"

if ${USE_BEDROCK}; then
	sed -i '' 's|__ANTHROPIC_BACKEND__|api|' "${RUN_CONFIG_PATH}"
else
	sed -i '' -e 's|__ANTHROPIC_BACKEND__|cli|' \
		-e '/^      api:$/,/^      [^ ]/{ /^      api:/d; /^        /d; }' \
		"${RUN_CONFIG_PATH}"
fi

if ${USE_BEDROCK}; then
	export LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-local-dev-master-key}"
fi

# Prevent git from opening an interactive editor for merge commits,
# which would block headless pipeline runs indefinitely.
export GIT_MERGE_AUTOEDIT=no

echo "[6/6] Running build pipeline..."
RUN_OUTPUT="$(./kilroy attractor run --skip-cli-headless-warning --graph "${GRAPH_OUT}" --config "${RUN_CONFIG_PATH}")"
echo "${RUN_OUTPUT}"

RUN_BRANCH="$(printf '%s\n' "${RUN_OUTPUT}" | sed -n 's/^run_branch=//p' | tail -n 1)"

if [[ -n "${RUN_BRANCH}" ]]; then
	git -C "${TARGET_REPO}" branch -f "${OUTPUT_BRANCH}" "${RUN_BRANCH}" >/dev/null
	git -C "${TARGET_REPO}" checkout "${OUTPUT_BRANCH}" >/dev/null
	echo "Generated code is available at ${TARGET_REPO} on branch ${OUTPUT_BRANCH}."
	echo "Graph written to ${GRAPH_OUT}."
else
	echo "Warning: run_branch was not found in run output; skipping output branch checkout." >&2
fi

popd >/dev/null

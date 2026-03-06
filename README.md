# Kilroy Docker POC

A proof-of-concept that turns a markdown specification into a working codebase using the Kilroy attractor pipeline. The factory ingests a spec, generates a DOT build graph, validates it, and executes the graph to produce code in a target repository.

## Dependencies

| Dependency | Purpose |
|---|---|
| **Docker & Docker Compose** | Runs CXDB (context database) and the LiteLLM Bedrock proxy |
| **Go** (1.22+) | Builds the `kilroy` binary |
| **Git** | Manages target repository branches and commits |
| **AWS CLI v2** | Configuring named profiles for Bedrock access |
| **curl** | Health-checks for CXDB and LiteLLM |
| **Claude CLI** *(optional)* | Used by `kilroy attractor ingest` when converting a spec to a DOT graph |

### AWS Configuration

The Bedrock proxy uses your local AWS CLI configuration (`~/.aws/config` and `~/.aws/credentials`) mounted read-only into the container. boto3 handles STS role assumption and automatic credential refresh — no manual token management required.

You need an AWS CLI **named profile** configured with `role_arn` and `source_profile`. For example:

```ini
# ~/.aws/config
[profile staging]
role_arn = arn:aws:iam::123456789012:role/my-role
source_profile = default
```

Copy the example `.env` file and set the profile name:

```bash
cp .env.example .env
```

```dotenv
AWS_PROFILE=staging
AWS_REGION=us-east-1
```

`run-from-spec.sh` automatically sources `.env` when it exists. The file is gitignored so configuration stays local.

## Getting Started — Two Steps

### 1. Write or Provide a Spec / DOT File

Create a markdown specification describing the software you want to build, **or** supply a pre-built DOT pipeline graph.

```
# Example: a simple spec file
echo "# My App\nBuild a REST API that ..." > spec.md
```

### 2. Run the Factory

Pass the spec (or graph) and a target directory to `run-from-spec.sh`. The script automatically starts CXDB and the Bedrock proxy (with auto-refreshing AWS credentials):

```bash
# From a markdown spec — generates and validates a DOT graph, then executes it
./run-from-spec.sh --spec ./spec.md --target ../my-new-project

# From a directory of markdown files
./run-from-spec.sh --spec ./specs/ --target ../my-new-project

# From a pre-existing DOT graph
./run-from-spec.sh --graph ./pipeline.dot --target ../my-new-project

# Skip Bedrock (use local Anthropic/OpenAI/Google CLI providers instead)
./run-from-spec.sh --spec ./spec.md --target ../my-new-project --no-bedrock
```

The script will:

1. Start CXDB
2. Build the `kilroy` binary
3. Generate a DOT pipeline from the spec (or copy the provided graph)
4. Validate the graph (auto-repairs up to 3 times on failure)
5. Execute the pipeline against the target repo
6. Check out the generated code on the `generated-output` branch

When it finishes, `cd` into your target directory and inspect the result:

```bash
cd ../my-new-project
git log --oneline
```

## Monitoring

Both CXDB and LiteLLM expose web UIs for monitoring while the factory is running:

| Service | URL | Notes |
|---|---|---|
| **CXDB UI** | [http://localhost:9011](http://localhost:9011) | Browse contexts, turns, and stored blobs |
| **LiteLLM UI** | [http://localhost:4000/ui](http://localhost:4000/ui) | View model usage, request logs, and spend — login with `admin` / `changeme` (configurable via `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD`) |

## Project Layout

```
.
├── run-from-spec.sh              # End-to-end factory runner
├── run-config.template.yaml      # Kilroy run config (templated)
├── docker-compose.yml            # CXDB, LiteLLM proxy, Postgres
├── bedrock/
│   └── litellm.config.yaml       # LiteLLM model routing (Claude via Bedrock)
├── kilroy/                        # Kilroy source (submodule / checkout)
├── cxdb/                          # CXDB source (submodule / checkout)
└── data/cxdb/                     # Persistent CXDB data volume
```

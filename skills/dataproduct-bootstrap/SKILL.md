---
name: dataproduct-bootstrap
description: Bootstrap a brand-new Databricks (Unity Catalog) dbt data product from scratch in one go — dbt_project.yml, generate_schema_name macro, model layout, README, .gitignore, profiles.yml.example for Databricks, ODPS, output-port ODCS, openlineage.yml, and a GitHub Actions workflow. Trigger when the user asks to start a new data product, scaffold a new dbt project, or "create a Databricks data product from scratch."
---

# Bootstrap a new Databricks dbt data product (demo)

Scaffold a Databricks-only dbt data product following the Entropy Data conventions and the Unity Catalog naming convention below. Demo-grade: one batched question, one platform, no audits, no migration logic.

For populating the contract schema and dbt model bodies from a published data product, use the **dataproduct-implement** skill after this one.

## Unity Catalog naming convention

| Object | Convention | Example |
|---|---|---|
| Catalog | the organization's catalog | `acme_prod` |
| Output-port schema | the output-port id = the contract id (ends in `_v<N>`) | `customers_v1` |
| Output-port table | the contract id without the `_v<N>` suffix | `customers` |
| Internal schema | `<DATA_PRODUCT_ID>_internal` — staging + intermediate, never granted to consumers | `dp_customers_internal` |
| Input ports | `<catalog>.<upstream-output-port-id>.<table>` as dbt sources | `acme_prod.orders_v2.orders` |

`macros/generate_schema_name.sql` makes dbt take `+schema` / `config(schema=...)` literally, so the output-port model lands in `customers_v1` rather than `<target_schema>_customers_v1`.

## What this skill produces

After running, the directory contains:

```
.
├── dbt_project.yml
├── .gitignore
├── .dbtignore
├── README.md
├── profiles.yml.example
├── <data-product-id>.odps.yaml
├── openlineage.yml
├── .github/workflows/data-product.yml
├── macros/generate_schema_name.sql
└── models/
    ├── input_ports/_models.yml
    ├── staging/_models.yml
    ├── intermediate/_models.yml
    └── output_ports/v1/
        ├── _models.yml
        └── <contract-id>.odcs.yaml
```

## How to run this skill

> `${PLUGIN_ROOT}` below refers to the root of this plugin — the directory that contains `skills/`. On Claude Code it is set automatically as `${CLAUDE_PLUGIN_ROOT}`; use that. On any other agent (Codex, Copilot CLI, etc.) it is unset; resolve it as `../..` relative to **this `SKILL.md` file's directory** (i.e. the grandparent of `skills/<this-skill>/`).

### Plan announcement (before Step 1)

Before running Step 1, print this plan to the user verbatim:

> Running **dataproduct-bootstrap**. I'll:
> 1. Pre-check: confirm the working directory is empty.
> 2. Ask you for parameters in one batched question (id, name, purpose, team, Unity Catalog catalog, output-port id, Databricks host + SQL warehouse HTTP path).
> 3. Scaffold the dbt project (dbt_project.yml, generate_schema_name macro, profiles.yml.example, model layout, README, .gitignore).
> 4. Scaffold the publishing layer (ODPS, output-port ODCS, openlineage.yml, GitHub Actions workflow).
> 5. Summarize what was scaffolded and the next manual steps.

Then proceed.

### Step 1 — Pre-checks

- Confirm the working directory is empty, or contains only files the user is fine with (e.g. an empty git repo, a `LICENSE`, or a placeholder `README.md` that will be overwritten).
- If `dbt_project.yml` already exists, stop and tell the user this demo skill only handles greenfield directories. Point them at `dataproduct-implement` to add models to an existing project.

### Step 2 — Gather parameters in one batched question

Ask the user for these in a single prompt. Do not generate any files until you have all of them. Pre-fill `DATABRICKS_HOST` / `DATABRICKS_HTTP_PATH` as suggested defaults when those env vars are already set in the shell.

| Parameter | Description | Example |
|---|---|---|
| `DATA_PRODUCT_ID` | Stable id, snake_case, also the dbt project name | `dp_customers` |
| `DATA_PRODUCT_NAME` | Human-friendly name | `Customers` |
| `PURPOSE` | One sentence — why this data product exists | `Customer master data for customer success.` |
| `TEAM_NAME` | Owning team id (free-text accepted for the demo) | `customer-success` |
| `CATALOG` | Unity Catalog catalog (the organization's catalog) | `acme_prod` |
| `OUTPUT_PORT_ID` | First output port id = contract id = UC schema. snake_case, must end in `_v1` | `customers_v1` |
| `DATABRICKS_HOST` | Workspace hostname, **without** `https://` | `adb-1234567890123456.7.azuredatabricks.net` |
| `DATABRICKS_HTTP_PATH` | SQL warehouse HTTP path (not secret) | `/sql/1.0/warehouses/abc123def456` |

Validate: `DATA_PRODUCT_ID`, `CATALOG`, and `OUTPUT_PORT_ID` must match `^[a-z][a-z0-9_]*$` (Unity Catalog identifiers without quoting); `OUTPUT_PORT_ID` must match `_v1$`. Strip a leading `https://` and trailing `/` from `DATABRICKS_HOST`. If a value is invalid, ask again for that value only.

Derive:

- `DBT_PROJECT_NAME` = `DBT_PROFILE` = `DATA_PRODUCT_ID`
- `CONTRACT_ID` = `OUTPUT_PORT_ID` (e.g. `customers_v1`)
- `SCHEMA` = `OUTPUT_PORT_ID` (the output-port schema in Unity Catalog)
- `TABLE` = `OUTPUT_PORT_ID` with the trailing `_v<N>` removed (e.g. `customers`)
- `INTERNAL_SCHEMA` = `<DATA_PRODUCT_ID>_internal`
- `CONTRACT_FILE` = `<CONTRACT_ID>.odcs.yaml`
- `CONTRACT_PATH` = `models/output_ports/v1/<CONTRACT_FILE>`
- `ODPS_FILE` = `<DATA_PRODUCT_ID>.odps.yaml`

Resolve `API_HOST` from the entropy-data CLI connection: `entropy-data connection get -o json` → `host`. If the CLI is not connected, stop and tell the user to run `entropy-data connection add <name> --host <host> --api-key <key>` first. The demo does not run without a working connection.

Always use the `entropy-data` CLI for any connection to Entropy Data. Do not use the Entropy Data MCP server.

### Step 3 — Scaffold the project

Templates live under `${PLUGIN_ROOT}/skills/dataproduct-bootstrap/templates/`. Copy each one into the working directory, substituting placeholders.

**Placeholder rule:** substitute only `{{UPPER_SNAKE_CASE}}` tokens (e.g. `{{CATALOG}}`). Leave dbt Jinja such as `{{ env_var('DATABRICKS_HOST') }}` / `{{ config(...) }}` and GitHub Actions expressions such as `${{ secrets.X }}` untouched.

| Template | Destination |
|---|---|
| `dbt_project.yml` | `dbt_project.yml` |
| `.gitignore` | `.gitignore` |
| `.dbtignore` | `.dbtignore` (keeps dbt from parsing `*.odcs.yaml` as schema files) |
| `README.md` | `README.md` |
| `profiles.yml.example` | `profiles.yml.example` |
| `macros/generate_schema_name.sql` | `macros/generate_schema_name.sql` |
| `data-product.odps.yaml` | `<DATA_PRODUCT_ID>.odps.yaml` |
| `openlineage.yml` | `openlineage.yml` |
| `models/input_ports/_models.yml` | `models/input_ports/_models.yml` |
| `models/staging/_models.yml` | `models/staging/_models.yml` |
| `models/intermediate/_models.yml` | `models/intermediate/_models.yml` |
| `models/output_ports/v1/_models.yml` | `models/output_ports/v1/_models.yml` |
| `models/output_ports/v1/contract.odcs.yaml` | `<CONTRACT_PATH>` |
| `.github/workflows/data-product.yml` | `.github/workflows/data-product.yml` |

Also create empty `analyses/`, `seeds/`, `snapshots/`, `tests/` directories with a `.gitkeep` each (`macros/` already has the schema macro).

### Step 4 — Final report

End with this two-part recap. Use the `Status` enum: `created`, `already present`, `skipped`.

**Part 1 — outcome table.**

| Artifact | Status | Details |
|---|---|---|
| `dbt_project.yml` | … | profile = `<DBT_PROJECT_NAME>`, Databricks adapter, Delta tables |
| `macros/generate_schema_name.sql` | … | literal custom schemas |
| `profiles.yml.example` | … | Databricks, catalog `<CATALOG>`, credentials from env vars |
| `README.md` | … | written |
| `.gitignore` / `.dbtignore` | … | written |
| Model layout | … | `models/{input_ports,staging,intermediate,output_ports/v1}/` |
| ODPS | … | `<DATA_PRODUCT_ID>.odps.yaml` |
| Output-port contract | … | `<CONTRACT_PATH>` → `<CATALOG>.<SCHEMA>.<TABLE>` (schema seeded with `id` + `updated_at`) |
| `openlineage.yml` | … | transport pointed at `<API_HOST>` |
| GitHub Actions workflow | … | `.github/workflows/data-product.yml` |

**Part 2 — next steps.** Bullet list:

- `uv venv && source .venv/bin/activate && uv pip install dbt-core dbt-databricks openlineage-dbt 'datacontract-cli[databricks]' entropy-data`
- This demo assumes `~/.dbt/profiles.yml` already has a working Databricks target for profile `<DBT_PROJECT_NAME>`. `profiles.yml.example` is checked in as a reference (all credentials via `DATABRICKS_HOST` / `DATABRICKS_HTTP_PATH` / `DATABRICKS_TOKEN`, or `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` for OAuth M2M).
- Make sure the principal running dbt can `USE CATALOG <CATALOG>` and `CREATE SCHEMA` on it (or that `<CATALOG>.<SCHEMA>` and `<CATALOG>.<INTERNAL_SCHEMA>` already exist with `CREATE TABLE` / `CREATE VIEW` rights).
- Set `OPENLINEAGE__TRANSPORT__AUTH__APIKEY=<your-entropy-data-api-key>` so `dbt-ol run` can publish lineage immediately.
- `git init && git add . && git commit -m "Initial commit"`, then push to GitHub.
- Set GitHub repository secrets for the workflow: `ENTROPY_DATA_API_KEY`, `DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET` (a service principal with an OAuth secret).
- Run **dataproduct-implement** next to generate models from a published data product, run dbt, run dbt + datacontract tests, and ship the first lineage event.

## Constraints

- **Databricks-only.** This demo plugin intentionally drops platform branching. If the user asks for Snowflake, point them at https://github.com/entropy-data/dataproduct-builder-demo; for BigQuery/Postgres, at the full builder at https://github.com/entropy-data/dataproduct-builder-dbt.
- **Greenfield only.** If `dbt_project.yml` exists, stop.
- **Do not run `dbt init`.** Use the templates here.
- **Do not commit secrets.** `profiles.yml` is in `.gitignore`; only `profiles.yml.example` (env-var based) is checked in. Host and HTTP path are not secrets; tokens and client secrets are.
- **Do not run `git init`, `git commit`, or `git push`** — surface them as next steps.
- **Idempotent.** Re-running on an already-populated directory is a no-op (refuse if anything would be overwritten).

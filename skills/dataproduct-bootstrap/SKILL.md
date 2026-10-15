---
name: dataproduct-bootstrap
description: Bootstrap a brand-new Databricks (Unity Catalog) dbt data product from scratch in one go — dbt_project.yml, generate_schema_name macro, model layout, README, .gitignore, profiles.yml(.example) for Databricks, ODPS, output-port ODCS, openlineage.yml, and a GitHub Actions workflow. Reuses the data product and contract when they are already published on Entropy Data. Trigger when the user asks to start a new data product, scaffold a new dbt project, or "create a Databricks data product from scratch."
---

# Bootstrap a new Databricks dbt data product (demo)

Scaffold a Databricks-only dbt data product following the Entropy Data conventions and the Unity Catalog naming convention below. Demo-grade: one batched question, one platform, no audits, no migration logic.

If the data product is **already published** on Entropy Data (the usual demo flow: the product and its contract were designed in the web UI first), this skill takes name, purpose, team, output ports, and the output-port contract from there and only asks for what Entropy Data cannot know (the SQL warehouse HTTP path, and host / catalog if the contract has no Databricks server).

For populating the contract schema and dbt model bodies from a published data product, use the **dataproduct-implement** skill after this one.

## Unity Catalog naming convention

| Object | Convention | Example |
|---|---|---|
| Catalog | the organization's catalog | `acme_prod` |
| Output-port schema | the output-port id = the contract id (ends in `_v<N>`) | `customers_v1` |
| Output-port table | the contract id without the `_v<N>` suffix | `customers` |
| Internal schema | `<DBT_NAME>_internal` — staging + intermediate, never granted to consumers | `customers_internal` |
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
├── profiles.yml                  (gitignored, env_var() references only)
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
> 1. Pre-check: confirm the working directory is empty and the `entropy-data` CLI is connected.
> 2. Look the data product up on Entropy Data; if it is published, reuse its name, purpose, team, output port, and data contract.
> 3. Ask you for the remaining parameters in one batched question (only what Entropy Data doesn't already know — at least the SQL warehouse HTTP path).
> 4. Scaffold the dbt project (dbt_project.yml, generate_schema_name macro, profiles.yml + profiles.yml.example, model layout, README, .gitignore).
> 5. Scaffold the publishing layer (ODPS, output-port ODCS — the published ones when they exist, openlineage.yml, GitHub Actions workflow).
> 6. Summarize what was scaffolded and the next manual steps.

Then proceed.

### Step 1 — Pre-checks

- Confirm the working directory is empty, or contains only files the user is fine with (e.g. an empty git repo, a `LICENSE`, or a placeholder `README.md` that will be overwritten).
- If `dbt_project.yml` already exists, stop and tell the user this demo skill only handles greenfield directories. Point them at `dataproduct-implement` to add models to an existing project.
- Confirm `entropy-data connection test` succeeds and resolve `API_HOST` = `entropy-data connection get -o json | jq -r .host` (no trailing `/`). If the CLI is not connected, stop and tell the user to run `entropy-data connection add <name> --host <host> --api-key <key>` first. The demo does not run without a working connection.

Always use the `entropy-data` CLI for any connection to Entropy Data. Do not use the Entropy Data MCP server.

### Step 2 — Reuse what is already published

If the user's request names a data product (id or URL `https://<app>/<org>/dataproducts/<id>` — take the trailing id), run `entropy-data dataproducts get <id> -o yaml`. Entropy Data ids are usually kebab-case (`regional-score-statistics`); use the id **exactly as published** for every Entropy Data call. If the request names none, skip to Step 3 and repeat this lookup with the id the user answers.

If the lookup succeeds, remember the YAML as `PUBLISHED_ODPS` and take:

- `DATA_PRODUCT_NAME` = `.name`, `PURPOSE` = `.description.purpose`, `TEAM_NAME` = `.team.name // .team.id`.
- The output port: the first entry of `.outputPorts` with `type: databricks` (else the first one). `OUTPUT_PORT_ID` = its `.id // .name`, `CONTRACT_ID` = its `.contractId`. If there are several output ports, scaffold the first and tell the user `dataproduct-implement` handles the others.

If `CONTRACT_ID` is set, run `entropy-data datacontracts get <CONTRACT_ID> -o yaml`. If that succeeds, remember it as `PUBLISHED_CONTRACT` and take from its Databricks server (`servers[]` with `type: databricks`; prefer `environment` `prod` / `production`, then server name `prod` / `production`, then the first one):

- `CONTRACT_SERVER` = `.server`, `DATABRICKS_HOST` = `.host`, `CATALOG` = `.catalog`, `SCHEMA` = `.schema`, and `DATABRICKS_HTTP_PATH` from a `customProperties` entry `httpPath` if present.
- `TABLE` = `schema[0].physicalName // schema[0].name`.

Anything published wins over defaults; do not ask for it again.

### Step 3 — Gather the missing parameters in one batched question

Ask the user, in a single prompt, for **only the parameters not resolved in Step 2** (with a published data product and contract that is typically just `DATABRICKS_HTTP_PATH`). Do not generate any files until you have all of them. Pre-fill `DATABRICKS_HOST` / `DATABRICKS_HTTP_PATH` as suggested defaults when those env vars are already set in the shell. If everything is already known, skip the question and state the values you will use.

| Parameter | Description | Example |
|---|---|---|
| `DATA_PRODUCT_ID` | Entropy Data id, kebab-case or snake_case | `customers` / `regional-score-statistics` |
| `DATA_PRODUCT_NAME` | Human-friendly name | `Customers` |
| `PURPOSE` | One sentence — why this data product exists | `Customer master data for customer success.` |
| `TEAM_NAME` | Owning team id (free-text accepted for the demo) | `customer-success` |
| `CATALOG` | Unity Catalog catalog (the organization's catalog) | `acme_prod` |
| `OUTPUT_PORT_ID` | First output port id = contract id = UC schema. snake_case, must end in `_v1` | `customers_v1` |
| `DATABRICKS_HOST` | Workspace hostname, **without** `https://` | `adb-1234567890123456.7.azuredatabricks.net` |
| `DATABRICKS_HTTP_PATH` | SQL warehouse HTTP path (not secret) | `/sql/1.0/warehouses/abc123def456` |

If the user supplied `DATA_PRODUCT_ID` only now, run the Step 2 lookup with it; if it is published, the published values replace the answers (say so) and the contract is fetched as in Step 2.

Validate: `DATA_PRODUCT_ID` must match `^[a-z][a-z0-9_-]*$`; `CATALOG` and `OUTPUT_PORT_ID` must match `^[a-z][a-z0-9_]*$` (Unity Catalog identifiers without quoting); a new `OUTPUT_PORT_ID` must match `_v1$` (published ones are taken as they are). Strip a leading `https://` and trailing `/` from `DATABRICKS_HOST`. If a value is invalid, ask again for that value only.

Derive (unless resolved in Step 2):

- `DBT_NAME` = `DATA_PRODUCT_ID` lower-cased with every character outside `[a-z0-9_]` replaced by `_` (e.g. `regional-score-statistics` → `regional_score_statistics`). Used as dbt project name and dbt profile name — dbt and Unity Catalog need snake_case; Entropy Data keeps the original id.
- `CONTRACT_ID` = `OUTPUT_PORT_ID` (e.g. `customers_v1`)
- `SCHEMA` = `OUTPUT_PORT_ID` (the output-port schema in Unity Catalog)
- `TABLE` = `OUTPUT_PORT_ID` with the trailing `_v<N>` removed (e.g. `customers`)
- `CONTRACT_SERVER` = `production` (the server name in the stub contract)
- `INTERNAL_SCHEMA` = `<DBT_NAME>_internal`
- `CONTRACT_FILE` = `<CONTRACT_ID>.odcs.yaml`
- `CONTRACT_PATH` = `models/output_ports/v1/<CONTRACT_FILE>`
- `ODPS_FILE` = `<DATA_PRODUCT_ID>.odps.yaml`

### Step 4 — Scaffold the project

Templates live under `${PLUGIN_ROOT}/skills/dataproduct-bootstrap/templates/`. Copy each one into the working directory, substituting placeholders.

**Placeholder rule:** substitute only `{{UPPER_SNAKE_CASE}}` tokens (e.g. `{{CATALOG}}`). Leave dbt Jinja such as `{{ env_var('DATABRICKS_HOST') }}` / `{{ config(...) }}` and GitHub Actions expressions such as `${{ secrets.X }}` untouched.

| Template | Destination |
|---|---|
| `dbt_project.yml` | `dbt_project.yml` |
| `.gitignore` | `.gitignore` |
| `.dbtignore` | `.dbtignore` (keeps dbt from parsing `*.odcs.yaml` as schema files) |
| `README.md` | `README.md` |
| `profiles.yml.example` | `profiles.yml.example` **and** `profiles.yml` (same content: `env_var()` references only, no secrets; gitignored) |
| `macros/generate_schema_name.sql` | `macros/generate_schema_name.sql` |
| `data-product.odps.yaml` | `<ODPS_FILE>` — **only if not published.** If `PUBLISHED_ODPS` exists, write it verbatim instead: `entropy-data dataproducts get <DATA_PRODUCT_ID> -o yaml > <ODPS_FILE>` (CI's `dataproducts put` publishes this file, so a stub would overwrite the richer published product) |
| `openlineage.yml` | `openlineage.yml` |
| `models/input_ports/_models.yml` | `models/input_ports/_models.yml` |
| `models/staging/_models.yml` | `models/staging/_models.yml` |
| `models/intermediate/_models.yml` | `models/intermediate/_models.yml` |
| `models/output_ports/v1/_models.yml` | `models/output_ports/v1/_models.yml` |
| `models/output_ports/v1/contract.odcs.yaml` | `<CONTRACT_PATH>` — **only if not published.** If `PUBLISHED_CONTRACT` exists, write it verbatim instead: `entropy-data datacontracts get <CONTRACT_ID> -o yaml > <CONTRACT_PATH>` (no stub that `dataproduct-implement` would have to overwrite) |
| `.github/workflows/data-product.yml` | `.github/workflows/data-product.yml` |

Also create empty `analyses/`, `seeds/`, `snapshots/`, `tests/` directories with a `.gitkeep` each (`macros/` already has the schema macro).

The stub templates start with a `# dataproduct-builder:stub` comment. Keep it in stub files (`dataproduct-implement` replaces marked files without asking) and never add it to files written from Entropy Data.

All dbt commands in this project run with `--profiles-dir .` so the project-local `profiles.yml` is used, never `~/.dbt/profiles.yml`.

### Step 5 — Final report

End with this two-part recap. Use the `Status` enum: `created`, `already present`, `skipped`.

**Part 1 — outcome table.**

| Artifact | Status | Details |
|---|---|---|
| `dbt_project.yml` | … | project / profile = `<DBT_NAME>`, Databricks adapter, Delta tables |
| `macros/generate_schema_name.sql` | … | literal custom schemas |
| `profiles.yml` / `profiles.yml.example` | … | Databricks, catalog `<CATALOG>`, credentials from env vars; `profiles.yml` gitignored |
| `README.md` | … | written |
| `.gitignore` / `.dbtignore` | … | written |
| Model layout | … | `models/{input_ports,staging,intermediate,output_ports/v1}/` |
| ODPS | … | `<ODPS_FILE>` — "from Entropy Data" / "stub" |
| Output-port contract | … | `<CONTRACT_PATH>` → `<CATALOG>.<SCHEMA>.<TABLE>`, server `<CONTRACT_SERVER>` — "from Entropy Data" / "stub (`id` + `updated_at`)" |
| `openlineage.yml` | … | transport pointed at `<API_HOST>` |
| GitHub Actions workflow | … | `.github/workflows/data-product.yml` |

**Part 2 — next steps.** Bullet list:

- Tools run via uv, nothing to install into the project: `uvx --python 3.12 --from dbt-core --with dbt-databricks dbt`, `uvx --python 3.12 --from openlineage-dbt --with dbt-databricks dbt-ol`, `uv tool run --from 'datacontract-cli[databricks]' datacontract` (see the README's aliases).
- Databricks credentials, read by `profiles.yml` from env vars (`--profiles-dir .`): `DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, and either `DATABRICKS_TOKEN` (PAT or Azure AD token, target `dev`) or `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` (writer service principal, target `prod`).
- **dbt writes, `datacontract test` only reads.** The principal running dbt needs `USE CATALOG <CATALOG>` + `CREATE SCHEMA` on it (or pre-created `<CATALOG>.<SCHEMA>` and `<CATALOG>.<INTERNAL_SCHEMA>` with `CREATE TABLE` / `CREATE VIEW`) and `SELECT` on the input ports. A read-only service principal is enough for `datacontract test`.
- `export ENTROPY_DATA_API_KEY=<your-entropy-data-api-key>` — `dataproduct-implement` uses it for the OpenLineage transport, and the contract lint hook needs it to resolve semantic references.
- For you to run (the agent leaves version control to you): `git init && git add . && git commit -m "Initial commit"`, then push to GitHub.
- Set GitHub repository secrets for the workflow: `ENTROPY_DATA_API_KEY`, `DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET` (a writer service principal with a Databricks OAuth secret).
- Run **dataproduct-implement** next to generate models from the published data product, run dbt, run dbt + datacontract tests, and ship the first lineage event.

## Constraints

- **Databricks-only.** This demo plugin intentionally drops platform branching. If the user asks for Snowflake, point them at https://github.com/entropy-data/dataproduct-builder-demo; for BigQuery/Postgres, at the full builder at https://github.com/entropy-data/dataproduct-builder-dbt.
- **Greenfield only.** If `dbt_project.yml` exists, stop.
- **Do not run `dbt init`.** Use the templates here.
- **Do not commit secrets.** `profiles.yml` is in `.gitignore` and, like `profiles.yml.example`, only holds `env_var()` references. Host and HTTP path are not secrets; tokens and client secrets are. Never print API keys or tokens.
- **Published metadata wins.** Never write a stub ODPS or contract when Entropy Data already has the real one.
- **Do not run `git init`, `git commit`, or `git push`** — list them as next steps for the user.
- **Idempotent.** Re-running on an already-populated directory is a no-op (refuse if anything would be overwritten).

---
name: dataproduct-implement
description: Given an Entropy Data data product URL or id, fetch its ODCS, derive and generate Databricks (Unity Catalog) dbt models, run dbt-ol (ship lineage to Entropy Data on the spot), run dbt tests, run datacontract tests, and mark the output port live on Entropy Data — end-to-end in one go. Demo-grade. Trigger when the user asks to "implement the data product <url>", "build the dbt pipeline for this data product", or "scaffold dbt models from a data contract".
---

# Implement a data product from its data contract (demo)

Turn an Entropy Data data product into a working Databricks dbt pipeline and prove it works — in one pass. The data contract (ODCS) is the source of truth for the output schema; the data product's purpose, the contract's descriptions and quality rules, and the input-port contracts define the transformation. This skill reads them, writes dbt artifacts that produce data matching the contract, runs everything against your Databricks SQL warehouse, and ships an OpenLineage event so the pipeline shows up in Entropy Data immediately.

Unity Catalog naming convention (see `dataproduct-bootstrap`): catalog = the organization's catalog; one schema per output port named after the output-port / contract id (`customers_v1`); table = contract id without `_v<N>` (`customers`); staging/intermediate in `<DBT_NAME>_internal`, where `DBT_NAME` is the dbt project name (the data product id in snake_case, e.g. `regional-score-statistics` → `regional_score_statistics`); upstream data products are read from `<catalog>.<upstream-output-port-id>.<table>`.

## When to use this vs. other skills

- **Empty directory, no dbt project yet** → run `dataproduct-bootstrap` first, then come back here.
- **Existing dbt project, want to derive Databricks models from a published data contract and prove the pipeline works** → this skill.

## How to run this skill

> `${PLUGIN_ROOT}` below refers to the root of this plugin — the directory that contains `skills/`. On Claude Code it is set automatically as `${CLAUDE_PLUGIN_ROOT}`; use that. On any other agent (Codex, Copilot CLI, etc.) it is unset; resolve it as `../..` relative to **this `SKILL.md` file's directory** (i.e. the grandparent of `skills/<this-skill>/`).

**Tool invocations.** The tools run through uv, pinned to Python 3.12 (newer Pythons print Pydantic V1 warnings). Below, `dbt`, `dbt-ol`, and `datacontract` mean exactly:

| Short name | Command |
|---|---|
| `dbt` | `uvx --python 3.12 --from dbt-core --with dbt-databricks dbt` |
| `dbt-ol` | `uvx --python 3.12 --from openlineage-dbt --with dbt-databricks dbt-ol` |
| `datacontract` | `uv tool run --from 'datacontract-cli[databricks]' datacontract` |

Every `dbt` / `dbt-ol` call runs from the project root with `--profiles-dir .` (the project-local, gitignored `profiles.yml`).

### Plan announcement (before Step 0)

Before running Step 0, print this plan to the user verbatim:

> Running **dataproduct-implement**. I'll:
> 1. Pre-checks: confirm this is a dbt project with the `generate_schema_name` macro and a project-local Databricks `profiles.yml`; `uv`, `entropy-data`, `jq`, and `yq` are available; the Entropy Data connection works; Databricks credentials can be resolved.
> 2. Resolve the data product by id (`entropy-data dataproducts get <id>`) and sync the local ODPS file.
> 3. Fetch each output port's data contract (`entropy-data datacontracts get`) and save it to `models/output_ports/v<N>/`.
> 4. Translate the ODCS schema into dbt models: Databricks types, an enforced dbt model contract, and tests — materialised into `<catalog>.<output-port-id>.<table>`.
> 5. Wire input ports from active access agreements as dbt sources (`<catalog>.<upstream-port-id>.<table>`).
> 6. Derive the transformation (staging → intermediate → output port) from the data product's purpose, the contract's descriptions and quality rules, and the input-port contracts.
> 7. Run `dbt parse` to catch syntax errors.
> 8. Run `dbt-ol run` against your Databricks target — this builds the tables AND ships the lineage event to Entropy Data on the spot. (One confirmation question, together with any open assumption about the transformation.)
> 9. Run `dbt test` against the same target.
> 10. Run `datacontract test` against each output-port contract.
> 11. Update the data product on Entropy Data: `dataProductBuilder` stamp, and — on success — output port display name/status and a real SQL example.
> 12. Summarize what was generated, what ran, and what's still open.

Then proceed.

### Step 0 — Pre-checks

- Confirm `dbt_project.yml` exists at the working directory root. If not, route the user to `dataproduct-bootstrap` and stop. `DBT_NAME` = `yq '.name' dbt_project.yml`; `INTERNAL_SCHEMA` = `<DBT_NAME>_internal`.
- Confirm a `.dbtignore` containing `*.odcs.yaml` exists (copy it from the bootstrap templates if missing, otherwise dbt tries to parse the contracts as schema files).
- Confirm a `generate_schema_name` macro exists under `macros/`. If not, copy `${PLUGIN_ROOT}/skills/dataproduct-bootstrap/templates/macros/generate_schema_name.sql` into `macros/` (tell the user — without it dbt would write the output port into `<target_schema>_<output_port_id>`).
- Confirm `uv --version`, `entropy-data --version`, `jq --version`, and `yq --version` work. Then warm up and check the tools — these checks need no dbt project and no OpenLineage config:
  - `uvx --python 3.12 --from dbt-core --with dbt-databricks dbt --version`
  - `uvx --python 3.12 --from openlineage-dbt --with dbt-databricks python -c "import openlineage.dbt"` — do **not** use `dbt-ol --version` / `--help`: inside a project with `openlineage.yml` it crashes without an API key (`KeyError: apiKey is required for HTTP Transport`), outside a project with `FileNotFoundError: ./dbt_project.yml`.
  - `uv tool run --from 'datacontract-cli[databricks]' datacontract --version`

  If one fails, surface the error and the install line (`curl -LsSf https://astral.sh/uv/install.sh | sh`, `uv tool install entropy-data`) and stop.
- Confirm `entropy-data connection test` succeeds. If not, stop and tell the user to run `entropy-data connection add <name> --host <host> --api-key <key>`. `API_HOST` = `entropy-data connection get -o json | jq -r .host`.
- **dbt profile.** If `profiles.yml` is missing in the project root, write it: copy `profiles.yml.example`, or — if that is missing too — the bootstrap template `profiles.yml.example` with `{{DBT_NAME}}`, `{{CATALOG}}`, `{{INTERNAL_SCHEMA}}` substituted (`CATALOG` from the output-port contract's Databricks server — write the file once Step 2 resolved it). It contains `env_var()` references only and must be gitignored (add `profiles.yml` to `.gitignore` if missing). `TARGET` = `yq ".${DBT_NAME}.target" profiles.yml` unless the user names one or the credentials below select one. If `yq ".${DBT_NAME}.outputs.${TARGET}.type" profiles.yml` is not `databricks`, stop and point the user at https://github.com/entropy-data/dataproduct-builder-demo (Snowflake) or https://github.com/entropy-data/dataproduct-builder-dbt. If the file contains a literal token or secret instead of `env_var()`, tell the user to move it to an env var.
- **Resolve runtime credentials once, never print them.** Do not echo, log, or persist API keys or tokens; pass them only as inline env vars of the command that needs them, through `$(...)` / `${VAR}` expansions so the values never appear in the transcript.
  - **Entropy Data API key** — `${ENTROPY_DATA_API_KEY}` if set, else `$(entropy-data connection get --show-api-key -o json | jq -r .api_key)` (the JSON field is `api_key`; without `--show-api-key` it is masked).
  - `DBX_HOST` ← `$DATABRICKS_HOST`, else the output-port contract server's `host` (Step 2). Strip any `https://` and trailing `/`.
  - `DBX_HTTP_PATH` ← `$DATABRICKS_HTTP_PATH`, else the contract server's `customProperties` `httpPath`, else ask the user (not a secret).
  - **dbt needs a writer** — `CREATE SCHEMA` on the catalog (or pre-created `<CATALOG>.<SCHEMA>` and `<CATALOG>.<INTERNAL_SCHEMA>` with `CREATE TABLE` / `CREATE VIEW`) plus `SELECT` on the input-port schemas. First match wins:
    1. `$DATABRICKS_TOKEN` (PAT, Azure AD / Entra token, or a minted token) → target `dev`.
    2. `$DATABRICKS_CLIENT_ID` / `$DATABRICKS_CLIENT_SECRET` of a **writer** service principal → target `prod` (native OAuth M2M in the profile).
    3. A logged-in `databricks` CLI: `DATABRICKS_TOKEN="$(databricks auth token --host "https://${DBX_HOST}" | jq -r .access_token)"` → target `dev`.
    4. Azure Databricks with an `az` login: `DATABRICKS_TOKEN="$(az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv)"` → target `dev`.
  - **`datacontract test` only reads** (`USE CATALOG`, `USE SCHEMA`, `SELECT`), so a read-only service principal is fine. First match wins: `$DATACONTRACT_DATABRICKS_TOKEN`; else a token minted from `$DATACONTRACT_DATABRICKS_CLIENT_ID` / `$DATACONTRACT_DATABRICKS_CLIENT_SECRET` (read-only SP):
    ```bash
    curl -sf -X POST "https://${DBX_HOST}/oidc/v1/token" \
      -u "${DATACONTRACT_DATABRICKS_CLIENT_ID}:${DATACONTRACT_DATABRICKS_CLIENT_SECRET}" \
      -d 'grant_type=client_credentials&scope=all-apis' | jq -r .access_token
    ```
    else the dbt token from above (minted the same way from `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` when dbt uses a writer SP).

  If a value is genuinely missing from every source, stop and tell the user which env var to set. With Azure AD tokens the tools may log `Token exchange failed, using external token` — harmless, ignore it.

### Step 1 — Resolve the data product

Accept either a full URL (`https://app.entropy-data.com/<org>/dataproducts/<id>`, extract the trailing id) or a bare id. Use the id exactly as published (usually kebab-case) for every Entropy Data call; only dbt names use the snake_case `DBT_NAME`.

Load the data product ODPS via the `entropy-data` CLI: run `entropy-data dataproducts get <id> -o yaml`. Remember the response as `DATA_PRODUCT`. Extract:

- `DATA_PRODUCT_ID`, `DATA_PRODUCT_NAME`, owning team, purpose (`description.purpose`, plus `description.usage` / `limitations` if present)
- the list of output ports — each has an id (`.id // .name`), a type, and a linked data contract id (`contractId`)

Always use the `entropy-data` CLI for any connection to Entropy Data (data products, data contracts, access, publishing). Do not use the Entropy Data MCP server for these calls.

If the data product has more than one output port, ask the user which one(s) to implement. Default to all.

If the data product does not exist on Entropy Data, stop and tell the user to publish it first (e.g. `entropy-data dataproducts put <id> --file <id>.odps.yaml` from the bootstrap scaffold, or create it in the web UI). This demo skill does not create platform records itself.

**Sync the local ODPS file** `<DATA_PRODUCT_ID>.odps.yaml` (CI publishes it with `dataproducts put`, so a stale local copy would overwrite the published product): if it is missing or starts with the `# dataproduct-builder:stub` marker, run `entropy-data dataproducts get <id> -o yaml > <DATA_PRODUCT_ID>.odps.yaml` without asking. If it exists, has no marker, and differs from the published one, surface the diff and ask (default: take the published version).

### Step 2 — Fetch the data contract

For each selected output port, run `entropy-data datacontracts get <contract-id> -o yaml`. Remember as `CONTRACT`, write it to `models/output_ports/v<N>/<contract-id>.odcs.yaml` (`<N>` from the `_v<N>` suffix of the output-port id, else the output port's `version`, default `1`):

- File missing → write it.
- File starts with the `# dataproduct-builder:stub` marker (written by `dataproduct-bootstrap` before a contract was published) → overwrite it **without asking**, and say so.
- File differs otherwise → surface the diff and ask before overwriting.

You need from `CONTRACT`:

- `description` (`purpose`, `usage`, `limitations`) and `schema` (table → properties list with `logicalType`, `physicalType`, `physicalName`, `required`, `primaryKey`, `unique`, `description`, `classification`, plus table- and property-level `quality` rules)
- `servers` — the Databricks server the contract test runs against. **`CONTRACT_SERVER`** = the `.server` name of the `servers[]` entry with `type: databricks`, preferring `environment` `prod` / `production`, then server name `prod` / `production`, then the first one. Never assume the name `production`.

Resolve the Unity Catalog location of the output port:

- `CATALOG` = `server.catalog`; `SCHEMA` = `server.schema`; `TABLE` = `schema[0].physicalName // schema[0].name`.
- Expected by convention: `SCHEMA` = output-port id = contract id (e.g. `customers_v1`), `TABLE` = contract id without `_v<N>` (e.g. `customers`). If the contract deviates (or the server has no explicit `catalog`), surface it and ask the user whether to follow the contract as-is (default) or fix the contract upstream first. Never silently rename — the contract is what `datacontract test` checks.

**Keep the server name consistent.** If `.github/workflows/data-product.yml` or `README.md` pass a different `--server` to `datacontract test` (e.g. the bootstrap default `production` while the contract says `databricks-prod`), replace it with `CONTRACT_SERVER` and show the diff.

### Step 3 — Translate ODCS schema to dbt artifacts

**Output column identifier rule (applies to every property in this step and the next ones).** For every contract property, resolve `OUT_COL = property.physicalName // property.name` — prefer `physicalName` when present, fall back to `name`. Use `OUT_COL` for the SQL alias **and** the `_models.yml` `columns: - name:` entry so the projected column, the dbt tests, the enforced model contract, and the materialised Delta column all agree. Databricks identifiers are case-insensitive and stored as written; if `OUT_COL` is not a plain `^[a-z_][a-z0-9_]*$` identifier, quote it with backticks in SQL (`` as `Mixed Case` ``) and set `quote: true` on the `_models.yml` column. Note: `datacontract test` keys its presence check on the contract field `name`, so a contract whose `name` and `physicalName` disagree is an upstream contract bug to fix at the source.

**Databricks type rule.** `DBX_TYPE` = the property's `physicalType` (lower-cased) when present, otherwise map `logicalType`:

| ODCS `logicalType` | Databricks SQL type |
|---|---|
| `string` | `string` |
| `integer` | `bigint` (use `int` only if `physicalType: int`) |
| `number` | `decimal(38,9)` (or the `physicalType` precision, e.g. `decimal(10,2)`) |
| `boolean` | `boolean` |
| `date` | `date` |
| `timestamp` | `timestamp` |
| `array` | `array<T>` where `T` maps `items` the same way (e.g. `array<string>`) |
| `object` | ask the user (`struct<...>` from `properties`, or `string` JSON) |

For each contract:

1. Decide the dbt model: file `models/output_ports/v<N>/<TABLE>.sql`. If a model named `<TABLE>` already exists for another version (e.g. `v1` and `v2` both produce `customers`), name the file `<CONTRACT_ID>.sql` instead — the `alias` keeps the Unity Catalog table name correct either way. Every output model starts with:

   ```sql
   -- Governed by <contract-file>.odcs.yaml (ODCS id: <CONTRACT_ID>)
   {{ config(schema='<SCHEMA>', alias='<TABLE>', materialized='table') }}
   ```

   `schema='<SCHEMA>'` + the `generate_schema_name` override puts the table at `<CATALOG>.<SCHEMA>.<TABLE>`; the catalog comes from the profile's `catalog:`. If `CATALOG` differs from the profile catalog, also set `database='<CATALOG>'` in the config (dbt-databricks maps `database` to the Unity Catalog catalog). The `select` body is written in Step 5.

2. Append the model to `models/output_ports/v<N>/_models.yml` with an **enforced dbt model contract** whose `data_type`s are the `DBX_TYPE`s:

   ```yaml
   models:
     - name: <model-name>
       description: <from contract>
       config:
         schema: <SCHEMA>
         contract:
           enforced: true
         meta:
           data_contract:
             id: <CONTRACT_ID>
             file: models/output_ports/v<N>/<contract-file>.odcs.yaml
       columns:
         - name: <OUT_COL>
           description: <from contract>
           data_type: <DBX_TYPE>
           data_tests: [not_null]   # only when required or primaryKey
   ```

   Translate ODCS rules to dbt tests: `required: true` → `not_null`, `unique: true` or `primaryKey: true` → `unique` (+ `not_null`), enum → `accepted_values`. With `contract.enforced: true`, every projected column must be listed with a `data_type`, and the column order/types in SQL must match — dbt fails the build otherwise, which is the point.

3. Translate each contract `quality` rule of `type: sql` into a singular dbt test `tests/assert_<TABLE>_<short_slug>.sql` that returns the violating rows, with the contract's table name replaced by `{{ ref('<model-name>') }}` (e.g. `SELECT COUNT(*) FROM t WHERE persons < 50` with `mustBe: 0` → `select * from {{ ref('t') }} where persons < 50`). Add a comment naming the rule. Rules that don't map cleanly stay with `datacontract test`.

### Step 4 — Wire input ports

1. **Identify input ports.** Run `entropy-data access list --consumer-dataproduct <DATA_PRODUCT_ID> -o json` to list access agreements. Each entry's `provider.dataProductId` / `provider.outputPortId` is an input port this product can read. Keep agreements with `info.active: true`; ignore `pending` / `rejected`. Remember each agreement's `info.purpose` — it limits which columns may be read. If `models/input_ports/<provider-output-port-id>.source.yaml` already exists for an agreement, treat it as authoritative.
2. **Declare each input port as a dbt source:**
   1. Fetch the provider data product (`entropy-data dataproducts get <provider-data-product-id> -o yaml`) to resolve the linked contract id.
   2. Fetch the upstream contract (`entropy-data datacontracts get <provider-contract-id> -o yaml`) and write it to `models/input_ports/<provider-output-port-id>.odcs.yaml` as a trust snapshot. Its `databricks` server gives the location: `<catalog>.<schema>.<table>` — by convention `<catalog>.<provider-output-port-id>.<contract id without _v<N>>`. If the upstream server is not `type: databricks`, leave a TODO (it can't be read from this warehouse without Lakehouse Federation) and continue.
   3. Write `models/input_ports/<provider-output-port-id>.source.yaml`. The **source name** is `<provider-data-product-id>_<provider-output-port-id>` normalised to snake_case — lower-cased, every character outside `[a-z0-9_]` replaced by `_` (e.g. `schufa-score` + `consumer_scores_v1` → `schufa_score_consumer_scores_v1`):

      ```yaml
      version: 2
      sources:
        - name: <provider_data_product_id>_<provider_output_port_id>
          database: <upstream catalog>        # Unity Catalog catalog
          schema: <upstream schema>           # e.g. orders_v2
          config:
            meta:
              data_contract:
                id: <provider-contract-id>
                file: models/input_ports/<provider-output-port-id>.odcs.yaml
          tables:
            - name: <upstream table>          # e.g. orders
              description: <from contract>
              columns:
                - name: <col>
                  description: <from contract>
                  data_type: <DBX_TYPE per the type rule in Step 3>
      ```

   One pair (`*.odcs.yaml` + `*.source.yaml`) per agreement. Surface diffs and ask before overwriting an existing file.

### Step 5 — Derive and write the transformation

The contract fixes the output schema; the logic comes from what the metadata says. Read, in this order:

- the data product's purpose (and usage / limitations) and the output contract's `description`;
- every output field's `description`, `required` / `primaryKey` / `unique`, and the `quality` rules (e.g. a minimum cell size means aggregate + `having`);
- the input-port contracts: field descriptions, keys, status / enum fields (e.g. "ACTIVE, MERGED or BLOCKED" → keep the valid rows), and each access agreement's purpose (read only what the purpose covers — data minimisation).

From that, write the pipeline in the bootstrap layout:

1. **Staging** — one `models/staging/stg_<upstream_table>.sql` per input port: `select` only the columns the transformation needs `from {{ source('<source_name>', '<table>') }}`, with a header comment naming the input port and agreement. Add `not_null` / `unique` tests for the keys in `models/staging/_models.yml`.
2. **Intermediate** (when there is more than one input or a non-trivial filter) — `models/intermediate/int_<grain>.sql`: joins on the keys the input contracts declare, plus filters derived from the metadata. Document it in `models/intermediate/_models.yml`.
3. **Output port** — the `select` in the model from Step 3: aggregations / derivations named by the field descriptions, every column `cast(... as <DBX_TYPE>) as <OUT_COL>` in contract order, and quality rules that describe the content enforced in SQL (e.g. `having count(*) >= 50`).

When the output columns match one input 1:1, the output model can select straight from the staging view.

**Ambiguity → one question.** If the metadata leaves a real choice open (join key, grain, which rows count, how a derived value is computed), pick the most plausible option, write it, and collect each such assumption. They are asked **together with the Step 7 run confirmation** — one question that shows the proposed output-model SQL (and the intermediate SQL if relevant) and lists the assumptions. If the user corrects something, update the SQL, re-run Step 6, and proceed without asking again. Fall back to `cast(null as <DBX_TYPE>) as <OUT_COL>  -- TODO: <what is missing>` only for a column the user explicitly leaves open.

### Step 6 — `dbt parse`

Run `dbt parse --profiles-dir .` with `DATABRICKS_HOST` / `DATABRICKS_HTTP_PATH` and the selected target's credential env vars set (the profile renders `env_var()`; parse does not connect). If it fails, surface the error, fix obvious mistakes (wrong source name, typos in `_models.yml`, missing `data_type` under an enforced contract), and re-run. Do not proceed to Step 7 with a failing parse.

### Step 7 — `dbt-ol run` (this is where lineage gets shipped)

Confirm with the user — normally the skill's only question: "Run `dbt-ol run` against your Databricks target `<TARGET>` now? This materialises the models in `<CATALOG>.<SCHEMA>` and `<CATALOG>.<INTERNAL_SCHEMA>` (creating the schemas if needed) and ships the lineage event to Entropy Data immediately." If Step 5 collected assumptions, include the proposed SQL and the assumptions in the same question. Wait for explicit yes.

If TODO columns remain, warn that those columns will be `null` and `not_null` tests / contract checks will fail, and offer to scope to the complete models: `dbt-ol run --profiles-dir . --select <model> ...`.

Command — export the API key and the Databricks settings inline from Step 0; do not require the user to have them in their shell (`DATABRICKS_TOKEN` or `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` come from the environment or a `$(...)` from Step 0):

```bash
OPENLINEAGE__TRANSPORT__AUTH__APIKEY="${ENTROPY_DATA_API_KEY:-$(entropy-data connection get --show-api-key -o json | jq -r .api_key)}" \
OPENLINEAGE_NAMESPACE="databricks://<DBX_HOST>" \
DATABRICKS_HOST="<DBX_HOST>" DATABRICKS_HTTP_PATH="<DBX_HTTP_PATH>" \
  uvx --python 3.12 --from openlineage-dbt --with dbt-databricks dbt-ol run --profiles-dir . --target <TARGET>
```

`dbt-ol` emits the datasets under the namespace `databricks://<host>` (taken from the profile's `host:`, which is why it must be a bare hostname) and the job under `OPENLINEAGE_NAMESPACE`. The transport in `openlineage.yml` sends the events to Entropy Data authenticated with the API key.

Capture stdout and exit code. Non-zero means at least one model failed; surface the dbt log section, do not retry silently. Common Databricks failures: `PERMISSION_DENIED` on `CREATE SCHEMA` / `CREATE TABLE` (the principal is read-only — dbt needs a writer: a PAT / Azure AD token of a user with write rights, or a writer SP; or the catalog owner grants `CREATE SCHEMA` on `<CATALOG>` / pre-creates `<SCHEMA>` and `<INTERNAL_SCHEMA>`), and a stopped SQL warehouse (the first query wakes it; a timeout usually resolves on retry).

If `dbt-ol run` succeeded, **the data product is now visible with materialised tables AND a lineage event in Entropy Data.** Tell the user this explicitly in the final report — it is the whole point of the demo.

### Step 8 — `dbt test`

```bash
DATABRICKS_HOST="<DBX_HOST>" DATABRICKS_HTTP_PATH="<DBX_HTTP_PATH>" \
  uvx --python 3.12 --from dbt-core --with dbt-databricks dbt test --profiles-dir . --target <TARGET>
```

Covers the contract-derived tests (`not_null`, `unique`, `accepted_values`, the singular quality tests) and the staging tests. Surface failures by model and test name.

### Step 9 — `datacontract test`

For each output-port contract, export the Databricks settings inline (the read token from Step 0 — a read-only principal is enough); do not require the user to set `DATACONTRACT_DATABRICKS_*` in their shell:

```bash
DATACONTRACT_DATABRICKS_SERVER_HOSTNAME="<DBX_HOST>" \
DATACONTRACT_DATABRICKS_HTTP_PATH="<DBX_HTTP_PATH>" \
DATACONTRACT_DATABRICKS_TOKEN="${DATACONTRACT_DATABRICKS_TOKEN:-${DATABRICKS_TOKEN}}" \
  uv tool run --from 'datacontract-cli[databricks]' datacontract test models/output_ports/v<N>/<contract-id>.odcs.yaml --server <CONTRACT_SERVER> --logs
```

(Replace the token expansion with the `$(...)` from Step 0 when the token is minted.) The Data Contract CLI takes `catalog` / `schema` from the ODCS server block and the HTTP path only from `DATACONTRACT_DATABRICKS_HTTP_PATH`. `--logs` ensures the failure detail (field + rule) is in stdout. Non-zero exit means at least one rule failed. Capture per-contract result for the final report. To also publish the result to Entropy Data, add `--publish <API_HOST>/api/test-results` with `ENTROPY_DATA_API_KEY` set (not the deprecated `--publish-test-results`).

### Step 10 — Update the data product on Entropy Data

One `get` → edit → diff → `put`, preserving everything else:

1. `mkdir -p target && entropy-data dataproducts get <DATA_PRODUCT_ID> -o yaml > target/<DATA_PRODUCT_ID>.published.odps.yaml`, and copy it to `target/<DATA_PRODUCT_ID>.odps.yaml` (`target/` is gitignored).
2. Edit only these keys in the copy (with `yq -i`), leaving every other key, list entry, and order untouched:
   - **Always:** the top-level `customProperties` entry `dataProductBuilder` = `https://github.com/entropy-data/dataproduct-builder-demo-databricks` (add if missing).
   - **Only if `dbt-ol run` and `datacontract test` passed for the port**, for each implemented output port (matched by `.id // .name`), in its `customProperties`:
     - `displayName` — set it if missing or empty (the contract's `name`, else `DATA_PRODUCT_NAME`); keep an existing value.
     - `status` = `active`.
   - **Only on success:** the top-level `customProperties` entry `aiExamples` — if it is missing, says the product is not implemented yet, or doesn't reference the real table, set it to one realistic question plus SQL against the fully qualified table, using only contract columns, in the existing style, e.g. `Q: Average score per federal state` + newline + `SELECT federal_state, sum(avg_score_value * persons) / sum(persons) AS avg_score FROM <CATALOG>.<SCHEMA>.<TABLE> GROUP BY federal_state`. If it already queries `<CATALOG>.<SCHEMA>.<TABLE>` with existing columns, keep it.
3. `diff -u target/<DATA_PRODUCT_ID>.published.odps.yaml target/<DATA_PRODUCT_ID>.odps.yaml` and show it. If nothing changed, skip the put. If the diff touches anything beyond the keys above, stop and fix the edit.
4. `entropy-data dataproducts put <DATA_PRODUCT_ID> --file target/<DATA_PRODUCT_ID>.odps.yaml`.
5. Refresh the local file so CI publishes the same thing: `entropy-data dataproducts get <DATA_PRODUCT_ID> -o yaml > <DATA_PRODUCT_ID>.odps.yaml`. Delete the two `target/` files.

If other custom properties still say the product is not implemented (e.g. `aiInstructions: Not yet implemented — no data available`), don't edit them; list them in the next steps.

### Step 11 — Final report

End with this two-part recap. Use the `Status` enum: `created`, `updated`, `already present`, `passed`, `failed`, `skipped`.

**Part 1 — outcome table.**

| Artifact | Status | Details |
|---|---|---|
| Data product | already present | `<DATA_PRODUCT_ID>` (dbt project `<DBT_NAME>`), local `<DATA_PRODUCT_ID>.odps.yaml` in sync |
| Output-port data contract `<CONTRACT_ID>` | … | `models/output_ports/v<N>/<contract-id>.odcs.yaml` → `<CATALOG>.<SCHEMA>.<TABLE>`, server `<CONTRACT_SERVER>` |
| Input-port contracts | … | `<N>` files at `models/input_ports/<...>.odcs.yaml` |
| Input-port sources | … | `<N>` files at `models/input_ports/<...>.source.yaml` |
| Transformation | … | staging / intermediate / output models — "derived from metadata" / "confirmed by user" / "TODO: <columns>" |
| `_models.yml` entries + singular tests | … | counts, contract enforced |
| `dbt parse` | … | passed / failed: `<reason>` |
| `dbt-ol run` | … | "passed — N models materialised, lineage shipped to `<API_HOST>`" / "failed" / "skipped" |
| `dbt test` | … | "passed — N tests" / "failed: N of M" / "skipped" |
| `datacontract test` | … | per contract: "passed" / "failed: <count>" / "skipped" |
| Data product on Entropy Data | … | `dataProductBuilder`, output port `displayName` / `status: active`, `aiExamples` — "updated" / "already present" / "skipped (tests failed)" |

**Part 2 — next steps.** Bullet list, only what applies:

- The transformation assumptions made in Step 5, so the owner can review them.
- For each remaining TODO column, the inputs and the missing logic.
- For each `failed` row, the concrete next action (which model, which test, which contract rule).
- If `dbt-ol run` succeeded, link the user to the data product in Entropy Data so they can see the lineage event land.
- Consumers get access by a grant on the output-port schema only, e.g. `GRANT USE SCHEMA, SELECT ON SCHEMA <CATALOG>.<SCHEMA> TO <group>` (plus `USE CATALOG`) — never on `<INTERNAL_SCHEMA>`.
- Custom properties that still claim the product is not implemented (e.g. `aiInstructions`) — for the owner to update.
- If GitHub Actions are set up, remind the user to set the workflow secrets (`ENTROPY_DATA_API_KEY`, `DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, and `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` of a **writer** service principal) so the CI run reproduces the local run.

If everything passed and there are no TODOs, write: `Pipeline implemented, materialised, tested, and lineage published. Nothing else to do.`

## Constraints

- **Databricks only.** The type map, profiles, and CLI invocations are Databricks-specific. If the user's profile is not `type: databricks`, stop.
- **Contract is the source of truth for the schema; metadata is the source of truth for the logic.** Every join, filter, and aggregation must be traceable to the data product purpose, the contract's descriptions and quality rules, the input-port contracts, or the user's answer. Don't make up business rules the metadata doesn't support — list them as assumptions in the one question.
- **Don't overwrite existing dbt SQL silently.** Surface the diff and ask. Files with the `# dataproduct-builder:stub` marker are the exception — they are replaced without asking.
- **Don't auto-fix failing dbt or datacontract tests.** Report them; the fix belongs to the user.
- **Don't touch other catalogs/schemas.** Only write to `<CATALOG>.<SCHEMA>` (output ports) and `<CATALOG>.<INTERNAL_SCHEMA>`; upstream schemas are read-only sources.
- **Never print secrets.** API keys and tokens only travel as inline env vars via `$(...)` / `${VAR}` expansions; `profiles.yml` holds `env_var()` references only.
- **Don't push or commit.** Leave VCS state to the user.
- **Idempotent.** Re-running on the same data product when files already match the contract is a no-op (except the run/test commands, which always re-execute; the Step 10 diff is then empty).

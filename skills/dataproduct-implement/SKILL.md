---
name: dataproduct-implement
description: Given an Entropy Data data product URL or id, fetch its ODCS, generate Databricks (Unity Catalog) dbt models, run dbt-ol (ship lineage to Entropy Data on the spot), run dbt tests, and run datacontract tests — end-to-end in one go. Demo-grade. Trigger when the user asks to "implement the data product <url>", "build the dbt pipeline for this data product", or "scaffold dbt models from a data contract".
---

# Implement a data product from its data contract (demo)

Turn an Entropy Data data product into a working Databricks dbt pipeline and prove it works — in one pass. The data contract (ODCS) is the source of truth for the output schema; this skill reads it, writes dbt artifacts that produce data matching the contract, runs everything against your Databricks SQL warehouse, and ships an OpenLineage event so the pipeline shows up in Entropy Data immediately.

Unity Catalog naming convention (see `dataproduct-bootstrap`): catalog = the organization's catalog; one schema per output port named after the output-port / contract id (`customers_v1`); table = contract id without `_v<N>` (`customers`); staging/intermediate in `<data-product-id>_internal`; upstream data products are read from `<catalog>.<upstream-output-port-id>.<table>`.

## When to use this vs. other skills

- **Empty directory, no dbt project yet** → run `dataproduct-bootstrap` first, then come back here.
- **Existing dbt project, want to derive Databricks models from a published data contract and prove the pipeline works** → this skill.

## How to run this skill

> `${PLUGIN_ROOT}` below refers to the root of this plugin — the directory that contains `skills/`. On Claude Code it is set automatically as `${CLAUDE_PLUGIN_ROOT}`; use that. On any other agent (Codex, Copilot CLI, etc.) it is unset; resolve it as `../..` relative to **this `SKILL.md` file's directory** (i.e. the grandparent of `skills/<this-skill>/`).

### Plan announcement (before Step 0)

Before running Step 0, print this plan to the user verbatim:

> Running **dataproduct-implement**. I'll:
> 1. Pre-checks: confirm this is a dbt project with the `generate_schema_name` macro; `dbt`, `dbt-ol`, `datacontract`, `entropy-data`, `jq`, and `yq` are on PATH; the Entropy Data API key is available from `entropy-data connection`; the dbt profile is `type: databricks` and Databricks credentials can be resolved.
> 2. Resolve the data product by id (`entropy-data dataproducts get <id>`).
> 3. Fetch each output port's data contract (`entropy-data datacontracts get`) and save it to `models/output_ports/v<N>/`.
> 4. Translate the ODCS schema into dbt models: SQL column projections with Databricks types, an enforced dbt model contract, and `_models.yml` tests — materialised into `<catalog>.<output-port-id>.<table>`.
> 5. Wire input ports from active access agreements as dbt sources (`<catalog>.<upstream-port-id>.<table>`), project columns 1:1, leave the rest as TODOs.
> 6. Run `dbt parse` to catch syntax errors.
> 7. Run `dbt-ol run` against the user's Databricks target — this builds the tables AND ships the lineage event to Entropy Data on the spot.
> 8. Run `dbt test` against the same target.
> 9. Run `datacontract test` against each output-port contract.
> 10. Stamp the data product on Entropy Data with the `dataProductBuilder` customProperty.
> 11. Summarize what was generated, what ran, and what's still TODO.

Then proceed.

### Step 0 — Pre-checks

- Confirm `dbt_project.yml` exists at the working directory root. If not, route the user to `dataproduct-bootstrap` and stop.
- Confirm a `.dbtignore` containing `*.odcs.yaml` exists (copy it from the bootstrap templates if missing, otherwise dbt tries to parse the contracts as schema files).
- Confirm a `generate_schema_name` macro exists under `macros/`. If not, copy `${PLUGIN_ROOT}/skills/dataproduct-bootstrap/templates/macros/generate_schema_name.sql` into `macros/` (tell the user — without it dbt would write the output port into `<target_schema>_<output_port_id>`).
- Confirm `dbt --version`, `dbt-ol --version`, `datacontract --version`, and `entropy-data --version` are on PATH. If any are missing, surface the install line (`uv pip install dbt-core dbt-databricks openlineage-dbt 'datacontract-cli[databricks]' entropy-data`) and stop. Also confirm `jq` and `yq` are on PATH — they are used to derive credentials below.
- Confirm `entropy-data connection test` succeeds. If not, stop and tell the user to run `entropy-data connection add <name> --host <host> --api-key <key>`.
- **Assume the user has a working Databricks dbt profile.** Do not audit `~/.dbt/profiles.yml` for correctness beyond checking `type: databricks`; if it is misconfigured, `dbt parse` / `dbt-ol run` will surface a clear error. If the profile's type is not `databricks`, stop and point the user at https://github.com/entropy-data/dataproduct-builder-demo (Snowflake) or https://github.com/entropy-data/dataproduct-builder-dbt.
- **Derive runtime credentials from existing config — do not require the user to export env vars.** Resolve them once here and reuse them inline in Step 6 / Step 8. `PROFILE=$(yq '.profile' dbt_project.yml)`; `TARGET` = the profile's `target:` (or the explicit `--target` you'll pass to dbt); `OUT=".${PROFILE}.outputs.${TARGET}"`. A profile value may be a literal or `{{ env_var('X') }}` — in the latter case read env var `X`.
  - `OPENLINEAGE__TRANSPORT__AUTH__APIKEY` ← `entropy-data connection get -o json | jq -r .apiKey`.
  - `DBX_HOST` ← `$DATABRICKS_HOST`, else the profile's `host`. Strip any `https://` and trailing `/`.
  - `DBX_HTTP_PATH` ← `$DATABRICKS_HTTP_PATH`, else the profile's `http_path`.
  - `DBX_TOKEN`, first match wins:
    1. `$DATABRICKS_TOKEN`, else the profile's `token` (PAT or OAuth access token).
    2. Service principal (OAuth M2M) — `client_id` / `client_secret` from the profile or `$DATABRICKS_CLIENT_ID` / `$DATABRICKS_CLIENT_SECRET`; mint a ~1h token:
       ```bash
       curl -sf -X POST "https://${DBX_HOST}/oidc/v1/token" \
         -u "${CLIENT_ID}:${CLIENT_SECRET}" \
         -d 'grant_type=client_credentials&scope=all-apis' | jq -r .access_token
       ```
    3. A logged-in `databricks` CLI: `databricks auth token --host "https://${DBX_HOST}" | jq -r .access_token`.
  If a value is genuinely missing from every source, stop and tell the user which source to fix. Do not echo or persist these values; export them only as part of the command invocation that needs them.

### Step 1 — Resolve the data product

Accept either a full URL (`https://app.entropy-data.com/<org>/dataproducts/<id>`, extract the trailing id) or a bare id.

Load the data product ODPS via the `entropy-data` CLI: run `entropy-data dataproducts get <id> -o yaml`. Remember the response as `DATA_PRODUCT`. Extract:

- `DATA_PRODUCT_ID`, `DATA_PRODUCT_NAME`, owning team, purpose
- the list of output ports — each has an id, a server (catalog/schema/table), and a linked data contract id

Always use the `entropy-data` CLI for any connection to Entropy Data (data products, data contracts, access, publishing). Do not use the Entropy Data MCP server for these calls.

If the data product has more than one output port, ask the user which one(s) to implement. Default to all.

If the data product does not exist on Entropy Data, stop and ask the user whether to create it via `dataproduct-bootstrap` first. This demo skill does not create platform records itself.

### Step 2 — Fetch the data contract

For each selected output port, run `entropy-data datacontracts get <contract-id> -o yaml`. Remember as `CONTRACT`, write it to `models/output_ports/v<N>/<contract-id>.odcs.yaml` (`<N>` from the `_v<N>` suffix of the output-port id, else the output port's `version`, default `1`). If the file already exists and differs, surface the diff and ask before overwriting.

You need from `CONTRACT`:

- `schema` (table → properties list with `logicalType`, `physicalType`, `physicalName`, `required`, `primaryKey`, `unique`, `description`, `classification`)
- `servers` — the `type: databricks` server (prefer `production`) the contract test will run against: `host`, `catalog`, `schema`.

Resolve the Unity Catalog location of the output port:

- `CATALOG` = `server.catalog`; `SCHEMA` = `server.schema`; `TABLE` = `schema[0].physicalName // schema[0].name`.
- Expected by convention: `SCHEMA` = output-port id = contract id (e.g. `customers_v1`), `TABLE` = contract id without `_v<N>` (e.g. `customers`). If the contract deviates (or the server has no explicit `catalog`), surface it and ask the user whether to follow the contract as-is (default) or fix the contract upstream first. Never silently rename — the contract is what `datacontract test` checks.

### Step 3 — Translate ODCS schema to dbt artifacts

**Output column identifier rule (applies to every property in this step and Step 4).** For every contract property, resolve `OUT_COL = property.physicalName // property.name` — prefer `physicalName` when present, fall back to `name`. Use `OUT_COL` for the SQL alias **and** the `_models.yml` `columns: - name:` entry so the projected column, the dbt tests, the enforced model contract, and the materialised Delta column all agree. Databricks identifiers are case-insensitive and stored as written; if `OUT_COL` is not a plain `^[a-z_][a-z0-9_]*$` identifier, quote it with backticks in SQL (`` as `Mixed Case` ``) and set `quote: true` on the `_models.yml` column. Note: `datacontract test` keys its presence check on the contract field `name`, so a contract whose `name` and `physicalName` disagree is an upstream contract bug to fix at the source.

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

1. Decide the dbt model: file `models/output_ports/v<N>/<TABLE>.sql`. If a model named `<TABLE>` already exists for another version (e.g. `v1` and `v2` both produce `customers`), name the file `<CONTRACT_ID>.sql` instead — the `alias` below keeps the Unity Catalog table name correct either way.
2. **Identify candidate input ports.** Run `entropy-data access list --consumer-dataproduct <DATA_PRODUCT_ID> -o json` to list active access agreements. Each entry's `provider.dataProductId` / `provider.outputPortId` is an input port this product can read. Keep agreements with `info.active: true`; ignore `pending` / `rejected`. If `models/input_ports/<provider-output-port-id>.source.yaml` already exists for an agreement, treat it as authoritative.
3. Generate the model — a stub `select` that projects each contract column with `cast(... as <DBX_TYPE>) as <OUT_COL>`. Leave the `from` clause as a TODO commented with the candidate input ports from Step 3.2:

   ```sql
   -- Governed by <contract-file>.odcs.yaml (ODCS id: <CONTRACT_ID>)
   {{ config(schema='<SCHEMA>', alias='<TABLE>', materialized='table') }}

   select
       cast(null as string) as id,              -- TODO: map from input port
       cast(current_timestamp() as timestamp) as updated_at
   -- TODO: from {{ source('<provider-dp>_<provider-port>', '<table>') }}
   ```

   `schema='<SCHEMA>'` + the `generate_schema_name` override puts the table at `<CATALOG>.<SCHEMA>.<TABLE>`; the catalog comes from the profile's `catalog:`. If `CATALOG` differs from the profile catalog, also set `database='<CATALOG>'` in the config (dbt-databricks maps `database` to the Unity Catalog catalog).

4. Append the model to `models/output_ports/v<N>/_models.yml` with an **enforced dbt model contract** whose `data_type`s are the `DBX_TYPE`s:

   ```yaml
   models:
     - name: <model-name>
       description: <from contract>
       config:
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

### Step 4 — Wire input ports and project columns

For each output port:

1. **Declare each candidate input port as a dbt source** — for every access agreement from Step 3.2:
   1. Fetch the provider data product (`entropy-data dataproducts get <provider-data-product-id> -o yaml`) to resolve the linked contract id.
   2. Fetch the upstream contract (`entropy-data datacontracts get <provider-contract-id> -o yaml`) and write it to `models/input_ports/<provider-output-port-id>.odcs.yaml` as a trust snapshot. Its `databricks` server gives the location: `<catalog>.<schema>.<table>` — by convention `<catalog>.<provider-output-port-id>.<contract id without _v<N>>`. If the upstream server is not `type: databricks`, leave a TODO (it can't be read from this warehouse without Lakehouse Federation) and continue.
   3. Write `models/input_ports/<provider-output-port-id>.source.yaml`:

      ```yaml
      version: 2
      sources:
        - name: <provider-data-product-id>_<provider-output-port-id>
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

2. **Match input columns to output columns** by name — comparing against both the input property's `name` and its `physicalName` — or an obvious synonym only if the input contract's description makes it explicit. For each output column, if exactly one input has a matching column, project `cast(<input_col> as <DBX_TYPE>) as <OUT_COL>`. Otherwise leave `cast(null as <DBX_TYPE>) as <OUT_COL>` with a `-- TODO:` comment (the typed null keeps the enforced model contract satisfied).

3. **Write the SQL body.**
   - **Single input source, columns match 1:1** → replace the TODO `from` with `from {{ source('<provider-data-product-id>_<provider-output-port-id>', '<table>') }}`.
   - **Multiple input sources** → leave the join logic as an inline TODO listing each candidate `{{ source(...) }}` and the join keys.
   - **Derived / aggregated columns** → leave as `cast(null as <DBX_TYPE>) as <col>` with a `-- TODO: compute <description>` comment.

### Step 5 — `dbt parse`

Run `dbt parse`. If it fails, surface the error, fix obvious mistakes (wrong source name, typos in `_models.yml`, missing `data_type` under an enforced contract), and re-run. Do not proceed to Step 6 with a failing parse.

### Step 6 — `dbt-ol run` (this is where lineage gets shipped)

Confirm with the user: "Run `dbt-ol run` against your Databricks target now? This materialises the models in `<CATALOG>.<SCHEMA>` (creating the schema if needed) and ships the lineage event to Entropy Data immediately." Wait for explicit yes.

If the user has TODOs left in any output-port model (unwired `from`, derived columns, multi-source joins), warn them that those columns will be `null` and `not_null` tests / contract checks will fail. Offer to scope to only the models with no TODOs: `dbt-ol run --select <wired-model-1> <wired-model-2>`.

Command (default target inferred from the profile — usually `dev` for local runs). Export the OpenLineage API key and the Databricks credentials inline from the values resolved in Step 0; do not require the user to have them in their shell:

```
OPENLINEAGE__TRANSPORT__AUTH__APIKEY=$(entropy-data connection get -o json | jq -r .apiKey) \
OPENLINEAGE_NAMESPACE="databricks://${DBX_HOST}" \
DATABRICKS_HOST="${DBX_HOST}" DATABRICKS_HTTP_PATH="${DBX_HTTP_PATH}" DATABRICKS_TOKEN="${DBX_TOKEN}" \
  dbt-ol run --target <target>
```

`dbt-ol` emits the datasets under the namespace `databricks://<host>` (taken from the profile's `host:`, which is why it must be a bare hostname) and the job under `OPENLINEAGE_NAMESPACE`. The transport in `openlineage.yml` sends the events to Entropy Data authenticated with the API key.

Capture stdout and exit code. Non-zero means at least one model failed; surface the dbt log section, do not retry silently. Common Databricks failures: `PERMISSION_DENIED` on `CREATE SCHEMA` (ask the catalog owner for `CREATE SCHEMA` on `<CATALOG>` or to pre-create `<SCHEMA>`), and a stopped SQL warehouse (the first query wakes it; a timeout usually resolves on retry).

If `dbt-ol run` succeeded, **the data product is now visible with materialised tables AND a lineage event in Entropy Data.** Tell the user this explicitly in the final report — it is the whole point of the demo.

### Step 7 — `dbt test`

```
DATABRICKS_HOST="${DBX_HOST}" DATABRICKS_HTTP_PATH="${DBX_HTTP_PATH}" DATABRICKS_TOKEN="${DBX_TOKEN}" \
  dbt test --target <target>
```

Captures the contract-derived tests (`not_null`, `unique`, `accepted_values`) added in Step 3. Surface failures by model and test name.

### Step 8 — `datacontract test`

For each output-port contract, export the Databricks credentials resolved in Step 0 inline — do not require the user to set `DATACONTRACT_DATABRICKS_*` in their shell:

```
DATACONTRACT_DATABRICKS_SERVER_HOSTNAME="${DBX_HOST}" \
DATACONTRACT_DATABRICKS_HTTP_PATH="${DBX_HTTP_PATH}" \
DATACONTRACT_DATABRICKS_TOKEN="${DBX_TOKEN}" \
  datacontract test models/output_ports/v<N>/<contract-id>.odcs.yaml --server production --logs
```

The Data Contract CLI takes `catalog` / `schema` from the ODCS server block and the HTTP path only from `DATACONTRACT_DATABRICKS_HTTP_PATH`. `--logs` ensures the failure detail (field + rule) is in stdout. Non-zero exit means at least one rule failed. Capture per-contract result for the final report.

### Step 9 — Stamp the data product as builder-managed

Check `DATA_PRODUCT.customProperties` for an entry `property: "dataProductBuilder"` with `value: "https://github.com/entropy-data/dataproduct-builder-demo-databricks"`. If already present, skip.

Otherwise:

1. `entropy-data dataproducts get <DATA_PRODUCT_ID> -o yaml > /tmp/<DATA_PRODUCT_ID>.odps.yaml`
2. Append to the top-level `customProperties`:

   ```yaml
   customProperties:
     - property: "dataProductBuilder"
       value: "https://github.com/entropy-data/dataproduct-builder-demo-databricks"
   ```

3. `entropy-data dataproducts put <DATA_PRODUCT_ID> --file /tmp/<DATA_PRODUCT_ID>.odps.yaml`
4. Delete the temp file.

### Step 10 — Final report

End with this two-part recap. Use the `Status` enum: `created`, `updated`, `already present`, `passed`, `failed`, `skipped`.

**Part 1 — outcome table.**

| Artifact | Status | Details |
|---|---|---|
| Data product | already present | `<DATA_PRODUCT_ID>` |
| `dataProductBuilder` customProperty | … | "added" / "already present" |
| Output-port data contract `<CONTRACT_ID>` | … | `models/output_ports/v<N>/<contract-id>.odcs.yaml` → `<CATALOG>.<SCHEMA>.<TABLE>` |
| Input-port contracts | … | `<N>` files at `models/input_ports/<...>.odcs.yaml` |
| Input-port sources | … | `<N>` files at `models/input_ports/<...>.source.yaml` |
| Model `<TABLE>` | … | "wired to `<source>`" / "join TODO" / "skipped per user" |
| `_models.yml` entries | … | counts, contract enforced |
| `dbt parse` | … | passed / failed: `<reason>` |
| `dbt-ol run` | … | "passed — N models materialised, lineage shipped to `<API_HOST>`" / "failed" / "skipped" |
| `dbt test` | … | "passed — N tests" / "failed: N of M" / "skipped" |
| `datacontract test` | … | per contract: "passed" / "failed: <count>" / "skipped" |

**Part 2 — next steps.** Bullet list, only what applies:

- For each model with a join or derived-column TODO, name the inputs and the missing logic.
- For each `failed` row, the concrete next action (which model, which test, which contract rule).
- If `dbt-ol run` succeeded, link the user to `<API_HOST>/dataproducts/<DATA_PRODUCT_ID>` so they can see the lineage event land.
- Consumers get access by a grant on the output-port schema only, e.g. `GRANT USE SCHEMA, SELECT ON SCHEMA <CATALOG>.<SCHEMA> TO <group>` (plus `USE CATALOG`) — never on `<DATA_PRODUCT_ID>_internal`.
- If GitHub Actions are set up, remind the user to set the workflow secrets (`ENTROPY_DATA_API_KEY`, `DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET`) so the CI run reproduces the local run.

If everything passed and there are no TODOs, write: `Pipeline implemented, materialised, tested, and lineage published. Nothing else to do.`

## Constraints

- **Databricks only.** The type map, profiles, and CLI invocations are Databricks-specific. If the user's profile is not `type: databricks`, stop.
- **Contract is source of truth for schema, not logic.** Generate columns, types, and tests from the contract. Project and cast in SQL only — do not invent joins, aggregations, or column derivations.
- **Don't overwrite existing dbt SQL silently.** Surface the diff and ask.
- **Don't auto-fix failing dbt or datacontract tests.** Report them; the fix belongs to the user.
- **Don't touch other catalogs/schemas.** Only write to `<CATALOG>.<SCHEMA>` (output ports) and `<CATALOG>.<DATA_PRODUCT_ID>_internal`; upstream schemas are read-only sources.
- **Don't push or commit.** Leave VCS state to the user.
- **Idempotent.** Re-running on the same data product when files already match the contract is a no-op (except the run/test commands, which always re-execute).

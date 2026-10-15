---
name: datacontract-test
description: Run `datacontract test` against ODCS contracts in the project to verify the live Databricks (Unity Catalog) data still conforms to schema, quality rules, and freshness. Handles two kinds of contracts with different semantics: output-port contracts under `models/output_ports/**/*.odcs.yaml` (tested against this project's output-port schema — "am I still producing what I promised?") and input-port contracts under `models/input_ports/*.odcs.yaml` (tested against the upstream data product's schema — "is upstream still producing what I trusted?"). Trigger when the user asks to "test the data contracts", "verify the data product matches its contract", "are we still contract-conformant", "check upstream drift", or "run the contract tests".
---

# Test ODCS data contracts against Databricks

Run the **Data Contract CLI** (`datacontract test`) against contracts in the project to check whether the data currently in Unity Catalog still matches the schema and quality rules declared in the contract.

Two kinds of contracts live in this project and they test against different Unity Catalog locations:

- **Output-port contracts** at `models/output_ports/v<N>/*.odcs.yaml` — what this data product commits to produce. They test against **this project's** output-port schema (`<catalog>.<output-port-id>`). A failure means we are no longer producing what we promised.
- **Input-port contracts** at `models/input_ports/*.odcs.yaml` — cached snapshots of what we trust upstream to produce. They test against the **upstream provider's** server (`<catalog>.<upstream-output-port-id>`), using the server block from the upstream ODCS. A failure means upstream drifted from the contract we trusted; the consequence is that our output may break too. Treat input-port failures as an upstream incident, not a local bug.

## When to use this vs. other skills

- **Just ran `dataproduct-implement` and want to re-test without re-running dbt** → this skill.
- **A CI run failed the contract test step** → this skill, to reproduce locally with `--logs`.
- **You want to edit a contract and check the impact** → not in this demo plugin; use [datacontract-edit](https://github.com/entropy-data/dataproduct-builder-dbt/blob/main/skills/datacontract-edit/SKILL.md) from the full builder.

## How to run this skill

> `${PLUGIN_ROOT}` below refers to the root of this plugin — the directory that contains `skills/`. On Claude Code it is set automatically as `${CLAUDE_PLUGIN_ROOT}`; use that. On any other agent (Codex, Copilot CLI, etc.) it is unset; resolve it as `../..` relative to **this `SKILL.md` file's directory** (i.e. the grandparent of `skills/<this-skill>/`).

### Plan announcement (before Step 0)

Before running Step 0, print this plan to the user verbatim:

> Running **datacontract-test**. I'll:
> 1. Pre-checks: confirm `datacontract` is on PATH and Databricks credentials are in the environment.
> 2. Pick which contract(s) to test — defaults to all `models/output_ports/**/*.odcs.yaml` and `models/input_ports/*.odcs.yaml`.
> 3. Pick the server (defaults to `production` if the contract defines one).
> 4. Run `datacontract test` per contract and capture the result.
> 5. Report pass/fail with per-rule detail; flag missing credentials separately from real failures.

Then proceed.

### Step 0 — Pre-checks

- Confirm `datacontract --version` is on PATH. If not, stop and tell the user to install it: `uv tool install 'datacontract-cli[databricks]'`.
- Confirm at least one `*.odcs.yaml` exists under `models/output_ports/**/` or `models/input_ports/`. If not, stop and tell the user there is nothing to test.
- Confirm Databricks credentials for the Data Contract CLI are in the environment. The CLI reads `DATACONTRACT_DATABRICKS_*` env vars, **not** `~/.dbt/profiles.yml`. The minimum set:

  ```bash
  DATACONTRACT_DATABRICKS_HTTP_PATH        # SQL warehouse, e.g. /sql/1.0/warehouses/<id> — env only, never read from the contract
  DATACONTRACT_DATABRICKS_TOKEN            # PAT or OAuth access token (see below)
  DATACONTRACT_DATABRICKS_SERVER_HOSTNAME  # optional when the server block has `host`
  ```

  If any are unset, surface the list and ask whether to continue (the CLI will fail-fast on that server) or stop. Do not try to source credentials yourself.

### Step 1 — Select contracts

- If the user named a specific contract file or data product id, resolve it to one file. Search both `models/output_ports/**/*.odcs.yaml` and `models/input_ports/*.odcs.yaml`.
- If the user said "output contracts" / "input contracts" / "upstream drift", scope to one of those globs.
- If they did not, default to **all** ODCS files under both globs. List them, grouped by **Output ports** and **Input ports** so the user sees the two roles, then ask before running.
- Remember the resolved list as `CONTRACTS`. For each entry, also remember its role (`output` or `input`) — Step 4 surfaces failures differently.

### Step 2 — Select the server

For each contract in `CONTRACTS`:

- If the contract has exactly one server, use it.
- If it has multiple, default to `production`. If `production` is not defined, ask the user which one.
- Only pass `--server all` if the user explicitly asks to test every server.
- If the chosen server is not `type: databricks`, mark the contract `skipped` (this plugin is Databricks-only).

### Step 3 — Run the test

For each contract:

```
datacontract test <path-to-contract>.odcs.yaml --server <server> --logs
```

Where `<path-to-contract>` is the file resolved in Step 1 — typically `models/output_ports/v<N>/<file>.odcs.yaml` for output contracts, or `models/input_ports/<file>.odcs.yaml` for input contracts. The CLI does not care which directory; the role only matters for how Step 4 reports the result.

- **Upstream on another workspace:** `DATACONTRACT_DATABRICKS_SERVER_HOSTNAME` overrides the contract's `host`. If an input-port contract's `host` differs from this project's workspace, run it with that variable unset (and with an HTTP path + token valid for the upstream workspace), otherwise the CLI connects to the wrong workspace.
- `--logs` ensures per-rule failure detail is in stdout — without it the CLI only prints a summary.
- If the user asks for a persisted report (e.g. to attach to a PR), add `--output ./test-results/<contract>.xml --output-format junit`.
- If the user asks to publish results back to Entropy Data (matches the generated CI workflow), add `--publish $API/test-results` where `$API` is the Entropy Data host. Do not publish by default — it writes server-side state.
- Capture stdout and exit code per contract. Non-zero exit means at least one rule failed.

Run sequentially, not in parallel — the SQL warehouse is the bottleneck and parallel runs muddy the log output.

### Step 4 — Report

End with this two-part recap. Use the `Status` enum: `passed`, `failed`, `skipped` (missing creds or non-Databricks server).

**Part 1 — outcome table.** One row per contract tested. Group the rows: output-port contracts first, then input-port contracts under a sub-header (so the reader sees the two roles at a glance).

| Contract | Role | Server | Result | Failures | Details |
|---|---|---|---|---|---|
| `<contract-file>` | `output` / `input` | `<server>` (`<catalog>.<schema>`) | `passed` / `failed` / `skipped` | count or `—` | one line per failing rule (field + rule), or "missing env var: …" if skipped |

**Part 2 — next steps.** Bullet list, include only what applies. Treat output vs. input failures differently:

- **Output-port failures**: surface the field and the violated check (e.g. `customers.customer_id: not_null violated for 17 rows`). The fix is in this project — either the dbt model is wrong, the contract is wrong, or the data is wrong. If the user wants a follow-up SQL to find the offending rows, suggest the shape but do not run it.
- **Input-port failures**: this is upstream drift. Name the provider data product and output port (from the contract id and file name). The fix is *not* in this project — the user should contact the upstream owner, and in the meantime expect downstream output-port failures. Suggest re-running `dataproduct-implement` once upstream republishes a corrected contract, so the cached snapshot under `models/input_ports/` refreshes.
- For each `skipped` row, the exact env vars the user needs to set, and where to get them (usually the workspace admin).
- `PERMISSION_DENIED` / `TABLE_OR_VIEW_NOT_FOUND` on an input port usually means the access agreement isn't provisioned as a Unity Catalog grant yet (`USE CATALOG`, `USE SCHEMA`, `SELECT`) — not drift.
- If failures look like a data quality issue (rules unchanged, data drifted), suggest investigating the upstream of the failing model — this skill does not auto-fix data.

If everything passed, write a single line: `All <N> contracts pass against <server>.`

## Databricks authentication

The Data Contract CLI reads credentials from environment variables, not from the contract file. Only the connection topology belongs in the `servers` block — always with an explicit `catalog`:

```yaml
servers:
  - server: production
    type: databricks
    host: adb-1234567890123456.7.azuredatabricks.net
    catalog: acme_prod
    schema: customers_v1
    customProperties:
      - property: httpPath          # informational; the CLI reads the HTTP path from env
        value: /sql/1.0/warehouses/abc123def456
```

There is no `table` in the server block: the table is the contract's `schema[].physicalName // name` (e.g. `customers`).

**Personal access token** (local runs):
```bash
export DATACONTRACT_DATABRICKS_SERVER_HOSTNAME=adb-1234567890123456.7.azuredatabricks.net
export DATACONTRACT_DATABRICKS_HTTP_PATH=/sql/1.0/warehouses/<warehouse-id>
export DATACONTRACT_DATABRICKS_TOKEN=dapi...
```

A PAT is long-lived until rotated. Scope it narrowly and avoid putting the `export` in `.bashrc`/`.zshrc`.

**Short-lived OAuth from a logged-in `databricks` CLI** (recommended for local runs):
```bash
export DATACONTRACT_DATABRICKS_TOKEN=$(databricks auth token --host "https://${DATABRICKS_HOST}" | jq -r .access_token)
```

**Service principal, OAuth M2M** — used for CI. Mint a ~1h token with the client-credentials grant:
```bash
export DATACONTRACT_DATABRICKS_TOKEN=$(curl -sf -X POST "https://${DATABRICKS_HOST}/oidc/v1/token" \
  -u "${DATABRICKS_CLIENT_ID}:${DATABRICKS_CLIENT_SECRET}" \
  -d 'grant_type=client_credentials&scope=all-apis' | jq -r .access_token)
export DATACONTRACT_DATABRICKS_SERVER_HOSTNAME=${DATABRICKS_HOST}
export DATACONTRACT_DATABRICKS_HTTP_PATH=${DATABRICKS_HTTP_PATH}
```

(Recent `datacontract-cli` releases can also do the exchange themselves from `DATACONTRACT_DATABRICKS_CLIENT_ID` / `DATACONTRACT_DATABRICKS_CLIENT_SECRET` when no token is set.) Grant the service principal `USE CATALOG`, `USE SCHEMA`, and `SELECT` on the schemas under test — nothing more.

**Azure Databricks with an Entra ID login** — an Entra access token for the Azure Databricks resource also works as the token:
```bash
export DATACONTRACT_DATABRICKS_TOKEN=$(az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv)
```

## Constraints

- **Read-only against Databricks.** This skill runs `datacontract test` which executes `SELECT` queries; it never writes. Do not invoke `datacontract publish`, `datacontract export`, or `entropy-data datacontracts put` from this skill.
- **No edits to contracts or models.** If a test fails, surface it — do not auto-patch the contract to make it pass. That defeats the purpose.
- **No credential sourcing.** If env vars are missing, tell the user; don't read them from `.env`, dotfiles, or anywhere else on the user's behalf.
- **Idempotent**: re-running the skill produces the same report against the same data. Failures from rules that depend on time (freshness, row-count windows) are expected to drift — note that in the failure detail when relevant.

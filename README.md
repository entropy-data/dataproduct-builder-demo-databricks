# dataproduct-builder-demo-databricks

Demo-grade coding-agent plugin for building **Databricks** (Unity Catalog) dbt data products with [Entropy Data](https://entropy-data.com).

This is the Databricks sibling of the Snowflake demo [dataproduct-builder-demo](https://github.com/entropy-data/dataproduct-builder-demo), and a streamlined derivative of the full [dataproduct-builder-dbt](https://github.com/entropy-data/dataproduct-builder-dbt): fewer skills, no platform branching, one batched question, and the implement skill runs dbt + tests + contract tests + OpenLineage on the spot so the data product shows up in Entropy Data in minutes.

## Skills

- **[dataproduct-bootstrap](skills/dataproduct-bootstrap/SKILL.md)** scaffolds a new Databricks dbt data product from scratch: `dbt_project.yml`, the `generate_schema_name` macro, model layout, README, `profiles.yml` + `profiles.yml.example`, ODPS, output-port ODCS, OpenLineage transport, and a GitHub Actions workflow. If the data product (and its contract) is already published on Entropy Data, it reuses them and only asks for the SQL warehouse.
- **[dataproduct-implement](skills/dataproduct-implement/SKILL.md)** fetches a published data product, derives dbt models from its purpose, ODCS contract, and input-port contracts, runs `dbt-ol run` (which ships lineage to Entropy Data immediately), runs `dbt test` and `datacontract test`, and marks the output port active on Entropy Data — end-to-end in one pass.
- **[datacontract-test](skills/datacontract-test/SKILL.md)** runs `datacontract test` against output-port and input-port ODCS files to verify the live Databricks data still matches the contract.

## Install

The skills are plain markdown; any coding agent that can read instruction files can run them.

### Claude Code

```
/plugin marketplace add https://github.com/entropy-data/dataproduct-builder-demo-databricks
/plugin install dataproduct-builder-demo-databricks@dataproduct-builder-demo-databricks
```

### OpenAI Codex

```
codex plugin marketplace add https://github.com/entropy-data/dataproduct-builder-demo-databricks
```

Then open Codex, run `/plugins`, and pick `dataproduct-builder-demo-databricks`.

### GitHub Copilot CLI

```
/plugin marketplace add https://github.com/entropy-data/dataproduct-builder-demo-databricks
/plugin install dataproduct-builder-demo-databricks@dataproduct-builder-demo-databricks
```

### Other agents (Cursor, Aider, etc.)

Any agent that reads `AGENTS.md` picks up the routing manifest. Or copy the `skills/` directory into the path your coding agent expects.

## Connect

Only [uv](https://docs.astral.sh/uv/) is required; the skills run dbt, dbt-ol, and the Data Contract CLI through it, pinned to Python 3.12:

```
uvx --python 3.12 --from dbt-core --with dbt-databricks dbt …
uvx --python 3.12 --from openlineage-dbt --with dbt-databricks dbt-ol …
uv tool run --from 'datacontract-cli[databricks]' datacontract …
```

### Entropy Data

The skills authenticate against Entropy Data through a connection registered with the [entropy-data CLI](https://github.com/entropy-data/entropy-data-cli).

Create a user-scoped key in the Entropy Data web UI (**Organization Settings → API Keys → Create new API key**, scope `User (personal token)`) and add the connection:

```
uv tool install --upgrade entropy-data
entropy-data connection add default --api-key <your-api-key> --host <your-entropy-data-host>
```

Also export the key as `ENTROPY_DATA_API_KEY` (the skills prefer it over the stored connection key). The contract lint hook needs it: contracts that link semantic business definitions are resolved through the Entropy Data API, and without a key the hook can only warn about them. If the semantics IRIs point at a different host than your connection, also set `ENTROPY_DATA_HOST` to that host.

```bash
export ENTROPY_DATA_API_KEY=<your-api-key>
```

### Databricks

dbt, the Data Contract CLI, and the CI workflow all read Databricks credentials from environment variables — nothing secret is written to a file (the generated project-local `profiles.yml` only holds `env_var()` references and is gitignored).

**dbt writes** — it creates the output-port and internal schemas, tables, and views — so it needs a principal with `CREATE SCHEMA` on the catalog (or pre-created schemas with `CREATE TABLE` / `CREATE VIEW`) and `SELECT` on the input ports. Either a user token or a writer service principal:

```bash
export DATABRICKS_HOST=adb-1234567890123456.7.azuredatabricks.net   # bare hostname, no https://
export DATABRICKS_HTTP_PATH=/sql/1.0/warehouses/<warehouse-id>

# a) user token: PAT, or an Azure AD (Entra) token of your login       -> dbt target dev
export DATABRICKS_TOKEN=<personal-access-token>
# export DATABRICKS_TOKEN=$(az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv)

# b) writer service principal, OAuth M2M                               -> dbt target prod
# export DATABRICKS_CLIENT_ID=<application-id>
# export DATABRICKS_CLIENT_SECRET=<databricks-oauth-secret>
```

**`datacontract test` only reads** (`USE CATALOG`, `USE SCHEMA`, `SELECT`), so a read-only service principal is enough. Mint a short-lived token for it:

```bash
export DATACONTRACT_DATABRICKS_SERVER_HOSTNAME=${DATABRICKS_HOST}
export DATACONTRACT_DATABRICKS_HTTP_PATH=${DATABRICKS_HTTP_PATH}
export DATACONTRACT_DATABRICKS_TOKEN=$(curl -sf -X POST "https://${DATABRICKS_HOST}/oidc/v1/token" \
  -u "${READONLY_CLIENT_ID}:${READONLY_CLIENT_SECRET}" \
  -d 'grant_type=client_credentials&scope=all-apis' | jq -r .access_token)
```

Without `DATACONTRACT_DATABRICKS_TOKEN`, the implement skill reuses the dbt token. With Azure AD tokens the tools may log `Token exchange failed, using external token` — harmless.

## Use

In an empty directory, ask the agent:

> Bootstrap a Databricks dbt data product *(optionally: for the data product url or id)*.

Then, once the scaffold is in place:

> Implement the data product *url or id*.

The implement skill runs end-to-end: it generates the models, runs `dbt-ol run` against your Databricks SQL warehouse, runs `dbt test`, runs `datacontract test`, and ships the OpenLineage event so the pipeline shows up in Entropy Data right away. The GitHub Actions workflow is written to the repo as a reference for production use.

## Unity Catalog naming convention

| Object | Convention | Example |
|---|---|---|
| Catalog | the organization's catalog | `acme_prod` |
| Output-port schema | the output-port / contract id, one schema per output port | `customers_v1` |
| Output-port table | the contract id without the `_v<N>` suffix | `customers` |
| Internal schema (staging + intermediate) | `<dbt_name>_internal` (data product id in snake_case), never granted to consumers | `regional_score_statistics_internal` |
| Input port (upstream) | `<catalog>.<upstream-output-port-id>.<table>`, declared as a dbt source | `acme_prod.orders_v2.orders` |

A `generate_schema_name` macro override makes dbt use `+schema` / `config(schema=...)` literally instead of prefixing the target schema, so `customers_v1` lands as `customers_v1`, not `customers_internal_customers_v1`.

## Databricks-only

This demo plugin drops multi-platform branching to keep the flow short. The user is asked one batched question, the templates are Databricks-shaped (Unity Catalog, Delta, Databricks SQL types), and the runtime invocations target the `dbt-databricks` adapter and the `datacontract-cli[databricks]` extras.

- For **Snowflake**, use the sibling demo at https://github.com/entropy-data/dataproduct-builder-demo.
- For **BigQuery / Postgres** or multi-platform projects, use the full builder at https://github.com/entropy-data/dataproduct-builder-dbt.

All three plugins can coexist.

## License

MIT

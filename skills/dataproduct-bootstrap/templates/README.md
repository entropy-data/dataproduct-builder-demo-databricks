# {{DATA_PRODUCT_NAME}}

dbt data product `{{DATA_PRODUCT_ID}}` (dbt project `{{DBT_NAME}}`) on Databricks (Unity Catalog). Published to [Entropy Data](https://entropy-data.com).

| | Unity Catalog location |
|---|---|
| Output port `{{OUTPUT_PORT_ID}}` | `{{CATALOG}}.{{SCHEMA}}.{{TABLE}}` |
| Staging / intermediate (internal) | `{{CATALOG}}.{{INTERNAL_SCHEMA}}` |

## Tools

Nothing to install besides [uv](https://docs.astral.sh/uv/) — the tools run through `uvx`, pinned to Python 3.12:

```bash
alias dbt='uvx --python 3.12 --from dbt-core --with dbt-databricks dbt'
alias dbt-ol='uvx --python 3.12 --from openlineage-dbt --with dbt-databricks dbt-ol'
alias datacontract="uv tool run --from 'datacontract-cli[databricks]' datacontract"
uv tool install entropy-data
```

## Configure

dbt uses the project-local `profiles.yml` (gitignored, created from `profiles.yml.example`, `env_var()` references only) — always pass `--profiles-dir .`:

```bash
cp -n profiles.yml.example profiles.yml
```

**dbt writes** (`CREATE SCHEMA` / `CREATE TABLE` / `CREATE VIEW` in `{{CATALOG}}.{{SCHEMA}}` and `{{CATALOG}}.{{INTERNAL_SCHEMA}}`, plus `SELECT` on the input-port schemas), so it needs a principal with write rights:

```bash
export DATABRICKS_HOST={{DATABRICKS_HOST}}            # bare hostname, no https://
export DATABRICKS_HTTP_PATH={{DATABRICKS_HTTP_PATH}}

# target dev (default): a token of a user or SP with write rights, e.g.
export DATABRICKS_TOKEN=<personal-access-token>
# or an Azure AD (Entra) token of your login:
# export DATABRICKS_TOKEN=$(az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv)

# target prod (CI): a writer service principal, OAuth M2M
# export DATABRICKS_CLIENT_ID=<application-id>
# export DATABRICKS_CLIENT_SECRET=<databricks-oauth-secret>
```

**`datacontract test` only reads** (`USE CATALOG`, `USE SCHEMA`, `SELECT`), so a read-only service principal is enough. It reads `DATACONTRACT_DATABRICKS_*`, not the dbt profile:

```bash
export DATACONTRACT_DATABRICKS_SERVER_HOSTNAME=${DATABRICKS_HOST}
export DATACONTRACT_DATABRICKS_HTTP_PATH=${DATABRICKS_HTTP_PATH}
export DATACONTRACT_DATABRICKS_TOKEN=$(curl -sf -X POST "https://${DATABRICKS_HOST}/oidc/v1/token" \
  -u "${READONLY_CLIENT_ID}:${READONLY_CLIENT_SECRET}" \
  -d 'grant_type=client_credentials&scope=all-apis' | jq -r .access_token)   # or reuse ${DATABRICKS_TOKEN}
```

With Azure AD tokens the tools may log `Token exchange failed, using external token` — harmless.

Entropy Data API key, for the OpenLineage transport and for resolving semantic references in `datacontract lint`:

```bash
export ENTROPY_DATA_API_KEY=<your-entropy-data-api-key>
export OPENLINEAGE__TRANSPORT__AUTH__APIKEY=${ENTROPY_DATA_API_KEY}
export OPENLINEAGE_NAMESPACE=databricks://${DATABRICKS_HOST}
```

## Run

```bash
dbt-ol run --profiles-dir .    # runs dbt and ships OpenLineage to Entropy Data
dbt test --profiles-dir .
datacontract test models/output_ports/v1/{{CONTRACT_FILE}} --server {{CONTRACT_SERVER}} --logs
```

## Layout

```
macros/generate_schema_name.sql  # use +schema / config(schema=...) literally
models/
├── input_ports/      # upstream data products: sources at <catalog>.<upstream-port-id>.<table>
├── staging/          # 1:1 cleaned views over input ports      -> {{INTERNAL_SCHEMA}}
├── intermediate/     # joined / shaped views                   -> {{INTERNAL_SCHEMA}}
└── output_ports/v1/  # published tables, one schema per output port, ODCS contract alongside
```

## Publishing

CI in `.github/workflows/data-product.yml` runs `dbt-ol run` / `dbt test` as a writer service principal (OAuth M2M, target `prod`), publishes `{{ODPS_FILE}}` + the ODCS to Entropy Data, and runs the data contract test against server `{{CONTRACT_SERVER}}`. CI publishes the local `{{ODPS_FILE}}`, so keep it in sync with Entropy Data (`entropy-data dataproducts get {{DATA_PRODUCT_ID}} -o yaml > {{ODPS_FILE}}`) — otherwise CI overwrites metadata edited in the web UI.

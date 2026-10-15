# {{DATA_PRODUCT_NAME}}

dbt data product `{{DATA_PRODUCT_ID}}` on Databricks (Unity Catalog). Published to [Entropy Data](https://entropy-data.com).

| | Unity Catalog location |
|---|---|
| Output port `{{OUTPUT_PORT_ID}}` | `{{CATALOG}}.{{SCHEMA}}.{{TABLE}}` |
| Staging / intermediate (internal) | `{{CATALOG}}.{{INTERNAL_SCHEMA}}` |

## Install

```bash
uv venv
source .venv/bin/activate
uv pip install dbt-core dbt-databricks openlineage-dbt 'datacontract-cli[databricks]' entropy-data
```

## Configure

Copy `profiles.yml.example` to `~/.dbt/profiles.yml` (or merge it in). It reads all connection details from environment variables:

```bash
export DATABRICKS_HOST={{DATABRICKS_HOST}}            # bare hostname, no https://
export DATABRICKS_HTTP_PATH={{DATABRICKS_HTTP_PATH}}
export DATABRICKS_TOKEN=<personal-access-token>
```

Service principal (OAuth M2M) instead of a PAT — mint a short-lived token (valid ~1h):

```bash
export DATABRICKS_CLIENT_ID=<application-id>
export DATABRICKS_CLIENT_SECRET=<databricks-oauth-secret>
export DATABRICKS_TOKEN=$(curl -s -X POST "https://${DATABRICKS_HOST}/oidc/v1/token" \
  -u "${DATABRICKS_CLIENT_ID}:${DATABRICKS_CLIENT_SECRET}" \
  -d 'grant_type=client_credentials&scope=all-apis' | jq -r .access_token)
```

Set the Entropy Data API key for the OpenLineage transport, and the job namespace:

```bash
export OPENLINEAGE__TRANSPORT__AUTH__APIKEY=<your-entropy-data-api-key>
export OPENLINEAGE_NAMESPACE=databricks://${DATABRICKS_HOST}
```

Set the Data Contract CLI credentials (it reads `DATACONTRACT_DATABRICKS_*` env vars, not `~/.dbt/profiles.yml`):

```bash
export DATACONTRACT_DATABRICKS_SERVER_HOSTNAME=${DATABRICKS_HOST}
export DATACONTRACT_DATABRICKS_HTTP_PATH=${DATABRICKS_HTTP_PATH}
export DATACONTRACT_DATABRICKS_TOKEN=${DATABRICKS_TOKEN}
```

## Run

```bash
source .venv/bin/activate
dbt-ol run    # runs dbt and ships OpenLineage to Entropy Data
dbt test
datacontract test models/output_ports/v1/{{CONTRACT_FILE}} --server production --logs
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

CI in `.github/workflows/data-product.yml` mints an OAuth M2M token for a service principal, runs `dbt-ol run`, `dbt test`, publishes the ODPS + ODCS to Entropy Data, and runs the data contract test.

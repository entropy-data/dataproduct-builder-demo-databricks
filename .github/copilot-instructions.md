# Copilot instructions — dataproduct-builder-demo-databricks

This repository is a coding-agent plugin that helps build **Databricks** (Unity Catalog) dbt data products and integrate them with [Entropy Data](https://entropy-data.com). It is the Databricks sibling of [dataproduct-builder-demo](https://github.com/entropy-data/dataproduct-builder-demo) (Snowflake) and a streamlined demo derivative of [dataproduct-builder-dbt](https://github.com/entropy-data/dataproduct-builder-dbt).

Capabilities are exposed as **skills** — markdown files under `skills/<name>/SKILL.md` that the agent reads top-to-bottom and executes step by step.

## Routing

When a user request matches a skill's trigger, **read the corresponding `SKILL.md` start to finish before acting.**

| When the user asks about… | Follow this skill |
|---|---|
| Scaffolding a brand-new Databricks dbt data product from scratch | `skills/dataproduct-bootstrap/SKILL.md` |
| Implementing a data product from a published Entropy Data URL or id, running dbt + OpenLineage + dbt tests + data contract tests | `skills/dataproduct-implement/SKILL.md` |
| Testing existing data contracts against the live Databricks SQL warehouse | `skills/datacontract-test/SKILL.md` |

The trigger phrasing above is illustrative; each `SKILL.md`'s frontmatter `description` is authoritative.

## Resolving `${PLUGIN_ROOT}`

Skill files reference `${PLUGIN_ROOT}` to locate `templates/`. On Claude Code it is set automatically as `${CLAUDE_PLUGIN_ROOT}`. On Copilot / Codex / Cursor, it is **not** set — resolve it as the directory containing `AGENTS.md` and `skills/`.

## CLIs the skills shell out to

- **`entropy-data`** — fetch and publish data products / contracts.
- **`dbt`** (`dbt-databricks` adapter) — required by both skills.
- **`dbt-ol`** (`openlineage-dbt`) — runs dbt with OpenLineage so lineage ships to Entropy Data on the spot (namespace `databricks://<host>`).
- **`datacontract`** (`datacontract-cli[databricks]`) — runs contract tests against Databricks.

If any CLI is missing, surface the install line and stop.

## Conventions

- **Databricks only.** If the user's dbt profile is not `type: databricks`, stop and point them at https://github.com/entropy-data/dataproduct-builder-demo (Snowflake) or https://github.com/entropy-data/dataproduct-builder-dbt (multi-platform).
- **Unity Catalog naming.** One schema per output port named after the output-port / contract id (`customers_v1`), table = contract id without `_v<N>` (`customers`), staging/intermediate in `<data-product-id>_internal`.
- **Don't skip pre-checks.** Both skills verify CLI presence and Entropy Data connection first.
- **Don't overwrite existing files silently.** Surface the diff and ask.
- **Don't run `git init`, commit, or push.** Leave VCS state to the user.
- **Don't commit secrets.** API keys and Databricks tokens / client secrets must come from env vars or repo secrets.
- **Idempotent re-runs**, except `dbt run` / `dbt test` / `datacontract test` which always execute.

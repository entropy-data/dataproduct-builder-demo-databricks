{#-
  Use `+schema` / config(schema=...) literally instead of dbt's default
  `<target_schema>_<custom_schema>` concatenation, so output-port models land in
  the Unity Catalog schema named after the output port (e.g. `customers_v1`)
  and staging / intermediate land in `<dbt_name>_internal`.
  Models without a custom schema fall back to the profile's `schema:`.
-#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}

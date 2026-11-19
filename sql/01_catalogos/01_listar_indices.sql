-- =============================================================================
-- Parte 1 — Questão 1: Listagem de Índices via Catálogo
-- Arquivo: sql/01_catalogos/01_listar_indices.sql
--
-- Descrição:
--   Consulta as tabelas de catálogo do PostgreSQL (pg_index, pg_class,
--   pg_namespace, pg_am) para listar todos os índices existentes acompanhados
--   das respectivas tabelas, métodos de acesso, colunas-chave, colunas INCLUDE
--   e flags estruturais.
-- =============================================================================

CREATE OR REPLACE FUNCTION bd2_meta.listar_indices(
    p_schema text DEFAULT NULL,
    p_incluir_sistema boolean DEFAULT false
)
RETURNS TABLE (
    schema_name text,
    table_name text,
    index_name text,
    access_method text,
    key_columns text[],
    include_columns text[],
    is_unique boolean,
    is_primary boolean,
    is_exclusion boolean,
    is_partial boolean,
    index_definition text
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        ns.nspname::text AS schema_name,
        tbl.relname::text AS table_name,
        idx.relname::text AS index_name,
        am.amname::text AS access_method,
        COALESCE(
            ARRAY(
                SELECT pg_get_indexdef(i.indexrelid, k, true)
                FROM generate_series(1, i.indnkeyatts) AS k
                ORDER BY k
            ),
            ARRAY[]::text[]
        ) AS key_columns,
        COALESCE(
            ARRAY(
                SELECT pg_get_indexdef(i.indexrelid, k, true)
                FROM generate_series(i.indnkeyatts + 1, i.indnatts) AS k
                ORDER BY k
            ),
            ARRAY[]::text[]
        ) AS include_columns,
        i.indisunique AS is_unique,
        i.indisprimary AS is_primary,
        i.indisexclusion AS is_exclusion,
        (i.indpred IS NOT NULL) AS is_partial,
        pg_get_indexdef(i.indexrelid)::text AS index_definition
    FROM pg_index i
    JOIN pg_class idx ON idx.oid = i.indexrelid
    JOIN pg_class tbl ON tbl.oid = i.indrelid
    JOIN pg_namespace ns ON ns.oid = tbl.relnamespace
    JOIN pg_am am ON am.oid = idx.relam
    -- r: tabela, p: tabela particionada, m: visão materializada, t: tabela TOAST
    -- (as TOAST ficam no schema pg_toast, listado só com p_incluir_sistema)
    WHERE tbl.relkind IN ('r', 'p', 'm', 't')
      AND (
          p_incluir_sistema
          OR (
              ns.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
              AND ns.nspname NOT LIKE 'pg_temp_%'
              AND ns.nspname NOT LIKE 'pg_toast_temp_%'
          )
      )
      AND (p_schema IS NULL OR ns.nspname = p_schema)
    ORDER BY ns.nspname, tbl.relname, idx.relname;
$$;

CREATE OR REPLACE VIEW bd2_meta.vw_indices AS
SELECT *
FROM bd2_meta.listar_indices(NULL, false);

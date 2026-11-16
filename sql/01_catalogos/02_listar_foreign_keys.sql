-- =============================================================================
-- Parte 1 — Questão 3: Listagem de Chaves Estrangeiras via Catálogo
-- Arquivo: sql/01_catalogos/02_listar_foreign_keys.sql
--
-- Descrição:
--   Consulta pg_constraint (contype = 'f'), pg_class, pg_namespace e
--   pg_attribute pareando conkey e confkey por posição para listar todas as
--   chaves estrangeiras com tabelas, colunas locais/referenciadas e ações.
-- =============================================================================

CREATE OR REPLACE FUNCTION bd2_meta.listar_foreign_keys(
    p_schema text DEFAULT NULL
)
RETURNS TABLE (
    constraint_name text,
    local_schema text,
    local_table text,
    local_column text,
    ref_schema text,
    ref_table text,
    ref_column text,
    key_position integer,
    on_update text,
    on_delete text,
    match_type text,
    is_deferrable boolean,
    is_deferred boolean,
    is_validated boolean
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        c.conname::text AS constraint_name,
        ns_local.nspname::text AS local_schema,
        tbl_local.relname::text AS local_table,
        att_local.attname::text AS local_column,
        ns_ref.nspname::text AS ref_schema,
        tbl_ref.relname::text AS ref_table,
        att_ref.attname::text AS ref_column,
        u.pos::integer AS key_position,
        CASE c.confupdtype
            WHEN 'a' THEN 'NO ACTION'
            WHEN 'r' THEN 'RESTRICT'
            WHEN 'c' THEN 'CASCADE'
            WHEN 'n' THEN 'SET NULL'
            WHEN 'd' THEN 'SET DEFAULT'
            ELSE c.confupdtype::text
        END AS on_update,
        CASE c.confdeltype
            WHEN 'a' THEN 'NO ACTION'
            WHEN 'r' THEN 'RESTRICT'
            WHEN 'c' THEN 'CASCADE'
            WHEN 'n' THEN 'SET NULL'
            WHEN 'd' THEN 'SET DEFAULT'
            ELSE c.confdeltype::text
        END AS on_delete,
        CASE c.confmatchtype
            WHEN 'f' THEN 'FULL'
            WHEN 'p' THEN 'PARTIAL'
            WHEN 's' THEN 'SIMPLE'
            ELSE c.confmatchtype::text
        END AS match_type,
        c.condeferrable AS is_deferrable,
        c.condeferred AS is_deferred,
        c.convalidated AS is_validated
    FROM pg_constraint c
    JOIN pg_class tbl_local ON tbl_local.oid = c.conrelid
    JOIN pg_namespace ns_local ON ns_local.oid = tbl_local.relnamespace
    JOIN pg_class tbl_ref ON tbl_ref.oid = c.confrelid
    JOIN pg_namespace ns_ref ON ns_ref.oid = tbl_ref.relnamespace
    CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS u(attnum_local, attnum_ref, pos)
    JOIN pg_attribute att_local
      ON att_local.attrelid = c.conrelid
     AND att_local.attnum = u.attnum_local
    JOIN pg_attribute att_ref
      ON att_ref.attrelid = c.confrelid
     AND att_ref.attnum = u.attnum_ref
    WHERE c.contype = 'f'
      AND (
          p_schema IS NULL
          OR ns_local.nspname = p_schema
      )
    ORDER BY ns_local.nspname, tbl_local.relname, c.conname, u.pos;
$$;

CREATE OR REPLACE VIEW bd2_meta.vw_foreign_keys AS
SELECT *
FROM bd2_meta.listar_foreign_keys(NULL);

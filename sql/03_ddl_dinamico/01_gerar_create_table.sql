-- =============================================================================
-- Parte 1 — Questão 4: Geração Dinâmica de CREATE TABLE a partir do Catálogo
-- Arquivo: sql/03_ddl_dinamico/01_gerar_create_table.sql
--
-- Descrição:
--   Gera dinamicamente o script DDL (CREATE TABLE + PK + FK) das tabelas
--   regulares (relkind = 'r') de um schema de origem, remapeando para o schema
--   de destino informado. Retorna texto DDL em duas fases sem executá-lo.
--
-- Limites declarados:
--   - Escopo mínimo exigido: colunas, tipos, NOT NULL, PK e FK.
--   - Não gera defaults/nextval/sequences, IDENTITY, UNIQUE, CHECK, índices,
--     comentários, tabelas particionadas, estrangeiras ou herança.
-- =============================================================================

CREATE OR REPLACE FUNCTION bd2_meta.gerar_ddl_tabelas(
    p_schema_origem text,
    p_schema_destino text,
    p_incluir_fks boolean DEFAULT true
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ddl text := '';
    v_tbl record;
    v_cols text;
    v_pk text;
    v_fk record;
    v_fk_local_cols text;
    v_fk_ref_cols text;
    v_fk_ref_schema text;
    v_fk_clauses text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = p_schema_origem) THEN
        RAISE EXCEPTION 'Schema de origem "%" não encontrado.', p_schema_origem;
    END IF;

    v_ddl := format(
        E'-- DDL gerado dinamicamente a partir do schema %I para %I\nCREATE SCHEMA IF NOT EXISTS %I;\n\n',
        p_schema_origem,
        p_schema_destino,
        p_schema_destino
    );

    -- Fase A: CREATE TABLE + PRIMARY KEY
    FOR v_tbl IN
        SELECT c.oid AS relid, c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = p_schema_origem
          AND c.relkind = 'r'
        ORDER BY c.relname
    LOOP
        SELECT string_agg(
            format(
                '    %I %s%s',
                a.attname,
                format_type(a.atttypid, a.atttypmod),
                CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
            ),
            E',\n'
            ORDER BY a.attnum
        )
        INTO v_cols
        FROM pg_attribute a
        WHERE a.attrelid = v_tbl.relid
          AND a.attnum > 0
          AND NOT a.attisdropped;

        SELECT format(
            '    CONSTRAINT %I %s',
            con.conname,
            pg_get_constraintdef(con.oid, true)
        )
        INTO v_pk
        FROM pg_constraint con
        WHERE con.conrelid = v_tbl.relid
          AND con.contype = 'p';

        v_ddl := v_ddl || format(
            E'CREATE TABLE %I.%I (\n%s%s\n);\n\n',
            p_schema_destino,
            v_tbl.table_name,
            COALESCE(v_cols, ''),
            CASE WHEN v_pk IS NOT NULL THEN E',\n' || v_pk ELSE '' END
        );
    END LOOP;

    -- Fase B: ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY
    IF p_incluir_fks THEN
        FOR v_fk IN
            SELECT
                con.oid AS conid,
                con.conname AS constraint_name,
                tbl_local.relname AS local_table,
                ns_ref.nspname AS ref_schema_orig,
                tbl_ref.relname AS ref_table,
                con.conrelid,
                con.confrelid,
                con.conkey,
                con.confkey,
                con.confupdtype,
                con.confdeltype,
                con.confmatchtype,
                con.condeferrable,
                con.condeferred
            FROM pg_constraint con
            JOIN pg_class tbl_local ON tbl_local.oid = con.conrelid
            JOIN pg_namespace ns_local ON ns_local.oid = tbl_local.relnamespace
            JOIN pg_class tbl_ref ON tbl_ref.oid = con.confrelid
            JOIN pg_namespace ns_ref ON ns_ref.oid = tbl_ref.relnamespace
            WHERE con.contype = 'f'
              AND ns_local.nspname = p_schema_origem
              AND tbl_local.relkind = 'r'
            ORDER BY tbl_local.relname, con.conname
        LOOP
            SELECT
                string_agg(format('%I', att_local.attname), ', ' ORDER BY u.pos),
                string_agg(format('%I', att_ref.attname), ', ' ORDER BY u.pos)
            INTO v_fk_local_cols, v_fk_ref_cols
            FROM unnest(v_fk.conkey, v_fk.confkey) WITH ORDINALITY AS u(attnum_local, attnum_ref, pos)
            JOIN pg_attribute att_local
              ON att_local.attrelid = v_fk.conrelid
             AND att_local.attnum = u.attnum_local
            JOIN pg_attribute att_ref
              ON att_ref.attrelid = v_fk.confrelid
             AND att_ref.attnum = u.attnum_ref;

            v_fk_ref_schema := CASE
                WHEN v_fk.ref_schema_orig = p_schema_origem THEN p_schema_destino
                ELSE v_fk.ref_schema_orig
            END;

            v_fk_clauses := '';
            IF v_fk.confmatchtype = 'f' THEN
                v_fk_clauses := v_fk_clauses || ' MATCH FULL';
            END IF;
            IF v_fk.confupdtype <> 'a' THEN
                v_fk_clauses := v_fk_clauses || ' ON UPDATE ' || CASE v_fk.confupdtype
                    WHEN 'r' THEN 'RESTRICT'
                    WHEN 'c' THEN 'CASCADE'
                    WHEN 'n' THEN 'SET NULL'
                    WHEN 'd' THEN 'SET DEFAULT'
                END;
            END IF;
            IF v_fk.confdeltype <> 'a' THEN
                v_fk_clauses := v_fk_clauses || ' ON DELETE ' || CASE v_fk.confdeltype
                    WHEN 'r' THEN 'RESTRICT'
                    WHEN 'c' THEN 'CASCADE'
                    WHEN 'n' THEN 'SET NULL'
                    WHEN 'd' THEN 'SET DEFAULT'
                END;
            END IF;
            IF v_fk.condeferrable THEN
                v_fk_clauses := v_fk_clauses || ' DEFERRABLE' ||
                    CASE WHEN v_fk.condeferred THEN ' INITIALLY DEFERRED' ELSE ' INITIALLY IMMEDIATE' END;
            END IF;

            v_ddl := v_ddl || format(
                E'ALTER TABLE %I.%I ADD CONSTRAINT %I FOREIGN KEY (%s) REFERENCES %I.%I (%s)%s;\n',
                p_schema_destino,
                v_fk.local_table,
                v_fk.constraint_name,
                v_fk_local_cols,
                v_fk_ref_schema,
                v_fk.ref_table,
                v_fk_ref_cols,
                v_fk_clauses
            );
        END LOOP;
    END IF;

    RETURN v_ddl;
END;
$$;

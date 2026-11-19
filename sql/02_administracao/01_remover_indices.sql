-- =============================================================================
-- Parte 1 — Questão 2: Procedimento para Remoção de Índices de uma Tabela
-- Arquivo: sql/02_administracao/01_remover_indices.sql
--
-- Descrição:
--   Remove índices de uma tabela informada por parâmetro (schema + tabela).
--   Diferencia índices independentes (DROP INDEX) de índices que sustentam
--   constraints PK/UNIQUE/EXCLUDE (ALTER TABLE ... DROP CONSTRAINT).
--   Por padrão preserva constraints e nunca aplica CASCADE sem pedido explícito.
-- =============================================================================

CREATE OR REPLACE PROCEDURE bd2_meta.remover_indices_tabela(
    p_schema text,
    p_tabela text,
    p_incluir_constraints boolean DEFAULT false,
    p_cascade boolean DEFAULT false,
    INOUT p_resumo jsonb DEFAULT '[]'::jsonb
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_relid oid;
    v_rec record;
    v_acao text;
    v_resultado text;
BEGIN
    p_resumo := '[]'::jsonb;

    SELECT c.oid
      INTO v_relid
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = p_schema
       AND c.relname = p_tabela
       AND c.relkind IN ('r', 'p');

    IF v_relid IS NULL THEN
        RAISE EXCEPTION 'Tabela %.% não encontrada.', p_schema, p_tabela;
    END IF;

    FOR v_rec IN
        SELECT
            idx.relname AS index_name,
            con.conname AS constraint_name,
            con.contype AS constraint_type
        FROM pg_index i
        JOIN pg_class idx ON idx.oid = i.indexrelid
        LEFT JOIN pg_constraint con
               ON con.conindid = i.indexrelid
              AND con.conrelid = i.indrelid
              AND con.contype IN ('p', 'u', 'x')
        WHERE i.indrelid = v_relid
        ORDER BY (con.oid IS NOT NULL), idx.relname
    LOOP
        IF v_rec.constraint_name IS NULL THEN
            v_acao := 'DROP INDEX';
            EXECUTE format('DROP INDEX %I.%I', p_schema, v_rec.index_name);
            v_resultado := 'REMOVIDO';
        ELSIF NOT p_incluir_constraints THEN
            v_acao := format('PRESERVAR CONSTRAINT (%s)', v_rec.constraint_type);
            v_resultado := 'PRESERVADO';
        ELSE
            v_acao := format(
                'DROP CONSTRAINT (%s) %s',
                v_rec.constraint_type,
                CASE WHEN p_cascade THEN 'CASCADE' ELSE 'RESTRICT' END
            );
            EXECUTE format(
                'ALTER TABLE %I.%I DROP CONSTRAINT %I %s',
                p_schema,
                p_tabela,
                v_rec.constraint_name,
                CASE WHEN p_cascade THEN 'CASCADE' ELSE 'RESTRICT' END
            );
            v_resultado := 'REMOVIDO';
        END IF;

        p_resumo := p_resumo || jsonb_build_array(
            jsonb_build_object(
                'objeto', v_rec.index_name,
                'constraint', v_rec.constraint_name,
                'tipo', COALESCE(v_rec.constraint_type::text, 'INDEX'),
                'acao', v_acao,
                'resultado', v_resultado
            )
        );

        RAISE NOTICE 'Tabela %.% | Objeto: % | Ação: % | Resultado: %',
            p_schema, p_tabela, v_rec.index_name, v_acao, v_resultado;
    END LOOP;
END;
$$;

-- Procedimento administrativo e destrutivo: não fica disponível a PUBLIC.
-- (Só o dono das tabelas consegue remover índices, mas o EXECUTE também é
--  restrito para que usuários comuns não tenham acesso a ele.)
REVOKE ALL ON PROCEDURE bd2_meta.remover_indices_tabela(text, text, boolean, boolean, jsonb) FROM PUBLIC;

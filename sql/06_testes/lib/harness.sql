-- =============================================================================
-- Harness de testes (incluído por cada arquivo de teste com \ir lib/harness.sql)
-- Arquivo: sql/06_testes/lib/harness.sql
--
--   pg_temp.caso(caso, operacao, sql, esperado, sqlstate, papel)
--       Executa `sql` (opcionalmente como `papel`, via SET ROLE), registra
--       ACEITO / REJEITADO(<SQLSTATE>) e compara com o esperado.
--       Se `sql` tiver RETURNING ou for CALL de procedure com parâmetro INOUT
--       (verificado no catálogo), devolve o valor retornado (ex.: id criado).
--   pg_temp.verifica(caso, operacao, condicao)
--       Registra uma pós-condição booleana.
--
-- Os resultados vão para a tabela temporária resultado_teste, impressa e
-- verificada por lib/resumo.sql (falha com ON_ERROR_STOP se algo divergir).
-- =============================================================================

\set QUIET on
SET client_min_messages = notice;

CREATE TEMP TABLE IF NOT EXISTS resultado_teste (
    ordem      integer GENERATED ALWAYS AS IDENTITY,
    caso       text,
    operacao   text,
    esperado   text,
    obtido     text,
    ok         boolean,
    detalhe    text
);
TRUNCATE resultado_teste;

-- O CALL devolve uma linha? (procedure com parâmetro INOUT/OUT, consultado no catálogo)
CREATE OR REPLACE FUNCTION pg_temp.call_devolve_linha(p_sql text) RETURNS boolean
LANGUAGE sql AS $$
    SELECT COALESCE(bool_or(p.proargmodes && ARRAY['b', 'o']::"char"[]), false)
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN LATERAL parse_ident(substring(p_sql FROM '^\s*[Cc][Aa][Ll][Ll]\s+([A-Za-z0-9_."]+)\s*\(')) AS id(partes) ON true
     WHERE p.prokind = 'p'
       AND p.proname = id.partes[array_length(id.partes, 1)]
       AND (array_length(id.partes, 1) = 1 OR n.nspname = id.partes[1]);
$$;

CREATE OR REPLACE FUNCTION pg_temp.caso(
    p_caso      text,
    p_operacao  text,
    p_sql       text,
    p_esperado  text,               -- 'ACEITO' | 'REJEITADO'
    p_sqlstate  text DEFAULT NULL,  -- SQLSTATE esperado quando REJEITADO
    p_papel     text DEFAULT NULL   -- executar como este papel (SET ROLE)
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_id      integer;
    v_obtido  text;
    v_state   text;
    v_msg     text;
    v_ok      boolean;
BEGIN
    BEGIN
        IF p_papel IS NOT NULL THEN
            EXECUTE format('SET ROLE %I', p_papel);
        END IF;

        IF p_sql ~* '\mreturning\M' THEN
            EXECUTE p_sql INTO v_id;
        ELSIF p_sql ~* '^\s*call\M' AND pg_temp.call_devolve_linha(p_sql) THEN
            -- CALL de procedure com parâmetro INOUT/OUT devolve uma linha
            EXECUTE p_sql INTO v_id;
        ELSE
            EXECUTE p_sql;
        END IF;

        IF p_papel IS NOT NULL THEN
            RESET ROLE;
        END IF;
        v_obtido := 'ACEITO';
    EXCEPTION WHEN OTHERS THEN
        -- o rollback da subtransação desfaz a operação e também o SET ROLE
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        v_obtido := 'REJEITADO';
    END;

    v_ok := v_obtido = p_esperado
            AND (p_sqlstate IS NULL OR v_obtido = 'ACEITO' OR v_state = p_sqlstate);

    INSERT INTO resultado_teste (caso, operacao, esperado, obtido, ok, detalhe)
    VALUES (p_caso, p_operacao,
            p_esperado || COALESCE(' (' || p_sqlstate || ')', ''),
            v_obtido   || COALESCE(' (' || v_state    || ')', ''),
            v_ok, v_msg);

    RAISE NOTICE '[%] % | % | esperado: % | obtido: % %',
        CASE WHEN v_ok THEN 'OK' ELSE 'FALHOU' END, p_caso, p_operacao, p_esperado, v_obtido,
        COALESCE(' — ' || v_msg, '');
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.verifica(p_caso text, p_operacao text, p_condicao boolean)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO resultado_teste (caso, operacao, esperado, obtido, ok)
    VALUES (p_caso, p_operacao, 'VERDADEIRO',
            CASE WHEN p_condicao THEN 'VERDADEIRO' WHEN NOT p_condicao THEN 'FALSO' ELSE 'NULO' END,
            COALESCE(p_condicao, false));
    RAISE NOTICE '[%] % | %',
        CASE WHEN COALESCE(p_condicao, false) THEN 'OK' ELSE 'FALHOU' END, p_caso, p_operacao;
END;
$$;

\set QUIET off

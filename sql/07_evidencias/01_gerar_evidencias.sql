-- =============================================================================
-- Geração de evidências para o relatório
-- Arquivo: sql/07_evidencias/01_gerar_evidencias.sql
--
-- Grava em :evid_dir (ex.: psql -v evid_dir=evidencias) a saída REAL das
-- consultas e rotinas de cada questão. O relatório inclui esses arquivos.
-- Executado pelo run_all.sh depois de toda a instalação e dos testes.
-- Não altera o Chinook: o que é criado em bd2_demo é removido no fim.
-- =============================================================================

\if :{?evid_dir}
\else
    \echo 'Defina o diretório de saída: psql -v evid_dir=evidencias ...'
    \quit
\endif

\set QUIET on
\pset footer on
\pset null '∅'

-- Tenta executar um comando e devolve ACEITO ou a mensagem de erro (sem abortar).
CREATE OR REPLACE FUNCTION pg_temp.tenta(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RETURN 'ACEITO';
EXCEPTION WHEN OTHERS THEN
    RETURN 'REJEITADO [' || SQLSTATE || ']: ' || SQLERRM;
END;
$$;

-- Chama a procedure da Q2 e devolve o resumo (INOUT p_resumo) como tabela.
CREATE OR REPLACE FUNCTION pg_temp.q2(p_schema text, p_tabela text, p_incluir_constraints boolean,
                                       p_cascade boolean DEFAULT false)
RETURNS TABLE (objeto text, tipo text, acao text, resultado text)
LANGUAGE plpgsql AS $$
DECLARE
    v_resumo jsonb;
BEGIN
    CALL bd2_meta.remover_indices_tabela(p_schema, p_tabela, p_incluir_constraints, p_cascade, v_resumo);
    RETURN QUERY SELECT * FROM jsonb_to_recordset(v_resumo) AS r(objeto text, tipo text, acao text, resultado text);
END;
$$;

-- -----------------------------------------------------------------------------
-- Ambiente
-- -----------------------------------------------------------------------------
\o :evid_dir/00_ambiente.txt
SELECT version() AS versao_postgresql;
SELECT current_database() AS banco,
       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r') AS tabelas_em_public;
SELECT nspname AS schema, pg_get_userbyid(nspowner) AS dono
  FROM pg_namespace WHERE nspname IN ('public', 'bd2_meta', 'bd2_demo') ORDER BY 1;

-- -----------------------------------------------------------------------------
-- P1-Q1: índices do esquema exemplo
-- -----------------------------------------------------------------------------
\o :evid_dir/p1_q1_indices.txt
SELECT table_name AS tabela,
       index_name AS indice,
       array_to_string(key_columns, ', ') AS colunas,
       access_method AS metodo,
       CASE WHEN is_primary THEN 'PK' WHEN is_unique THEN 'UNIQUE' ELSE '' END AS tipo
  FROM bd2_meta.listar_indices('public')
 ORDER BY table_name, index_name;
\qecho '== Total de índices por schema (listar_indices() sem filtro de schema; sistema excluído)'
SELECT schema_name AS schema, count(*) AS indices
  FROM bd2_meta.listar_indices()
 GROUP BY schema_name ORDER BY schema_name;

-- -----------------------------------------------------------------------------
-- P1-Q2: remoção de índices — tabela REAL do Chinook (public.invoice_line),
--        dentro de uma transação desfeita no fim (o esquema exemplo não é alterado)
-- -----------------------------------------------------------------------------
\o :evid_dir/p1_q2_remocao_indices.txt
BEGIN;
\qecho '== Tudo abaixo (passos 1 a 5) ocorre numa transação desfeita com ROLLBACK no fim.'
\qecho '== 1. Índices de public.invoice_line ANTES da remoção'
SELECT index_name AS indice, array_to_string(key_columns, ', ') AS colunas,
       CASE WHEN is_primary THEN 'PK' WHEN is_unique THEN 'UNIQUE' ELSE 'independente' END AS tipo
  FROM bd2_meta.listar_indices('public') WHERE table_name = 'invoice_line' ORDER BY 1;

\qecho '== 2. CALL bd2_meta.remover_indices_tabela(''public'', ''invoice_line'')   -- padrão seguro'
SELECT * FROM pg_temp.q2('public', 'invoice_line', false);

\qecho '== 3. Índices restantes (somente o que sustenta a PK)'
SELECT index_name AS indice, array_to_string(key_columns, ', ') AS colunas,
       CASE WHEN is_primary THEN 'PK' WHEN is_unique THEN 'UNIQUE' ELSE 'independente' END AS tipo
  FROM bd2_meta.listar_indices('public') WHERE table_name = 'invoice_line' ORDER BY 1;

\qecho '== 4. CALL bd2_meta.remover_indices_tabela(''public'', ''invoice_line'', p_incluir_constraints => true)   -- remove TODOS'
SELECT * FROM pg_temp.q2('public', 'invoice_line', true);

\qecho '== 5. Índices restantes em public.invoice_line após remover TODOS'
SELECT count(*) AS indices_restantes
  FROM bd2_meta.listar_indices('public') WHERE table_name = 'invoice_line';
ROLLBACK;

\qecho '== 6. Após o ROLLBACK, public.invoice_line voltou a ter seus índices'
SELECT count(*) AS indices FROM bd2_meta.listar_indices('public') WHERE table_name = 'invoice_line';

\qecho '== 7. Proteção: remover a PK de public.employee SEM cascade (outras tabelas a referenciam)'
SELECT pg_temp.tenta($$CALL bd2_meta.remover_indices_tabela('public', 'employee', p_incluir_constraints => true)$$) AS resultado;

BEGIN;
\qecho '== 8. public.employee COM p_cascade => true (transação desfeita com ROLLBACK no fim)'
\qecho '==    FKs que referenciam employee antes da remoção:'
SELECT constraint_name AS fk, local_table || '(' || local_column || ')' AS origem
  FROM bd2_meta.listar_foreign_keys('public') WHERE ref_table = 'employee' ORDER BY 1;
\qecho '==    CALL bd2_meta.remover_indices_tabela(''public'', ''employee'', p_incluir_constraints => true, p_cascade => true)'
SELECT * FROM pg_temp.q2('public', 'employee', true, true);
\qecho '==    Depois: índices restantes em employee e FKs que ainda o referenciam'
SELECT (SELECT count(*) FROM bd2_meta.listar_indices('public') WHERE table_name = 'employee') AS indices_restantes,
       (SELECT count(*) FROM bd2_meta.listar_foreign_keys('public') WHERE ref_table = 'employee') AS fks_restantes;
ROLLBACK;
\qecho '== 9. Após o ROLLBACK, employee voltou a ter seus índices e FKs'
SELECT (SELECT count(*) FROM bd2_meta.listar_indices('public') WHERE table_name = 'employee') AS indices,
       (SELECT count(*) FROM bd2_meta.listar_foreign_keys('public') WHERE ref_table = 'employee') AS fks;
\o

-- -----------------------------------------------------------------------------
-- P1-Q3: chaves estrangeiras
-- -----------------------------------------------------------------------------
\o :evid_dir/p1_q3_foreign_keys.txt
SELECT constraint_name AS fk,
       local_table || '(' || local_column || ')' AS origem,
       ref_table   || '(' || ref_column   || ')' AS referencia,
       on_update, on_delete
  FROM bd2_meta.listar_foreign_keys('public')
 ORDER BY local_table, constraint_name, key_position;

-- -----------------------------------------------------------------------------
-- P1-Q4: DDL gerado dinamicamente a partir do catálogo
-- -----------------------------------------------------------------------------
\o :evid_dir/p1_q4_ddl_gerado.sql
\pset format unaligned
\pset tuples_only on
SELECT bd2_meta.gerar_ddl_tabelas('public', 'public', true);
\pset tuples_only off
\pset format aligned

-- Prova: o DDL gerado é executável e reproduz a estrutura
DROP SCHEMA IF EXISTS bd2_q4_prova CASCADE;
SELECT pg_temp.tenta(bd2_meta.gerar_ddl_tabelas('public', 'bd2_q4_prova', true)) AS execucao \gset q4_
\o :evid_dir/p1_q4_prova.txt
\qecho '== Execução do DDL gerado em um schema novo (bd2_q4_prova):' :q4_execucao
SELECT n.nspname AS schema,
       count(*) FILTER (WHERE c.relkind = 'r') AS tabelas,
       (SELECT count(*) FROM pg_constraint k WHERE k.connamespace = n.oid AND k.contype = 'p') AS pks,
       (SELECT count(*) FROM pg_constraint k WHERE k.connamespace = n.oid AND k.contype = 'f') AS fks,
       (SELECT count(*) FROM pg_attribute a JOIN pg_class t ON t.oid = a.attrelid
         WHERE t.relnamespace = n.oid AND t.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped) AS colunas,
       (SELECT count(*) FROM pg_attribute a JOIN pg_class t ON t.oid = a.attrelid
         WHERE t.relnamespace = n.oid AND t.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped AND a.attnotnull) AS colunas_not_null
  FROM pg_namespace n
  JOIN pg_class c ON c.relnamespace = n.oid
 WHERE n.nspname IN ('public', 'bd2_q4_prova')
 GROUP BY n.oid, n.nspname
 ORDER BY 1;
\o
DROP SCHEMA IF EXISTS bd2_q4_prova CASCADE;

-- -----------------------------------------------------------------------------
-- P1-Q5: configuração do DTE
-- -----------------------------------------------------------------------------
\o :evid_dir/p1_q5_configuracao.txt
\qecho '== Máquinas de estado'
SELECT machine_name AS maquina, insert_policy AS politica_insercao, active AS ativa, description AS descricao
  FROM bd2_meta.state_machine ORDER BY 1;
\qecho '== Estados'
SELECT m.machine_name AS maquina, d.state_code AS estado, d.is_initial AS inicial, d.is_terminal AS terminal, d.active AS ativo
  FROM bd2_meta.state_definition d JOIN bd2_meta.state_machine m USING (machine_id)
 ORDER BY 1, d.is_initial DESC, d.is_terminal, 2;
\qecho '== Transições permitidas'
SELECT machine_name AS maquina, from_state AS de, to_state AS para, description AS descricao
  FROM bd2_meta.vw_dte_transicoes ORDER BY 1, 2, 3;
\qecho '== Vínculos (bindings) e triggers instalados'
SELECT schema_name || '.' || table_name || '.' || column_name AS coluna, machine_name AS maquina,
       binding_ativo, trigger_instalado, trigger_name
  FROM bd2_meta.vw_dte_bindings ORDER BY 1;

-- -----------------------------------------------------------------------------
-- Parte 2: triggers, papéis e privilégios
-- -----------------------------------------------------------------------------
\o :evid_dir/p2_triggers.txt
SELECT c.relnamespace::regnamespace || '.' || c.relname AS tabela,
       t.tgname AS trigger,
       p.proname AS funcao,
       pg_get_triggerdef(t.oid) AS definicao
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_proc  p ON p.oid = t.tgfoid
 WHERE NOT t.tgisinternal
   AND c.relnamespace IN ('public'::regnamespace, 'bd2_demo'::regnamespace)
 ORDER BY 1, 2;

\o :evid_dir/p2_permissoes.txt
\qecho '== Papéis'
SELECT rolname AS papel, rolcanlogin AS login, rolsuper AS superusuario, rolinherit AS herda
  FROM pg_roles WHERE rolname IN ('bd2_owner', 'bd2_app') ORDER BY 1;
\qecho '== Privilégios de tabela concedidos aos papéis do trabalho'
SELECT grantee AS papel, table_name AS tabela, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privilegios
  FROM information_schema.role_table_grants
 WHERE grantee IN ('bd2_owner', 'bd2_app') AND table_schema = 'public'
 GROUP BY 1, 2 ORDER BY 1, 2;
\qecho '== Privilégios de coluna'
SELECT grantee AS papel, table_name AS tabela, column_name AS coluna, privilege_type AS privilegio
  FROM information_schema.column_privileges
 WHERE grantee IN ('bd2_owner', 'bd2_app') AND table_schema = 'public'
   AND (grantee, table_name, privilege_type) NOT IN (
       SELECT grantee, table_name, privilege_type FROM information_schema.role_table_grants
        WHERE grantee IN ('bd2_owner', 'bd2_app'))
 ORDER BY 1, 2, 3;
\qecho '== Procedure R-SP-01'
SELECT p.oid::regprocedure AS procedure,
       pg_get_userbyid(p.proowner) AS dono,
       CASE WHEN p.prosecdef THEN 'SECURITY DEFINER' ELSE 'SECURITY INVOKER' END AS seguranca,
       array_to_string(p.proconfig, '; ') AS configuracao,
       p.proacl AS acl
  FROM pg_proc p WHERE p.proname = 'criar_fatura_com_itens';
\qecho '== bd2_app tentando manipular os dados por fora da procedure'
SET ROLE bd2_app;
SELECT 'INSERT INTO public.invoice'  AS tentativa, pg_temp.tenta('INSERT INTO public.invoice (customer_id, invoice_date, total) VALUES (1, now(), 0)') AS resultado
UNION ALL
SELECT 'DELETE FROM public.invoice_line', pg_temp.tenta('DELETE FROM public.invoice_line')
UNION ALL
SELECT 'SELECT FROM public.invoice', pg_temp.tenta('SELECT 1 FROM public.invoice');
RESET ROLE;

\qecho '== Auditoria R-TRG-02 após os testes SQL: faturas com total divergente (a auditoria após os testes de concorrência está em p2_concorrencia.txt)'
SELECT count(*) AS faturas, count(*) FILTER (WHERE total <> soma_itens) AS divergentes
  FROM bd2_demo.vw_auditoria_invoice_total;
\o

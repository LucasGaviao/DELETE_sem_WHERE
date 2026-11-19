-- =============================================================================
-- Resumo de um arquivo de teste (incluído ao final com \ir lib/resumo.sql)
-- Requer a variável psql :bloco (ex.: \set bloco 'Q5 (DTE)').
-- Imprime a tabela operação / esperado / obtido e falha se algum caso divergir.
-- Se :evid_dir e :evid_nome estiverem definidos (run_all.sh), grava a mesma
-- tabela em :evid_dir/:evid_nome.txt (evidência para o relatório).
-- =============================================================================

SELECT caso, operacao, esperado, obtido,
       CASE WHEN ok THEN 'OK' ELSE 'FALHOU' END AS resultado
  FROM resultado_teste
 ORDER BY ordem;

\if :{?evid_dir}
\if :{?evid_nome}
\o :evid_dir/:evid_nome.txt
SELECT caso, operacao, esperado, obtido,
       CASE WHEN ok THEN 'OK' ELSE 'FALHOU' END AS resultado
  FROM resultado_teste
 ORDER BY ordem;
\o
\endif
\endif

SELECT set_config('bd2.bloco_teste', :'bloco', false) \gset

DO $$
DECLARE
    v_bloco  text := current_setting('bd2.bloco_teste');
    v_total  int;
    v_falhas int;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE NOT ok) INTO v_total, v_falhas FROM resultado_teste;
    ASSERT v_total > 0, format('%s: nenhum caso executado.', v_bloco);
    ASSERT v_falhas = 0, format('%s: %s de %s casos falharam — ver tabela acima.', v_bloco, v_falhas, v_total);
    RAISE NOTICE 'OK: Testes % passaram — % casos.', v_bloco, v_total;
END $$;

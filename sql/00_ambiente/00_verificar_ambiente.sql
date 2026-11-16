-- =============================================================================
-- Arquivo: sql/00_ambiente/00_verificar_ambiente.sql
-- Finalidade:
--   1. Criar os schemas auxiliares do projeto (bd2_meta e bd2_demo).
--   2. Verificar a versão do PostgreSQL e a presença das 11 tabelas do Chinook.
--   3. Auditar a consistência inicial de public.invoice.total vs public.invoice_line.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS bd2_meta;
CREATE SCHEMA IF NOT EXISTS bd2_demo;

DO $$
DECLARE
    v_version text;
    v_table_count int;
    v_divergencias int;
BEGIN
    SELECT version() INTO v_version;
    RAISE NOTICE 'Ambiente PostgreSQL: %', v_version;

    -- 1. Verificar se as 11 tabelas do Chinook existem em public
    SELECT count(*)
      INTO v_table_count
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind = 'r'
       AND c.relname IN (
           'album', 'artist', 'customer', 'employee', 'genre',
           'invoice', 'invoice_line', 'media_type', 'playlist',
           'playlist_track', 'track'
       );

    ASSERT v_table_count = 11,
        format('Esperadas 11 tabelas do Chinook em public, encontradas: %s', v_table_count);

    -- 2. Auditar se invoice.total bate com SUM(unit_price * quantity) no seed inicial
    SELECT count(*)
      INTO v_divergencias
      FROM public.invoice i
      LEFT JOIN (
          SELECT invoice_id, COALESCE(SUM(unit_price * quantity), 0)::numeric(10,2) AS soma_calculada
            FROM public.invoice_line
           GROUP BY invoice_id
      ) il ON il.invoice_id = i.invoice_id
     WHERE i.total IS DISTINCT FROM COALESCE(il.soma_calculada, 0.00);

    ASSERT v_divergencias = 0,
        format('Encontradas %s faturas com total divergente no seed inicial!', v_divergencias);

    RAISE NOTICE 'Verificação concluída com sucesso: 11 tabelas presentes e 0 divergências em invoice.total.';
END $$;

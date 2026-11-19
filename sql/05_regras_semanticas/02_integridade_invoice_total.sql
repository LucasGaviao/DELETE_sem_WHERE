-- =============================================================================
-- Parte 2 — Questão 4: Trigger Semântico R-TRG-02 (Integridade de Invoice.Total)
-- Arquivo: sql/05_regras_semanticas/02_integridade_invoice_total.sql
-- Deve ser instalado antes de 03_procedure_criar_fatura.sql.
--
-- Regra: para toda fatura,
--     invoice.total = COALESCE(SUM(invoice_line.unit_price * quantity), 0)
--
-- Por que é semântica: CHECK e colunas GENERATED não podem consultar outra
-- tabela nem agregar linhas filhas.
--
-- Mecanismo (o total passa a ser mantido SOMENTE pelo banco):
--   A) BEFORE INSERT OR UPDATE OF total, invoice_id ON invoice
--        sobrescreve NEW.total com o valor calculado -> qualquer tentativa de
--        gravar um total "na mão" é corrigida (sem UPDATE recursivo).
--   B) AFTER INSERT OR DELETE OR UPDATE OF invoice_id, unit_price, quantity
--        ON invoice_line (FOR EACH ROW)
--        recalcula a fatura nova e a antiga (item movido entre faturas), em
--        ordem crescente de invoice_id (ordem determinística de locks).
--   C) AFTER TRUNCATE ON invoice_line (FOR EACH STATEMENT)
--        TRUNCATE não dispara triggers de linha; sem itens, todo total é 0.
--
-- Eventos cobertos: INSERT/DELETE de item; UPDATE de preço, quantidade ou
-- fatura do item; INSERT de cabeçalho; UPDATE direto de total; TRUNCATE dos
-- itens; INSERT ... ON CONFLICT DO UPDATE (dispara os triggers de UPDATE).
--
-- Limites (declarados no relatório): superusuário/dono pode desabilitar
-- triggers (ALTER TABLE ... DISABLE TRIGGER, session_replication_role).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Pré-condição: o seed precisa estar consistente antes de ativar a regra.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_div int;
BEGIN
    SELECT count(*) INTO v_div
      FROM public.invoice i
     WHERE i.total IS DISTINCT FROM
           COALESCE((SELECT sum(l.unit_price * l.quantity)
                       FROM public.invoice_line l
                      WHERE l.invoice_id = i.invoice_id), 0);
    ASSERT v_div = 0, format('R-TRG-02: %s fatura(s) com total divergente; corrija antes de ativar a regra.', v_div);
END $$;

-- -----------------------------------------------------------------------------
-- A) invoice: o total gravado é sempre o calculado
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_invoice_total_before()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    NEW.total := COALESCE((SELECT sum(l.unit_price * l.quantity)
                             FROM public.invoice_line l
                            WHERE l.invoice_id = NEW.invoice_id), 0);
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_invoice_total_before
    BEFORE INSERT OR UPDATE OF total, invoice_id ON public.invoice
    FOR EACH ROW EXECUTE FUNCTION public.fn_invoice_total_before();

-- -----------------------------------------------------------------------------
-- B) invoice_line: recalcula a(s) fatura(s) afetada(s)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_invoice_line_recalc()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_invoice_id integer;
BEGIN
    FOR v_invoice_id IN
        SELECT DISTINCT x
          FROM unnest(ARRAY[
                   CASE WHEN TG_OP <> 'DELETE' THEN NEW.invoice_id END,
                   CASE WHEN TG_OP <> 'INSERT' THEN OLD.invoice_id END]) AS x
         WHERE x IS NOT NULL
         ORDER BY x
    LOOP
        -- O valor atribuído é irrelevante: o trigger A recalcula NEW.total.
        UPDATE public.invoice i
           SET total = i.total
         WHERE i.invoice_id = v_invoice_id;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER trg_invoice_line_recalc
    AFTER INSERT OR DELETE OR UPDATE OF invoice_id, unit_price, quantity ON public.invoice_line
    FOR EACH ROW EXECUTE FUNCTION public.fn_invoice_line_recalc();

-- -----------------------------------------------------------------------------
-- C) TRUNCATE invoice_line: nenhuma fatura tem itens -> todos os totais = 0
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_invoice_line_truncate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    UPDATE public.invoice i
       SET total = i.total          -- trigger A grava 0 (não há mais itens)
     WHERE i.total <> 0;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER trg_invoice_line_truncate
    AFTER TRUNCATE ON public.invoice_line
    FOR EACH STATEMENT EXECUTE FUNCTION public.fn_invoice_line_truncate();

-- -----------------------------------------------------------------------------
-- Visão de auditoria (usada nos testes e no relatório)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bd2_demo.vw_auditoria_invoice_total AS
SELECT i.invoice_id,
       i.total,
       COALESCE(sum(l.unit_price * l.quantity), 0) AS soma_itens,
       count(l.invoice_line_id)                    AS qtd_itens
  FROM public.invoice i
  LEFT JOIN public.invoice_line l ON l.invoice_id = i.invoice_id
 GROUP BY i.invoice_id, i.total;

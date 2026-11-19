-- =============================================================================
-- Parte 2 — Questão 3 (2/2): Stored Procedure R-SP-01 (criar_fatura_com_itens)
-- Arquivo: sql/05_regras_semanticas/03_procedure_criar_fatura.sql
-- Depende de: 00_roles_e_permissoes.sql e 02_integridade_invoice_total.sql
--
-- Regra R-SP-01: toda fatura criada pela aplicação deve nascer com pelo menos
-- um item válido (faixa existente, quantidade inteira > 0), cobrado pelo
-- preço oficial da faixa (track.unit_price) no momento da venda.
--
-- Por que é semântica: a FK fica do lado N (invoice_line -> invoice); ela
-- impede item sem fatura, mas não impede fatura sem itens (cardinalidade
-- mínima 1 no lado N não é expressável por PK/FK/NOT NULL/CHECK).
--
-- Uso:
--   CALL public.criar_fatura_com_itens(
--        <customer_id>,
--        '[{"track_id": 1, "quantity": 2}, {"track_id": 5, "quantity": 1}]');
--   -> devolve o invoice_id criado no parâmetro INOUT p_invoice_id.
--
-- Segurança:
--   SECURITY DEFINER + dono bd2_owner: executa com os privilégios mínimos
--   do bd2_owner, não com os de quem chama. search_path fixo (pg_temp por
--   último, como recomenda a documentação) e todos os objetos qualificados.
--   EXECUTE revogado de PUBLIC e concedido somente a bd2_app, que não tem
--   nenhum privilégio direto em invoice / invoice_line.
--
-- Atomicidade: sem COMMIT interno. Qualquer erro desfaz cabeçalho e itens.
-- O total é calculado pelos triggers de R-TRG-02.
-- =============================================================================

CREATE OR REPLACE PROCEDURE public.criar_fatura_com_itens(
    p_customer_id  integer,
    p_itens        jsonb,
    INOUT p_invoice_id integer DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_item       jsonb;
    v_pos        integer := 0;
    v_track_id   integer;
    v_quantity   integer;
    v_qtd_itens  integer;
BEGIN
    p_invoice_id := NULL;

    -- 1. Lista de itens: array JSON não vazio
    IF p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' OR jsonb_array_length(p_itens) = 0 THEN
        RAISE EXCEPTION 'R-SP-01: a fatura deve ter pelo menos 1 item (informe um array JSON não vazio).'
              USING ERRCODE = 'check_violation';
    END IF;

    -- 2. Validar TODOS os itens antes de gravar qualquer coisa
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_itens) LOOP
        v_pos := v_pos + 1;

        IF jsonb_typeof(v_item) <> 'object'
           OR jsonb_typeof(v_item -> 'track_id') IS DISTINCT FROM 'number'
           OR jsonb_typeof(v_item -> 'quantity') IS DISTINCT FROM 'number'
           OR (v_item ->> 'track_id') !~ '^[0-9]+$'
           OR (v_item ->> 'quantity') !~ '^-?[0-9]+$' THEN
            RAISE EXCEPTION 'R-SP-01: item % inválido: %. Formato esperado: {"track_id": <inteiro>, "quantity": <inteiro>}.',
                            v_pos, v_item
                  USING ERRCODE = 'invalid_parameter_value';
        END IF;

        v_track_id := (v_item ->> 'track_id')::integer;
        v_quantity := (v_item ->> 'quantity')::integer;

        IF v_quantity <= 0 THEN
            RAISE EXCEPTION 'R-SP-01: item %: a quantidade deve ser maior que zero (recebido: %).', v_pos, v_quantity
                  USING ERRCODE = 'check_violation';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM public.track t WHERE t.track_id = v_track_id) THEN
            RAISE EXCEPTION 'R-SP-01: item %: a faixa % não existe.', v_pos, v_track_id
                  USING ERRCODE = 'foreign_key_violation';
        END IF;
    END LOOP;

    -- 3. Cabeçalho (dados de cobrança copiados do cadastro do cliente)
    INSERT INTO public.invoice (customer_id, invoice_date,
                                billing_address, billing_city, billing_state,
                                billing_country, billing_postal_code, total)
    SELECT c.customer_id, now(),
           c.address, c.city, c.state, c.country, c.postal_code, 0
      FROM public.customer c
     WHERE c.customer_id = p_customer_id
    RETURNING invoice_id INTO p_invoice_id;

    IF p_invoice_id IS NULL THEN
        RAISE EXCEPTION 'R-SP-01: o cliente % não existe.', p_customer_id
              USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- 4. Itens, com o preço oficial da faixa
    INSERT INTO public.invoice_line (invoice_id, track_id, unit_price, quantity)
    SELECT p_invoice_id, t.track_id, t.unit_price, (e.item ->> 'quantity')::integer
      FROM jsonb_array_elements(p_itens) WITH ORDINALITY AS e(item, ord)
      JOIN public.track t ON t.track_id = (e.item ->> 'track_id')::integer
     ORDER BY e.ord;

    -- 5. Pós-condição: todos os itens pedidos foram gravados (uma faixa
    --    removida por outra transação entre a validação e o INSERT faria o
    --    JOIN descartar o item em silêncio) e a fatura tem pelo menos 1 item.
    GET DIAGNOSTICS v_qtd_itens = ROW_COUNT;
    IF v_qtd_itens <> jsonb_array_length(p_itens) OR v_qtd_itens < 1 THEN
        RAISE EXCEPTION 'R-SP-01: esperados % item(ns), gravados %; operação desfeita.',
                        jsonb_array_length(p_itens), v_qtd_itens
              USING ERRCODE = 'serialization_failure';
    END IF;
END;
$$;

ALTER PROCEDURE public.criar_fatura_com_itens(integer, jsonb, integer) OWNER TO bd2_owner;
REVOKE ALL     ON PROCEDURE public.criar_fatura_com_itens(integer, jsonb, integer) FROM PUBLIC;
GRANT  EXECUTE ON PROCEDURE public.criar_fatura_com_itens(integer, jsonb, integer) TO bd2_app;

COMMENT ON PROCEDURE public.criar_fatura_com_itens(integer, jsonb, integer) IS
    'R-SP-01: cria fatura com >= 1 item válido (preço oficial da faixa). Único caminho de escrita para bd2_app.';

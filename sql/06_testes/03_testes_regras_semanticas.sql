-- =============================================================================
-- Testes — Parte 2 (Regras Semânticas)
-- Arquivo: sql/06_testes/03_testes_regras_semanticas.sql
--
--   H*  R-TRG-01  hierarquia de employee sem ciclos (trigger)
--   T*  R-TRG-02  invoice.total = Σ(unit_price * quantity) (triggers)
--   S*  R-SP-01   fatura nasce com >= 1 item (procedure + permissões)
--   P*  Permissões / configuração de segurança
--
-- Casos positivos e negativos; nenhum ID do seed é fixado (linhas criadas
-- aqui via RETURNING e removidas no fim). Concorrência: 04_concorrencia.sh.
-- =============================================================================

\ir lib/harness.sql
\set QUIET on

-- =============================================================================
-- H. R-TRG-01 — hierarquia sem ciclos
-- =============================================================================
DO $$
DECLARE
    v_e1 int; v_e2 int; v_e3 int; v_e4 int; v_a int; v_b int;
    c_ins constant text :=
        'INSERT INTO public.employee (last_name, first_name, title, reports_to) VALUES (%L, ''Teste'', ''BD2 teste'', %s) RETURNING employee_id';
BEGIN
    -- Cadeia de teste: e1 (raiz) <- e2 <- e3 ;  e4 (outra raiz)
    v_e1 := pg_temp.caso('H01', 'employee: INSERT raiz (reports_to NULL)', format(c_ins, 'H_e1', 'NULL'), 'ACEITO');
    v_e2 := pg_temp.caso('H02', 'employee: INSERT e2 subordinado a e1', format(c_ins, 'H_e2', v_e1), 'ACEITO');
    v_e3 := pg_temp.caso('H03', 'employee: INSERT e3 subordinado a e2', format(c_ins, 'H_e3', v_e2), 'ACEITO');
    v_e4 := pg_temp.caso('H04', 'employee: INSERT e4 (outra raiz)',      format(c_ins, 'H_e4', 'NULL'), 'ACEITO');

    PERFORM pg_temp.caso('H05', 'employee: auto-referência (e2 superior de si mesmo)',
            format('UPDATE public.employee SET reports_to = %s WHERE employee_id = %s', v_e2, v_e2), 'REJEITADO', '23514');

    PERFORM pg_temp.caso('H06', 'employee: ciclo de 2 (e1 passa a reportar a e2; e2 já reporta a e1)',
            format('UPDATE public.employee SET reports_to = %s WHERE employee_id = %s', v_e2, v_e1), 'REJEITADO', '23514');

    PERFORM pg_temp.caso('H07', 'employee: ciclo de 3 (e1 -> e3 -> e2 -> e1)',
            format('UPDATE public.employee SET reports_to = %s WHERE employee_id = %s', v_e3, v_e1), 'REJEITADO', '23514');

    PERFORM pg_temp.caso('H08', 'employee: ciclo em UPDATE de várias linhas no mesmo comando (e1 <-> e4)',
            format('UPDATE public.employee SET reports_to = CASE employee_id WHEN %1$s THEN %2$s ELSE %1$s END
                     WHERE employee_id IN (%1$s, %2$s)', v_e1, v_e4), 'REJEITADO', '23514');

    -- INSERT de 2 linhas que se referenciam mutuamente no mesmo comando
    v_a := nextval(pg_get_serial_sequence('public.employee', 'employee_id'));
    v_b := nextval(pg_get_serial_sequence('public.employee', 'employee_id'));
    PERFORM pg_temp.caso('H09', 'employee: ciclo em INSERT de 2 linhas no mesmo comando (a -> b, b -> a)',
            format('INSERT INTO public.employee (employee_id, last_name, first_name, reports_to)
                    VALUES (%1$s, ''H_a'', ''Teste'', %2$s), (%2$s, ''H_b'', ''Teste'', %1$s)', v_a, v_b),
            'REJEITADO', '23514');

    PERFORM pg_temp.caso('H10', 'employee: mudança válida (e3 passa a reportar direto a e1)',
            format('UPDATE public.employee SET reports_to = %s WHERE employee_id = %s', v_e1, v_e3), 'ACEITO');

    PERFORM pg_temp.caso('H11', 'employee: mudança válida (e1 passa a reportar a e4; sem ciclo)',
            format('UPDATE public.employee SET reports_to = %s WHERE employee_id = %s', v_e4, v_e1), 'ACEITO');

    PERFORM pg_temp.caso('H12', 'employee: agora e4 -> e3 fecharia e4 -> e3 -> e1 -> e4',
            format('UPDATE public.employee SET reports_to = %s WHERE employee_id = %s', v_e3, v_e4), 'REJEITADO', '23514');

    PERFORM pg_temp.caso('H13', 'employee: UPDATE de outra coluna (phone) não é afetado',
            format('UPDATE public.employee SET phone = ''+55 21 0000-0000'' WHERE employee_id = %s', v_e3), 'ACEITO');

    PERFORM pg_temp.caso('H14', 'employee: tornar e1 raiz novamente (reports_to NULL)',
            format('UPDATE public.employee SET reports_to = NULL WHERE employee_id = %s', v_e1), 'ACEITO');

    PERFORM pg_temp.caso('H15', 'employee: hierarquia do seed — General Manager passa a reportar a um subordinado indireto',
            $q$UPDATE public.employee SET reports_to = (SELECT max(employee_id) FROM public.employee WHERE last_name NOT LIKE 'H\_%' AND reports_to IS NOT NULL)
                WHERE reports_to IS NULL AND last_name NOT LIKE 'H\_%'$q$, 'REJEITADO', '23514');

    PERFORM pg_temp.verifica('H16', 'employee: hierarquia final acíclica (nenhum funcionário alcança a si mesmo)',
            NOT EXISTS (
                WITH RECURSIVE sobe AS (
                    SELECT employee_id AS origem, reports_to AS atual, 1 AS nivel
                      FROM public.employee WHERE reports_to IS NOT NULL
                    UNION ALL
                    SELECT s.origem, e.reports_to, s.nivel + 1
                      FROM sobe s JOIN public.employee e ON e.employee_id = s.atual
                     WHERE e.reports_to IS NOT NULL AND s.atual <> s.origem AND s.nivel < 1000)
                SELECT 1 FROM sobe WHERE atual = origem));

    -- limpeza
    UPDATE public.employee SET reports_to = NULL WHERE last_name LIKE 'H\_%';
    DELETE FROM public.employee WHERE last_name LIKE 'H\_%';
END $$;

-- =============================================================================
-- T. R-TRG-02 — invoice.total = Σ itens
-- =============================================================================
DO $$
DECLARE
    v_cli   int;
    v_inv1  int;
    v_inv2  int;
    v_t1    int;  v_p1 numeric;
    v_t2    int;  v_p2 numeric;
    v_l1    int;
    v_l2    int;
    v_div   int;
    v_trunc_ok boolean;
BEGIN
    SELECT min(customer_id) INTO v_cli FROM public.customer;
    -- duas faixas com preços diferentes (seleção controlada, sem ID fixo)
    SELECT track_id, unit_price INTO v_t1, v_p1 FROM public.track ORDER BY unit_price, track_id LIMIT 1;
    SELECT track_id, unit_price INTO v_t2, v_p2 FROM public.track ORDER BY unit_price DESC, track_id LIMIT 1;

    -- T01: fatura sem itens -> total 0 (mesmo informando outro valor)
    v_inv1 := pg_temp.caso('T01', 'invoice: INSERT informando total = 999.99 sem itens',
              format('INSERT INTO public.invoice (customer_id, invoice_date, total) VALUES (%s, now(), 999.99) RETURNING invoice_id', v_cli), 'ACEITO');
    PERFORM pg_temp.verifica('T01b', 'total da fatura sem itens = 0.00 (valor informado foi ignorado)',
            (SELECT total = 0 FROM public.invoice WHERE invoice_id = v_inv1));

    -- T02: 1 item
    v_l1 := pg_temp.caso('T02', 'invoice_line: INSERT 1 item (qtd 2)',
            format('INSERT INTO public.invoice_line (invoice_id, track_id, unit_price, quantity) VALUES (%s, %s, %s, 2) RETURNING invoice_line_id', v_inv1, v_t1, v_p1), 'ACEITO');
    PERFORM pg_temp.verifica('T02b', format('total = %s × 2', v_p1),
            (SELECT total = v_p1 * 2 FROM public.invoice WHERE invoice_id = v_inv1));

    -- T03: 2 itens
    v_l2 := pg_temp.caso('T03', 'invoice_line: INSERT 2º item (qtd 1)',
            format('INSERT INTO public.invoice_line (invoice_id, track_id, unit_price, quantity) VALUES (%s, %s, %s, 1) RETURNING invoice_line_id', v_inv1, v_t2, v_p2), 'ACEITO');
    PERFORM pg_temp.verifica('T03b', 'total = soma dos 2 itens',
            (SELECT total = v_p1 * 2 + v_p2 FROM public.invoice WHERE invoice_id = v_inv1));

    -- T04: UPDATE quantity
    PERFORM pg_temp.caso('T04', 'invoice_line: UPDATE quantity 2 -> 5',
            format('UPDATE public.invoice_line SET quantity = 5 WHERE invoice_line_id = %s', v_l1), 'ACEITO');
    PERFORM pg_temp.verifica('T04b', 'total recalculado após mudar quantidade',
            (SELECT total = v_p1 * 5 + v_p2 FROM public.invoice WHERE invoice_id = v_inv1));

    -- T05: UPDATE unit_price
    PERFORM pg_temp.caso('T05', 'invoice_line: UPDATE unit_price -> 10.00',
            format('UPDATE public.invoice_line SET unit_price = 10.00 WHERE invoice_line_id = %s', v_l2), 'ACEITO');
    PERFORM pg_temp.verifica('T05b', 'total recalculado após mudar preço',
            (SELECT total = v_p1 * 5 + 10.00 FROM public.invoice WHERE invoice_id = v_inv1));

    -- T09: UPDATE direto do total é corrigido
    PERFORM pg_temp.caso('T09', 'invoice: UPDATE direto total = 0.01 (adulteração)',
            format('UPDATE public.invoice SET total = 0.01 WHERE invoice_id = %s', v_inv1), 'ACEITO');
    PERFORM pg_temp.verifica('T09b', 'total voltou ao valor calculado (trigger A)',
            (SELECT total = v_p1 * 5 + 10.00 FROM public.invoice WHERE invoice_id = v_inv1));

    -- T08: mover item entre faturas -> ambas recalculadas
    v_inv2 := pg_temp.caso('T08a', 'invoice: INSERT segunda fatura (vazia)',
              format('INSERT INTO public.invoice (customer_id, invoice_date, total) VALUES (%s, now(), 0) RETURNING invoice_id', v_cli), 'ACEITO');
    PERFORM pg_temp.caso('T08', 'invoice_line: mover item (preço 10.00) da fatura 1 para a fatura 2',
            format('UPDATE public.invoice_line SET invoice_id = %s WHERE invoice_line_id = %s', v_inv2, v_l2), 'ACEITO');
    PERFORM pg_temp.verifica('T08b', 'fatura de origem diminuiu E fatura de destino aumentou',
            (SELECT total = v_p1 * 5 FROM public.invoice WHERE invoice_id = v_inv1)
        AND (SELECT total = 10.00     FROM public.invoice WHERE invoice_id = v_inv2));

    -- T06: DELETE de item
    PERFORM pg_temp.caso('T06', 'invoice_line: DELETE do item da fatura 1',
            format('DELETE FROM public.invoice_line WHERE invoice_line_id = %s', v_l1), 'ACEITO');
    -- T07: fatura ficou sem itens
    PERFORM pg_temp.verifica('T07', 'DELETE do último item -> total = 0.00',
            (SELECT total = 0 FROM public.invoice WHERE invoice_id = v_inv1));

    -- T10: inserção em lote
    PERFORM pg_temp.caso('T10', 'invoice_line: INSERT ... SELECT de 50 itens em um comando',
            format('INSERT INTO public.invoice_line (invoice_id, track_id, unit_price, quantity)
                    SELECT %s, track_id, unit_price, 1 + (track_id %% 3)
                      FROM public.track ORDER BY track_id LIMIT 50', v_inv1), 'ACEITO');
    PERFORM pg_temp.verifica('T10b', 'total = soma dos 50 itens',
            (SELECT total = soma_itens AND qtd_itens = 50 FROM bd2_demo.vw_auditoria_invoice_total WHERE invoice_id = v_inv1));

    -- T12: INSERT ... ON CONFLICT DO UPDATE
    PERFORM pg_temp.caso('T12', 'invoice_line: INSERT ... ON CONFLICT (invoice_line_id) DO UPDATE SET quantity = 7',
            format('INSERT INTO public.invoice_line (invoice_line_id, invoice_id, track_id, unit_price, quantity)
                    SELECT invoice_line_id, invoice_id, track_id, unit_price, 1
                      FROM public.invoice_line WHERE invoice_id = %s ORDER BY invoice_line_id LIMIT 1
                    ON CONFLICT (invoice_line_id) DO UPDATE SET quantity = 7', v_inv1), 'ACEITO');
    PERFORM pg_temp.verifica('T12b', 'total correto após upsert',
            (SELECT total = soma_itens FROM bd2_demo.vw_auditoria_invoice_total WHERE invoice_id = v_inv1));

    -- T13: TRUNCATE invoice_line (em subtransação desfeita, para preservar o seed)
    --      (variáveis PL/pgSQL não são transacionais: o resultado sobrevive ao rollback)
    BEGIN
        TRUNCATE public.invoice_line;
        v_trunc_ok := (SELECT count(*) > 400 FROM public.invoice)
                      AND NOT EXISTS (SELECT 1 FROM public.invoice WHERE total <> 0);
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'desfazer TRUNCATE';
    EXCEPTION WHEN raise_exception THEN
        NULL;
    END;
    PERFORM pg_temp.verifica('T13', 'TRUNCATE invoice_line -> todas as faturas com total = 0 (trigger de statement)',
            v_trunc_ok);
    PERFORM pg_temp.verifica('T13b', 'após desfazer o TRUNCATE, os itens do seed continuam lá',
            (SELECT count(*) FROM public.invoice_line) > 2000);

    -- T14: auditoria global
    SELECT count(*) INTO v_div FROM bd2_demo.vw_auditoria_invoice_total WHERE total <> soma_itens;
    PERFORM pg_temp.verifica('T14', 'auditoria global: 0 faturas com total divergente', v_div = 0);

    -- limpeza
    DELETE FROM public.invoice_line WHERE invoice_id IN (v_inv1, v_inv2);
    DELETE FROM public.invoice      WHERE invoice_id IN (v_inv1, v_inv2);
END $$;

-- =============================================================================
-- S. R-SP-01 — fatura nasce com >= 1 item (executado COMO bd2_app)
-- =============================================================================
DO $$
DECLARE
    v_cli    int;
    v_t1     int;
    v_t2     int;
    v_inv    int;
    v_antes  bigint;
    c_call   constant text := 'CALL public.criar_fatura_com_itens(%s, %L)';
BEGIN
    SELECT min(customer_id) INTO v_cli FROM public.customer;
    SELECT min(track_id), max(track_id) INTO v_t1, v_t2 FROM public.track;
    SELECT count(*) INTO v_antes FROM public.invoice;

    -- Positivo
    v_inv := pg_temp.caso('S01', 'bd2_app: CALL com 2 itens válidos',
             format(c_call, v_cli, format('[{"track_id": %s, "quantity": 2}, {"track_id": %s, "quantity": 1}]', v_t1, v_t2)),
             'ACEITO', NULL, 'bd2_app');

    PERFORM pg_temp.verifica('S02', 'fatura criada com 2 itens e total = Σ(preço oficial da faixa × qtd)',
            (SELECT count(*) = 2 FROM public.invoice_line WHERE invoice_id = v_inv)
        AND (SELECT i.total = (SELECT 2 * unit_price FROM public.track WHERE track_id = v_t1)
                            + (SELECT 1 * unit_price FROM public.track WHERE track_id = v_t2)
               FROM public.invoice i WHERE i.invoice_id = v_inv));

    PERFORM pg_temp.verifica('S03', 'cobrança copiada do cliente e status inicial do DTE (PENDENTE)',
            (SELECT i.billing_city IS NOT DISTINCT FROM c.city AND i.billing_country IS NOT DISTINCT FROM c.country
                    AND i.status = 'PENDENTE'
               FROM public.invoice i JOIN public.customer c USING (customer_id)
              WHERE i.invoice_id = v_inv));

    -- Negativos da regra (todos atômicos: nada pode sobrar gravado)
    PERFORM pg_temp.caso('S04', 'bd2_app: CALL com lista vazia []',
            format(c_call, v_cli, '[]'), 'REJEITADO', '23514', 'bd2_app');
    PERFORM pg_temp.caso('S05', 'bd2_app: CALL com itens NULL',
            format('CALL public.criar_fatura_com_itens(%s, NULL)', v_cli), 'REJEITADO', '23514', 'bd2_app');
    PERFORM pg_temp.caso('S06', 'bd2_app: CALL com objeto em vez de array',
            format(c_call, v_cli, format('{"track_id": %s, "quantity": 1}', v_t1)), 'REJEITADO', '23514', 'bd2_app');
    PERFORM pg_temp.caso('S07', 'bd2_app: CALL com cliente inexistente',
            format(c_call, -1, format('[{"track_id": %s, "quantity": 1}]', v_t1)), 'REJEITADO', '23503', 'bd2_app');
    PERFORM pg_temp.caso('S08', 'bd2_app: CALL com 1 item válido + 1 faixa inexistente',
            format(c_call, v_cli, format('[{"track_id": %s, "quantity": 1}, {"track_id": %s, "quantity": 1}]', v_t1, v_t2 + 1000)),
            'REJEITADO', '23503', 'bd2_app');
    PERFORM pg_temp.caso('S09', 'bd2_app: CALL com quantidade 0',
            format(c_call, v_cli, format('[{"track_id": %s, "quantity": 0}]', v_t1)), 'REJEITADO', '23514', 'bd2_app');
    PERFORM pg_temp.caso('S10', 'bd2_app: CALL com quantidade negativa',
            format(c_call, v_cli, format('[{"track_id": %s, "quantity": -3}]', v_t1)), 'REJEITADO', '23514', 'bd2_app');
    PERFORM pg_temp.caso('S11', 'bd2_app: CALL com quantidade não inteira (1.5)',
            format(c_call, v_cli, format('[{"track_id": %s, "quantity": 1.5}]', v_t1)), 'REJEITADO', '22023', 'bd2_app');
    PERFORM pg_temp.caso('S12', 'bd2_app: CALL com item sem track_id',
            format(c_call, v_cli, '[{"quantity": 1}]'), 'REJEITADO', '22023', 'bd2_app');
    PERFORM pg_temp.caso('S13', 'bd2_app: CALL com quantidade em texto ("2")',
            format(c_call, v_cli, format('[{"track_id": %s, "quantity": "2"}]', v_t1)), 'REJEITADO', '22023', 'bd2_app');

    PERFORM pg_temp.verifica('S14', 'casos rejeitados não deixaram fatura gravada (só a do S01 foi criada)',
            (SELECT count(*) FROM public.invoice) = v_antes + 1);

    -- O usuário não tem outro caminho para manipular os dados
    PERFORM pg_temp.caso('S15', 'bd2_app: INSERT direto em invoice',
            format('INSERT INTO public.invoice (customer_id, invoice_date, total) VALUES (%s, now(), 0)', v_cli),
            'REJEITADO', '42501', 'bd2_app');
    PERFORM pg_temp.caso('S16', 'bd2_app: INSERT direto em invoice_line',
            format('INSERT INTO public.invoice_line (invoice_id, track_id, unit_price, quantity) VALUES (%s, %s, 0.99, 1)', v_inv, v_t1),
            'REJEITADO', '42501', 'bd2_app');
    PERFORM pg_temp.caso('S17', 'bd2_app: UPDATE direto em invoice_line',
            format('UPDATE public.invoice_line SET quantity = 99 WHERE invoice_id = %s', v_inv), 'REJEITADO', '42501', 'bd2_app');
    PERFORM pg_temp.caso('S18', 'bd2_app: DELETE direto em invoice_line (deixaria fatura sem itens)',
            format('DELETE FROM public.invoice_line WHERE invoice_id = %s', v_inv), 'REJEITADO', '42501', 'bd2_app');
    PERFORM pg_temp.caso('S19', 'bd2_app: DELETE direto em invoice',
            format('DELETE FROM public.invoice WHERE invoice_id = %s', v_inv), 'REJEITADO', '42501', 'bd2_app');
    PERFORM pg_temp.caso('S20', 'bd2_app: TRUNCATE invoice_line',
            'TRUNCATE public.invoice_line', 'REJEITADO', '42501', 'bd2_app');
    PERFORM pg_temp.caso('S21', 'bd2_app: SELECT direto em invoice (sem acesso aos dados fora da procedure)',
            'SELECT count(*) FROM public.invoice', 'REJEITADO', '42501', 'bd2_app');
    PERFORM pg_temp.caso('S22', 'bd2_app: CALL de outra procedure (bd2_meta.remover_binding)',
            'CALL bd2_meta.remover_binding(''public'', ''invoice'', ''status'')', 'REJEITADO', '42501', 'bd2_app');

    -- limpeza (como superusuário)
    DELETE FROM public.invoice_line WHERE invoice_id = v_inv;
    DELETE FROM public.invoice      WHERE invoice_id = v_inv;
END $$;

-- =============================================================================
-- P. Configuração de segurança (catálogo)
-- =============================================================================
DO $$
DECLARE
    v_proc regprocedure := 'public.criar_fatura_com_itens(integer, jsonb, integer)'::regprocedure;
BEGIN
    PERFORM pg_temp.verifica('P01', 'bd2_owner: NOLOGIN e não superusuário; bd2_app: LOGIN e não superusuário',
            (SELECT NOT rolcanlogin AND NOT rolsuper FROM pg_roles WHERE rolname = 'bd2_owner')
        AND (SELECT rolcanlogin AND NOT rolsuper FROM pg_roles WHERE rolname = 'bd2_app'));

    PERFORM pg_temp.verifica('P02', 'procedure: SECURITY DEFINER, dono bd2_owner, search_path fixo',
            (SELECT p.prosecdef
                    AND pg_get_userbyid(p.proowner) = 'bd2_owner'
                    AND p.proconfig @> ARRAY['search_path=pg_catalog, public, pg_temp']
               FROM pg_proc p WHERE p.oid = v_proc));

    PERFORM pg_temp.verifica('P03', 'EXECUTE: concedido a bd2_app e NÃO a PUBLIC',
            has_function_privilege('bd2_app', v_proc, 'EXECUTE')
        AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                         WHERE p.oid = v_proc AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'));

    PERFORM pg_temp.verifica('P04', 'bd2_app: nenhum privilégio de tabela em invoice / invoice_line',
            NOT has_table_privilege('bd2_app', 'public.invoice',      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
        AND NOT has_table_privilege('bd2_app', 'public.invoice_line', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'));

    PERFORM pg_temp.verifica('P05', 'bd2_app não é membro de nenhum papel (não herda privilégios)',
            NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = 'bd2_app'));

    PERFORM pg_temp.verifica('P06', 'bd2_owner: sem DELETE/TRUNCATE em invoice / invoice_line (privilégio mínimo)',
            NOT has_table_privilege('bd2_owner', 'public.invoice',      'DELETE,TRUNCATE')
        AND NOT has_table_privilege('bd2_owner', 'public.invoice_line', 'DELETE,TRUNCATE,UPDATE'));

    PERFORM pg_temp.verifica('P07', 'bd2_app: nenhum privilégio em NENHUMA tabela do Chinook e sem EXECUTE na procedure de remoção de índices',
            NOT EXISTS (SELECT 1 FROM pg_class c
                         WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
                           AND has_table_privilege('bd2_app', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
        AND NOT has_function_privilege('bd2_app', 'bd2_meta.remover_indices_tabela(text,text,boolean,boolean,jsonb)', 'EXECUTE'));
END $$;

\set QUIET off

\set bloco 'Parte 2 (R-TRG-01, R-TRG-02, R-SP-01)'
\set evid_nome p2_testes_regras
\ir lib/resumo.sql

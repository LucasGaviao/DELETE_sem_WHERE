-- =============================================================================
-- Cenário de Teste — Parte 1, Questão 5 (Motor Genérico de DTE)
-- Arquivo: sql/06_testes/02_testes_maquina_estados.sql
--
-- Cada caso executa uma operação e compara o resultado obtido (ACEITO /
-- REJEITADO + SQLSTATE) com o esperado, usando o harness de lib/harness.sql.
-- A tabela de resultados é impressa ao final (evidência para o relatório) e,
-- se qualquer caso divergir, lib/resumo.sql falha (psql ON_ERROR_STOP=1).
--
-- Não depende de IDs do seed: todas as linhas usadas são criadas aqui
-- (RETURNING) e removidas ao final.
-- =============================================================================

\ir lib/harness.sql
\set QUIET on

DO $$
DECLARE
    v_cliente  integer;
    v_inv1     integer;
    v_inv2     integer;
    v_ped1     integer;
    v_ped2     integer;
    v_ped3     integer;
    v_ped_inv  integer;
    v_tmp      integer;
    c_ins_inv  constant text :=
        'INSERT INTO public.invoice (customer_id, invoice_date, total%s) VALUES (%s, now(), 0%s) RETURNING invoice_id';
BEGIN
    -- Cliente qualquer existente (seleção controlada, sem ID fixo)
    SELECT min(customer_id) INTO v_cliente FROM public.customer;

    -- =========================================================================
    -- A. public.invoice.status  — máquina INVOICE_STATE (INITIAL_ONLY)
    -- =========================================================================
    v_inv1 := pg_temp.caso('A01', 'invoice: INSERT sem informar status (DEFAULT PENDENTE = inicial)',
              format(c_ins_inv, '', v_cliente, ''), 'ACEITO');

    PERFORM pg_temp.caso('A02', 'invoice: INSERT com status PAGO (não inicial, política INITIAL_ONLY)',
            format(c_ins_inv, ', status', v_cliente, ', ''PAGO'''), 'REJEITADO', '23514');

    PERFORM pg_temp.caso('A03', 'invoice: INSERT com status inexistente ESTORNADO',
            format(c_ins_inv, ', status', v_cliente, ', ''ESTORNADO'''), 'REJEITADO', '23514');

    PERFORM pg_temp.caso('A04', 'invoice: PENDENTE -> PAGO',
            format('UPDATE public.invoice SET status = ''PAGO'' WHERE invoice_id = %s', v_inv1), 'ACEITO');

    PERFORM pg_temp.caso('A05', 'invoice: PAGO -> PENDENTE (PAGO é terminal)',
            format('UPDATE public.invoice SET status = ''PENDENTE'' WHERE invoice_id = %s', v_inv1), 'REJEITADO', '23514');

    PERFORM pg_temp.caso('A06', 'invoice: UPDATE de outra coluna (billing_city) numa fatura PAGO',
            format('UPDATE public.invoice SET billing_city = ''Niterói'' WHERE invoice_id = %s', v_inv1), 'ACEITO');

    PERFORM pg_temp.caso('A07', 'invoice: UPDATE status PAGO -> PAGO (sem mudança de estado)',
            format('UPDATE public.invoice SET status = ''PAGO'' WHERE invoice_id = %s', v_inv1), 'ACEITO');

    v_inv2 := pg_temp.caso('A08', 'invoice: INSERT de segunda fatura (PENDENTE)',
              format(c_ins_inv, '', v_cliente, ''), 'ACEITO');

    PERFORM pg_temp.caso('A09', 'invoice: PENDENTE -> CANCELADO',
            format('UPDATE public.invoice SET status = ''CANCELADO'' WHERE invoice_id = %s', v_inv2), 'ACEITO');

    PERFORM pg_temp.caso('A10', 'invoice: CANCELADO -> PAGO (CANCELADO é terminal)',
            format('UPDATE public.invoice SET status = ''PAGO'' WHERE invoice_id = %s', v_inv2), 'REJEITADO', '23514');

    PERFORM pg_temp.caso('A11', 'invoice: status em minúsculas (''pago'') — códigos são exatos',
            format('UPDATE public.invoice SET status = ''pago'' WHERE invoice_id = %s', v_inv2), 'REJEITADO', '23514');

    -- =========================================================================
    -- B. bd2_demo.pedido_demo.situacao — máquina PEDIDO_STATE (ANY_VALID_STATE)
    --    Outra tabela, outro nome de coluna, MESMA função de trigger.
    -- =========================================================================
    v_ped1 := pg_temp.caso('B01', 'pedido: INSERT sem informar situacao (DEFAULT NOVO)',
              'INSERT INTO bd2_demo.pedido_demo (descricao) VALUES (''teste B01'') RETURNING pedido_id', 'ACEITO');

    v_ped2 := pg_temp.caso('B02', 'pedido: INSERT direto em CONCLUIDO (política ANY_VALID_STATE permite)',
              'INSERT INTO bd2_demo.pedido_demo (descricao, situacao) VALUES (''teste B02'', ''CONCLUIDO'') RETURNING pedido_id', 'ACEITO');

    PERFORM pg_temp.caso('B03', 'pedido: INSERT com situacao NULL (coluna anulável; rejeitado pelo motor)',
            'INSERT INTO bd2_demo.pedido_demo (descricao, situacao) VALUES (''teste B03'', NULL)', 'REJEITADO', '23514');

    PERFORM pg_temp.caso('B04', 'pedido: INSERT com PAGO (estado de OUTRA máquina)',
            'INSERT INTO bd2_demo.pedido_demo (descricao, situacao) VALUES (''teste B04'', ''PAGO'')', 'REJEITADO', '23514');

    PERFORM pg_temp.caso('B05', 'pedido: NOVO -> CONCLUIDO (pula EM_ANDAMENTO; sem aresta)',
            format('UPDATE bd2_demo.pedido_demo SET situacao = ''CONCLUIDO'' WHERE pedido_id = %s', v_ped1), 'REJEITADO', '23514');

    PERFORM pg_temp.caso('B06', 'pedido: NOVO -> EM_ANDAMENTO',
            format('UPDATE bd2_demo.pedido_demo SET situacao = ''EM_ANDAMENTO'' WHERE pedido_id = %s', v_ped1), 'ACEITO');

    PERFORM pg_temp.caso('B07', 'pedido: EM_ANDAMENTO -> NULL',
            format('UPDATE bd2_demo.pedido_demo SET situacao = NULL WHERE pedido_id = %s', v_ped1), 'REJEITADO', '23514');

    PERFORM pg_temp.caso('B08', 'pedido: EM_ANDAMENTO -> CONCLUIDO',
            format('UPDATE bd2_demo.pedido_demo SET situacao = ''CONCLUIDO'' WHERE pedido_id = %s', v_ped1), 'ACEITO');

    -- UPDATE de várias linhas: se uma transição é inválida, o comando inteiro é desfeito.
    v_ped3 := pg_temp.caso('B09', 'pedido: INSERT de terceiro pedido (NOVO)',
              'INSERT INTO bd2_demo.pedido_demo (descricao) VALUES (''teste B09'') RETURNING pedido_id', 'ACEITO');

    PERFORM pg_temp.caso('B10', 'pedido: UPDATE em lote -> EM_ANDAMENTO (uma linha NOVO válida + uma CONCLUIDO inválida)',
            format('UPDATE bd2_demo.pedido_demo SET situacao = ''EM_ANDAMENTO'' WHERE pedido_id IN (%s, %s)', v_ped3, v_ped2),
            'REJEITADO', '23514');

    PERFORM pg_temp.verifica('B11', 'pedido: após B10, a linha válida continua NOVO (atomicidade do comando)',
            (SELECT situacao = 'NOVO' FROM bd2_demo.pedido_demo WHERE pedido_id = v_ped3));

    -- =========================================================================
    -- C. Estados inativos e falha segura (rejeita na dúvida)
    -- =========================================================================
    UPDATE bd2_meta.state_definition d SET active = false
      FROM bd2_meta.state_machine m
     WHERE m.machine_id = d.machine_id AND m.machine_name = 'PEDIDO_STATE' AND d.state_code = 'EM_ANDAMENTO';

    PERFORM pg_temp.caso('C01', 'pedido: NOVO -> EM_ANDAMENTO com o estado EM_ANDAMENTO desativado',
            format('UPDATE bd2_demo.pedido_demo SET situacao = ''EM_ANDAMENTO'' WHERE pedido_id = %s', v_ped3), 'REJEITADO', '23514');

    UPDATE bd2_meta.state_definition d SET active = true
      FROM bd2_meta.state_machine m
     WHERE m.machine_id = d.machine_id AND m.machine_name = 'PEDIDO_STATE' AND d.state_code = 'EM_ANDAMENTO';

    UPDATE bd2_meta.state_binding SET active = false
     WHERE schema_name = 'bd2_demo' AND table_name = 'pedido_demo' AND column_name = 'situacao';

    PERFORM pg_temp.caso('C02', 'pedido: INSERT com binding INATIVO (trigger ainda instalado) — falha segura',
            'INSERT INTO bd2_demo.pedido_demo (descricao) VALUES (''teste C02'')', 'REJEITADO', '55000');

    UPDATE bd2_meta.state_binding SET active = true
     WHERE schema_name = 'bd2_demo' AND table_name = 'pedido_demo' AND column_name = 'situacao';

    UPDATE bd2_meta.state_machine SET active = false WHERE machine_name = 'PEDIDO_STATE';

    PERFORM pg_temp.caso('C03', 'pedido: INSERT com a MÁQUINA inativa — falha segura',
            'INSERT INTO bd2_demo.pedido_demo (descricao) VALUES (''teste C03'')', 'REJEITADO', '55000');

    UPDATE bd2_meta.state_machine SET active = true WHERE machine_name = 'PEDIDO_STATE';

    PERFORM pg_temp.caso('C04', 'pedido: INSERT após reativar binding e máquina',
            'INSERT INTO bd2_demo.pedido_demo (descricao) VALUES (''teste C04'')', 'ACEITO');

    -- =========================================================================
    -- D. Gestão de bindings (registrar / remover)
    -- =========================================================================
    PERFORM pg_temp.caso('D01', 'registrar_binding de novo na MESMA coluna (idempotência: não duplica binding nem trigger)',
            'CALL bd2_meta.registrar_binding(''bd2_demo'', ''pedido_demo'', ''situacao'', ''PEDIDO_STATE'')', 'ACEITO');

    PERFORM pg_temp.verifica('D02', 'após D01: exatamente 1 binding e 1 trigger zz_fsm_ em pedido_demo',
            (SELECT count(*) FROM bd2_meta.state_binding
              WHERE schema_name = 'bd2_demo' AND table_name = 'pedido_demo' AND column_name = 'situacao') = 1
        AND (SELECT count(*) FROM pg_trigger
              WHERE tgrelid = 'bd2_demo.pedido_demo'::regclass AND tgname LIKE 'zz\_fsm\_%') = 1);

    PERFORM pg_temp.caso('D03', 'registrar_binding em tabela inexistente',
            'CALL bd2_meta.registrar_binding(''bd2_demo'', ''nao_existe'', ''situacao'', ''PEDIDO_STATE'')', 'REJEITADO', '42P01');

    PERFORM pg_temp.caso('D04', 'registrar_binding em coluna inexistente',
            'CALL bd2_meta.registrar_binding(''bd2_demo'', ''pedido_demo'', ''nao_existe'', ''PEDIDO_STATE'')', 'REJEITADO', '42703');

    PERFORM pg_temp.caso('D05', 'registrar_binding em coluna de tipo não suportado (timestamp)',
            'CALL bd2_meta.registrar_binding(''public'', ''invoice'', ''invoice_date'', ''INVOICE_STATE'')', 'REJEITADO', '22023');

    PERFORM pg_temp.caso('D06', 'registrar_binding com máquina inexistente',
            'CALL bd2_meta.registrar_binding(''bd2_demo'', ''pedido_demo'', ''situacao'', ''NAO_EXISTE'')', 'REJEITADO', '22023');

    PERFORM pg_temp.caso('D07', 'remover_binding de pedido_demo.situacao',
            'CALL bd2_meta.remover_binding(''bd2_demo'', ''pedido_demo'', ''situacao'')', 'ACEITO');

    PERFORM pg_temp.verifica('D08', 'após D07: trigger removido e binding desativado (sem trigger órfão)',
            NOT EXISTS (SELECT 1 FROM pg_trigger
                         WHERE tgrelid = 'bd2_demo.pedido_demo'::regclass AND tgname LIKE 'zz\_fsm\_%')
        AND NOT (SELECT active FROM bd2_meta.state_binding
                  WHERE schema_name = 'bd2_demo' AND table_name = 'pedido_demo' AND column_name = 'situacao'));

    v_ped_inv := pg_temp.caso('D09', 'pedido: sem binding, valor fora do DTE (QUALQUER) não é validado',
                 'INSERT INTO bd2_demo.pedido_demo (descricao, situacao) VALUES (''teste D09'', ''QUALQUER'') RETURNING pedido_id', 'ACEITO');

    PERFORM pg_temp.caso('D10', 'registrar_binding com dados existentes inválidos (linha QUALQUER)',
            'CALL bd2_meta.registrar_binding(''bd2_demo'', ''pedido_demo'', ''situacao'', ''PEDIDO_STATE'')', 'REJEITADO', '23514');

    DELETE FROM bd2_demo.pedido_demo WHERE pedido_id = v_ped_inv;

    PERFORM pg_temp.caso('D11', 'registrar_binding após corrigir os dados',
            'CALL bd2_meta.registrar_binding(''bd2_demo'', ''pedido_demo'', ''situacao'', ''PEDIDO_STATE'')', 'ACEITO');

    PERFORM pg_temp.caso('D12', 'pedido: após re-registro, NOVO -> CONCLUIDO volta a ser rejeitado',
            format('UPDATE bd2_demo.pedido_demo SET situacao = ''CONCLUIDO'' WHERE pedido_id = %s', v_ped3), 'REJEITADO', '23514');

    -- Tabela com uma coluna chamada "t" (nome comum de apelido em SQL dinâmico)
    CREATE TABLE bd2_demo.teste_coluna_t (id int PRIMARY KEY, t int, situacao text DEFAULT 'NOVO');
    INSERT INTO bd2_demo.teste_coluna_t VALUES (1, 5, 'NOVO');

    PERFORM pg_temp.caso('D13', 'registrar_binding em tabela com dados válidos e uma coluna chamada t',
            'CALL bd2_meta.registrar_binding(''bd2_demo'', ''teste_coluna_t'', ''situacao'', ''PEDIDO_STATE'')', 'ACEITO');

    CALL bd2_meta.remover_binding('bd2_demo', 'teste_coluna_t', 'situacao');
    DROP TABLE bd2_demo.teste_coluna_t;

    -- Renomeação da coluna e da tabela vinculadas
    CREATE TABLE bd2_demo.teste_renomear (id int PRIMARY KEY, situacao text DEFAULT 'NOVO');
    CALL bd2_meta.registrar_binding('bd2_demo', 'teste_renomear', 'situacao', 'PEDIDO_STATE');
    ALTER TABLE bd2_demo.teste_renomear RENAME COLUMN situacao TO fase;

    PERFORM pg_temp.caso('D14', 'renomear: INSERT depois de renomear a COLUNA vinculada (falha segura)',
            'INSERT INTO bd2_demo.teste_renomear (id) VALUES (1)', 'REJEITADO', '55000');

    PERFORM pg_temp.caso('D15', 'renomear: remover_binding com o nome ANTIGO da coluna',
            'CALL bd2_meta.remover_binding(''bd2_demo'', ''teste_renomear'', ''situacao'')', 'ACEITO');

    PERFORM pg_temp.verifica('D16', 'renomear: após D15, nenhum trigger do motor sobra na tabela',
            NOT EXISTS (SELECT 1 FROM pg_trigger
                         WHERE tgrelid = 'bd2_demo.teste_renomear'::regclass AND tgname LIKE 'zz\_fsm\_%'));

    PERFORM pg_temp.caso('D17', 'renomear: registrar_binding com o nome NOVO da coluna',
            'CALL bd2_meta.registrar_binding(''bd2_demo'', ''teste_renomear'', ''fase'', ''PEDIDO_STATE'')', 'ACEITO');

    ALTER TABLE bd2_demo.teste_renomear RENAME TO teste_renomeada;

    PERFORM pg_temp.caso('D18', 'renomear: INSERT depois de renomear a TABELA vinculada (falha segura)',
            'INSERT INTO bd2_demo.teste_renomeada (id) VALUES (2)', 'REJEITADO', '55000');

    PERFORM pg_temp.caso('D19', 'renomear: remover_binding com o nome ANTIGO da tabela',
            'CALL bd2_meta.remover_binding(''bd2_demo'', ''teste_renomear'', ''fase'')', 'ACEITO');

    PERFORM pg_temp.caso('D20', 'renomear: registrar_binding com o nome NOVO da tabela',
            'CALL bd2_meta.registrar_binding(''bd2_demo'', ''teste_renomeada'', ''fase'', ''PEDIDO_STATE'')', 'ACEITO');

    PERFORM pg_temp.verifica('D21', 'renomear: exatamente 1 trigger do motor na tabela (sem trigger duplicado)',
            (SELECT count(*) FROM pg_trigger
              WHERE tgrelid = 'bd2_demo.teste_renomeada'::regclass AND tgname LIKE 'zz\_fsm\_%') = 1);

    PERFORM pg_temp.caso('D22', 'renomear: após refazer o vínculo, INSERT em NOVO é aceito',
            'INSERT INTO bd2_demo.teste_renomeada (id) VALUES (3)', 'ACEITO');

    PERFORM pg_temp.caso('D23', 'renomear: e a transição NOVO -> CONCLUIDO continua rejeitada',
            'UPDATE bd2_demo.teste_renomeada SET fase = ''CONCLUIDO'' WHERE id = 3', 'REJEITADO', '23514');

    -- limpeza das tabelas e vínculos de teste
    CALL bd2_meta.remover_binding('bd2_demo', 'teste_renomeada', 'fase');
    DROP TABLE bd2_demo.teste_renomeada;
    DELETE FROM bd2_meta.state_binding
     WHERE schema_name = 'bd2_demo' AND table_name IN ('teste_coluna_t', 'teste_renomear', 'teste_renomeada');

    -- =========================================================================
    -- E. Integridade da configuração do DTE
    -- =========================================================================
    PERFORM pg_temp.caso('E01', 'config: transição saindo de estado terminal (CONCLUIDO -> NOVO)',
            $q$INSERT INTO bd2_meta.state_transition (machine_id, from_state, to_state)
               SELECT machine_id, 'CONCLUIDO', 'NOVO' FROM bd2_meta.state_machine WHERE machine_name = 'PEDIDO_STATE'$q$,
            'REJEITADO', '23514');

    PERFORM pg_temp.caso('E02', 'config: marcar como terminal um estado com saídas (EM_ANDAMENTO)',
            $q$UPDATE bd2_meta.state_definition d SET is_terminal = true
                 FROM bd2_meta.state_machine m
                WHERE m.machine_id = d.machine_id AND m.machine_name = 'PEDIDO_STATE' AND d.state_code = 'EM_ANDAMENTO'$q$,
            'REJEITADO', '23514');

    PERFORM pg_temp.caso('E03', 'config: segundo estado inicial na mesma máquina',
            $q$INSERT INTO bd2_meta.state_definition (machine_id, state_code, is_initial)
               SELECT machine_id, 'RASCUNHO', true FROM bd2_meta.state_machine WHERE machine_name = 'PEDIDO_STATE'$q$,
            'REJEITADO', '23505');

    PERFORM pg_temp.caso('E04', 'config: transição para estado não cadastrado',
            $q$INSERT INTO bd2_meta.state_transition (machine_id, from_state, to_state)
               SELECT machine_id, 'NOVO', 'INEXISTENTE' FROM bd2_meta.state_machine WHERE machine_name = 'PEDIDO_STATE'$q$,
            'REJEITADO', '23503');

    -- =========================================================================
    -- F. Prova de generalidade
    -- =========================================================================
    PERFORM pg_temp.verifica('F01', 'os triggers das 2 tabelas usam a MESMA função (mesmo OID)',
            (SELECT count(DISTINCT tg.tgfoid) = 1 AND count(*) = 2
               FROM bd2_meta.state_binding b
               JOIN pg_trigger tg
                 ON tg.tgrelid = format('%I.%I', b.schema_name, b.table_name)::regclass
                AND tg.tgname  = b.trigger_name
              WHERE b.active));

    PERFORM pg_temp.verifica('F02', 'o código da função não contém nomes de tabela, coluna ou estado da demo',
            (SELECT p.prosrc !~* '\m(invoice|pedido_demo|status|situacao)\M'
                AND p.prosrc !~  '\m(PENDENTE|PAGO|CANCELADO|NOVO|EM_ANDAMENTO|CONCLUIDO)\M'
               FROM pg_proc p
              WHERE p.oid = 'bd2_meta.fn_validar_transicao_estado'::regproc));

    -- =========================================================================
    -- Limpeza das linhas criadas pelo teste (DELETE não é transição de estado)
    -- =========================================================================
    DELETE FROM public.invoice WHERE invoice_id IN (v_inv1, v_inv2);
    DELETE FROM bd2_demo.pedido_demo WHERE descricao LIKE 'teste %';
END $$;

\set QUIET off

\set bloco 'Q5 (DTE)'
\set evid_nome p1_q5_cenario_teste
\ir lib/resumo.sql

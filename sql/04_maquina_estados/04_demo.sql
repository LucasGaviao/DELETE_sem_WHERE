-- =============================================================================
-- Parte 1 — Questão 5 (4/4): Cenário de Demonstração do Motor DTE
-- Arquivo: sql/04_maquina_estados/04_demo.sql
--
-- Configura DUAS máquinas, em DUAS tabelas, com nomes de coluna DIFERENTES,
-- reutilizando a MESMA função de trigger sem nenhuma alteração de código:
--
--   1. public.invoice.status   (extensão do grupo ao Chinook)
--        máquina INVOICE_STATE, política INITIAL_ONLY
--
--            ┌──────────┐ ──► PAGO       (terminal)
--            │ PENDENTE │
--            └──────────┘ ──► CANCELADO  (terminal)
--             (inicial)
--
--   2. bd2_demo.pedido_demo.situacao   (tabela de demonstração)
--        máquina PEDIDO_STATE, política ANY_VALID_STATE
--
--        NOVO ──► EM_ANDAMENTO ──► CONCLUIDO  (terminal)
--          │           │
--          └─────┬─────┘
--                ▼
--            CANCELADO (terminal)
--
-- O cenário de teste (casos aceitos e rejeitados) está em
-- sql/06_testes/02_testes_maquina_estados.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Colunas/tabelas de estado
-- -----------------------------------------------------------------------------
-- Extensão do grupo: o Chinook original não tem coluna de situação em invoice.
-- As 412 faturas existentes recebem o estado inicial pelo DEFAULT.
ALTER TABLE public.invoice
    ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'PENDENTE';

-- Segunda tabela: coluna com outro nome e propositalmente ANULÁVEL, para
-- demonstrar que é o motor (e não um NOT NULL) que rejeita estado nulo.
CREATE TABLE IF NOT EXISTS bd2_demo.pedido_demo (
    pedido_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    descricao  text NOT NULL,
    situacao   text DEFAULT 'NOVO'
);

-- -----------------------------------------------------------------------------
-- 2. Máquinas, estados e transições (apenas DADOS)
-- -----------------------------------------------------------------------------
INSERT INTO bd2_meta.state_machine (machine_name, description, insert_policy)
VALUES ('INVOICE_STATE', 'Ciclo de vida de uma fatura (public.invoice.status)', 'INITIAL_ONLY'),
       ('PEDIDO_STATE',  'Ciclo de vida de um pedido de demonstração (bd2_demo.pedido_demo.situacao)', 'ANY_VALID_STATE')
ON CONFLICT (machine_name) DO NOTHING;

INSERT INTO bd2_meta.state_definition (machine_id, state_code, description, is_initial, is_terminal)
SELECT m.machine_id, s.state_code, s.description, s.is_initial, s.is_terminal
  FROM bd2_meta.state_machine m
  JOIN (VALUES
        ('INVOICE_STATE', 'PENDENTE',     'Fatura emitida, aguardando pagamento', true,  false),
        ('INVOICE_STATE', 'PAGO',         'Fatura quitada',                        false, true),
        ('INVOICE_STATE', 'CANCELADO',    'Fatura cancelada',                      false, true),
        ('PEDIDO_STATE',  'NOVO',         'Pedido recebido',                       true,  false),
        ('PEDIDO_STATE',  'EM_ANDAMENTO', 'Pedido em processamento',               false, false),
        ('PEDIDO_STATE',  'CONCLUIDO',    'Pedido entregue',                       false, true),
        ('PEDIDO_STATE',  'CANCELADO',    'Pedido cancelado',                      false, true)
       ) AS s(machine_name, state_code, description, is_initial, is_terminal)
    ON s.machine_name = m.machine_name
ON CONFLICT (machine_id, state_code) DO NOTHING;

INSERT INTO bd2_meta.state_transition (machine_id, from_state, to_state, description)
SELECT m.machine_id, t.from_state, t.to_state, t.description
  FROM bd2_meta.state_machine m
  JOIN (VALUES
        ('INVOICE_STATE', 'PENDENTE',     'PAGO',         'Pagamento confirmado'),
        ('INVOICE_STATE', 'PENDENTE',     'CANCELADO',    'Fatura cancelada antes do pagamento'),
        ('PEDIDO_STATE',  'NOVO',         'EM_ANDAMENTO', 'Início do processamento'),
        ('PEDIDO_STATE',  'NOVO',         'CANCELADO',    'Cancelado antes do processamento'),
        ('PEDIDO_STATE',  'EM_ANDAMENTO', 'CONCLUIDO',    'Pedido entregue'),
        ('PEDIDO_STATE',  'EM_ANDAMENTO', 'CANCELADO',    'Cancelado durante o processamento')
       ) AS t(machine_name, from_state, to_state, description)
    ON t.machine_name = m.machine_name
ON CONFLICT (machine_id, from_state, to_state) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 3. Vincular as máquinas às colunas (instala os triggers)
-- -----------------------------------------------------------------------------
CALL bd2_meta.registrar_binding('public',   'invoice',     'status',   'INVOICE_STATE');
CALL bd2_meta.registrar_binding('bd2_demo', 'pedido_demo', 'situacao', 'PEDIDO_STATE');

-- -----------------------------------------------------------------------------
-- 4. Configuração resultante (evidência para o relatório)
-- -----------------------------------------------------------------------------
SELECT machine_name, insert_policy, from_state, to_state
  FROM bd2_meta.vw_dte_transicoes
 ORDER BY machine_name, from_state, to_state;

SELECT schema_name, table_name, column_name, machine_name,
       binding_ativo, trigger_instalado, trigger_name
  FROM bd2_meta.vw_dte_bindings
 ORDER BY schema_name, table_name;

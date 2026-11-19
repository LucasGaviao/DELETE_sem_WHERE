-- =============================================================================
-- Parte 1 — Questão 5 (1/4): Tabelas de Configuração do Motor DTE
-- Arquivo: sql/04_maquina_estados/01_tabelas_configuracao.sql
--
-- Princípio: estados e transições são DADOS, não código. Um mesmo motor
-- (função de trigger genérica) valida qualquer coluna de estado de qualquer
-- tabela, bastando cadastrar a máquina e registrar o vínculo (binding).
--
-- Objetos em bd2_meta:
--   - state_machine      : uma máquina (DTE) e sua política de inserção
--   - state_definition   : estados da máquina (inicial / terminal / ativo)
--   - state_transition   : arestas permitidas (from_state -> to_state)
--   - state_binding      : vínculo máquina <-> (schema, tabela, coluna)
--   - fn_validar_config_transicao / fn_validar_config_estado : integridade
--     do próprio DTE (nenhuma aresta saindo de estado terminal)
--   - vw_dte_transicoes / vw_dte_bindings : visões para inspeção/relatório
--
-- Nenhum nome de tabela/coluna do esquema exemplo é usado neste arquivo.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS bd2_meta;

-- -----------------------------------------------------------------------------
-- 1. Máquina de estados
-- -----------------------------------------------------------------------------
-- insert_policy:
--   INITIAL_ONLY    -> uma linha nova só pode nascer no estado inicial
--   ANY_VALID_STATE -> uma linha nova pode nascer em qualquer estado ativo
--                      (útil p.ex. para carga de dados históricos)
CREATE TABLE IF NOT EXISTS bd2_meta.state_machine (
    machine_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    machine_name   text    NOT NULL UNIQUE CHECK (btrim(machine_name) <> ''),
    description    text,
    insert_policy  text    NOT NULL DEFAULT 'INITIAL_ONLY'
                   CHECK (insert_policy IN ('INITIAL_ONLY', 'ANY_VALID_STATE')),
    active         boolean NOT NULL DEFAULT true
);

-- -----------------------------------------------------------------------------
-- 2. Estados
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bd2_meta.state_definition (
    machine_id   integer NOT NULL
                 REFERENCES bd2_meta.state_machine (machine_id) ON DELETE CASCADE,
    state_code   text    NOT NULL CHECK (btrim(state_code) <> ''),
    description  text,
    is_initial   boolean NOT NULL DEFAULT false,
    is_terminal  boolean NOT NULL DEFAULT false,
    active       boolean NOT NULL DEFAULT true,
    PRIMARY KEY (machine_id, state_code)
);

-- No máximo um estado inicial por máquina.
CREATE UNIQUE INDEX IF NOT EXISTS state_definition_um_inicial_uidx
    ON bd2_meta.state_definition (machine_id)
 WHERE is_initial;

-- -----------------------------------------------------------------------------
-- 3. Transições (arestas do DTE)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bd2_meta.state_transition (
    machine_id   integer NOT NULL,
    from_state   text    NOT NULL,
    to_state     text    NOT NULL,
    description  text,
    PRIMARY KEY (machine_id, from_state, to_state),
    CHECK (from_state <> to_state),
    FOREIGN KEY (machine_id, from_state)
        REFERENCES bd2_meta.state_definition (machine_id, state_code)
        ON UPDATE CASCADE ON DELETE CASCADE,
    FOREIGN KEY (machine_id, to_state)
        REFERENCES bd2_meta.state_definition (machine_id, state_code)
        ON UPDATE CASCADE ON DELETE CASCADE
);

-- -----------------------------------------------------------------------------
-- 4. Vínculo máquina <-> coluna de estado
-- -----------------------------------------------------------------------------
-- UNIQUE(schema, tabela, coluna): cada coluna tem no máximo um binding.
-- registrar_binding faz upsert (ON CONFLICT ... DO UPDATE), portanto é
-- idempotente e pode trocar a máquina de uma coluna já vinculada.
CREATE TABLE IF NOT EXISTS bd2_meta.state_binding (
    binding_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schema_name    text    NOT NULL,
    table_name     text    NOT NULL,
    column_name    text    NOT NULL,
    machine_id     integer NOT NULL REFERENCES bd2_meta.state_machine (machine_id),
    trigger_name   text    NOT NULL,
    active         boolean NOT NULL DEFAULT true,
    registered_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (schema_name, table_name, column_name)
);

-- -----------------------------------------------------------------------------
-- 5. Integridade do próprio DTE: estado terminal não pode ter aresta de saída
-- -----------------------------------------------------------------------------
-- (Uma CHECK não consegue consultar outra tabela; por isso triggers.)

-- 5.1 Ao cadastrar/alterar transição: origem não pode ser terminal.
CREATE OR REPLACE FUNCTION bd2_meta.fn_validar_config_transicao()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM bd2_meta.state_definition d
         WHERE d.machine_id = NEW.machine_id
           AND d.state_code = NEW.from_state
           AND d.is_terminal
    ) THEN
        RAISE EXCEPTION 'DTE inválido: o estado terminal "%" não pode ter transição de saída (-> "%").',
                        NEW.from_state, NEW.to_state
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_state_transition_valida
    BEFORE INSERT OR UPDATE ON bd2_meta.state_transition
    FOR EACH ROW EXECUTE FUNCTION bd2_meta.fn_validar_config_transicao();

-- 5.2 Ao marcar um estado como terminal: ele não pode ter arestas de saída.
CREATE OR REPLACE FUNCTION bd2_meta.fn_validar_config_estado()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NEW.is_terminal AND EXISTS (
        SELECT 1
          FROM bd2_meta.state_transition t
         WHERE t.machine_id = NEW.machine_id
           AND t.from_state = NEW.state_code
    ) THEN
        RAISE EXCEPTION 'DTE inválido: o estado "%" possui transições de saída e não pode ser marcado como terminal.',
                        NEW.state_code
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_state_definition_valida
    BEFORE UPDATE OF is_terminal ON bd2_meta.state_definition
    FOR EACH ROW EXECUTE FUNCTION bd2_meta.fn_validar_config_estado();

-- -----------------------------------------------------------------------------
-- 6. Visões de inspeção (usadas no relatório)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bd2_meta.vw_dte_transicoes AS
SELECT m.machine_name,
       m.insert_policy,
       t.from_state,
       t.to_state,
       t.description
  FROM bd2_meta.state_transition t
  JOIN bd2_meta.state_machine m ON m.machine_id = t.machine_id;

CREATE OR REPLACE VIEW bd2_meta.vw_dte_bindings AS
SELECT b.schema_name,
       b.table_name,
       b.column_name,
       m.machine_name,
       b.active        AS binding_ativo,
       m.active        AS maquina_ativa,
       b.trigger_name,
       EXISTS (
           SELECT 1
             FROM pg_catalog.pg_trigger tg
             JOIN pg_catalog.pg_class c      ON c.oid = tg.tgrelid
             JOIN pg_catalog.pg_namespace n  ON n.oid = c.relnamespace
            WHERE n.nspname = b.schema_name
              AND c.relname = b.table_name
              AND tg.tgname = b.trigger_name
       ) AS trigger_instalado
  FROM bd2_meta.state_binding b
  JOIN bd2_meta.state_machine m ON m.machine_id = b.machine_id;

-- -----------------------------------------------------------------------------
-- 7. Permissões
-- -----------------------------------------------------------------------------
-- A função de validação é SECURITY INVOKER: quem faz DML numa tabela vinculada
-- precisa LER a configuração. Todos podem ler; só o administrador (dono)
-- altera estados, transições e bindings.
GRANT USAGE ON SCHEMA bd2_meta TO PUBLIC;
REVOKE ALL ON bd2_meta.state_machine, bd2_meta.state_definition,
              bd2_meta.state_transition, bd2_meta.state_binding FROM PUBLIC;
GRANT SELECT ON bd2_meta.state_machine, bd2_meta.state_definition,
                bd2_meta.state_transition, bd2_meta.state_binding,
                bd2_meta.vw_dte_transicoes, bd2_meta.vw_dte_bindings TO PUBLIC;

-- =============================================================================
-- Parte 1 — Questão 5 (3/4): Procedures de Registro e Remoção de Binding DTE
-- Arquivo: sql/04_maquina_estados/03_procedures_registro.sql
-- Objetos:
--   - bd2_meta.registrar_binding(p_schema, p_tabela, p_coluna, p_machine_id int)
--   - bd2_meta.registrar_binding(p_schema, p_tabela, p_coluna, p_machine_name text)
--   - bd2_meta.remover_binding(p_schema, p_tabela, p_coluna)
--
-- O PostgreSQL não tem trigger DML "global": a FUNÇÃO é genérica e a
-- INSTALAÇÃO é por tabela. registrar_binding faz essa instalação a partir
-- dos parâmetros, com SQL dinâmico seguro (format %I / %L).
--
-- Nome do trigger: 'zz_fsm_' || md5(schema.tabela.coluna)[1..24]
--   - determinístico (re-registro substitui o mesmo trigger) e < 63 chars;
--   - prefixo 'zz_' faz o trigger rodar por ÚLTIMO entre os BEFORE triggers
--     da tabela (ordem alfabética), validando o valor final da linha mesmo
--     que outro BEFORE trigger altere a coluna de estado.
-- =============================================================================

CREATE OR REPLACE FUNCTION bd2_meta.fn_nome_trigger_fsm(p_schema text, p_tabela text, p_coluna text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT 'zz_fsm_' || substr(md5(p_schema || '.' || p_tabela || '.' || p_coluna), 1, 24);
$$;

-- -----------------------------------------------------------------------------
-- registrar_binding (por id da máquina)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE bd2_meta.registrar_binding(
    p_schema     text,
    p_tabela     text,
    p_coluna     text,
    p_machine_id integer
)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_relid        oid;
    v_typid        oid;
    v_typ          pg_type%ROWTYPE;
    v_policy       text;
    v_machine      text;
    v_trigger      text;
    v_invalidos    bigint;
BEGIN
    -- 1. Tabela existe?
    SELECT c.oid
      INTO v_relid
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = p_schema
       AND c.relname = p_tabela
       AND c.relkind IN ('r', 'p');

    IF v_relid IS NULL THEN
        RAISE EXCEPTION 'registrar_binding: tabela %.% não encontrada.', p_schema, p_tabela
              USING ERRCODE = 'undefined_table';
    END IF;

    -- 2. Coluna existe (e não é de sistema nem removida)?
    SELECT a.atttypid
      INTO v_typid
      FROM pg_attribute a
     WHERE a.attrelid = v_relid
       AND a.attname  = p_coluna
       AND a.attnum   > 0
       AND NOT a.attisdropped;

    IF v_typid IS NULL THEN
        RAISE EXCEPTION 'registrar_binding: coluna "%" não existe em %.%.', p_coluna, p_schema, p_tabela
              USING ERRCODE = 'undefined_column';
    END IF;

    -- 3. Tipo suportado? (resolve domínios até o tipo base)
    --    Suportados: text, varchar, enum e inteiros. char(n) é recusado porque
    --    o preenchimento com espaços quebra a comparação textual do estado.
    SELECT * INTO v_typ FROM pg_type WHERE oid = v_typid;
    WHILE v_typ.typtype = 'd' LOOP
        SELECT * INTO v_typ FROM pg_type WHERE oid = v_typ.typbasetype;
    END LOOP;

    IF NOT (v_typ.typtype = 'e'
            OR v_typ.oid IN ('text'::regtype, 'varchar'::regtype,
                             'int2'::regtype, 'int4'::regtype, 'int8'::regtype)) THEN
        RAISE EXCEPTION 'registrar_binding: tipo "%" da coluna %.%.% não é suportado (use text, varchar, enum ou inteiro).',
                        format_type(v_typid, NULL), p_schema, p_tabela, p_coluna
              USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- 4. Máquina existe e está ativa? Se INITIAL_ONLY, tem estado inicial ativo?
    SELECT m.machine_name, m.insert_policy
      INTO v_machine, v_policy
      FROM bd2_meta.state_machine m
     WHERE m.machine_id = p_machine_id
       AND m.active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'registrar_binding: máquina % não existe ou está inativa.', p_machine_id
              USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF v_policy = 'INITIAL_ONLY' AND NOT EXISTS (
        SELECT 1 FROM bd2_meta.state_definition d
         WHERE d.machine_id = p_machine_id AND d.is_initial AND d.active
    ) THEN
        RAISE EXCEPTION 'registrar_binding: máquina "%" usa INITIAL_ONLY mas não possui estado inicial ativo.', v_machine
              USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- 5. Dados já existentes precisam estar em estados válidos da máquina
    --    (senão a próxima transição dessas linhas seria imprevisível).
    EXECUTE format(
        'SELECT count(*)
           FROM %I.%I t
          WHERE NOT EXISTS (
                SELECT 1
                  FROM bd2_meta.state_definition d
                 WHERE d.machine_id = $1
                   AND d.active
                   AND d.state_code = (to_jsonb(t) ->> %L))',
        p_schema, p_tabela, p_coluna)
      INTO v_invalidos
     USING p_machine_id;

    IF v_invalidos > 0 THEN
        RAISE EXCEPTION 'registrar_binding: % linha(s) de %.% possuem "%" nulo ou fora dos estados ativos da máquina "%".',
                        v_invalidos, p_schema, p_tabela, p_coluna, v_machine
              USING ERRCODE = 'check_violation',
                    HINT = 'Corrija os dados existentes antes de registrar o binding.';
    END IF;

    -- 6. Upsert do binding (idempotente)
    v_trigger := bd2_meta.fn_nome_trigger_fsm(p_schema, p_tabela, p_coluna);

    INSERT INTO bd2_meta.state_binding (schema_name, table_name, column_name, machine_id, trigger_name, active)
    VALUES (p_schema, p_tabela, p_coluna, p_machine_id, v_trigger, true)
    ON CONFLICT (schema_name, table_name, column_name) DO UPDATE
       SET machine_id    = EXCLUDED.machine_id,
           trigger_name  = EXCLUDED.trigger_name,
           active        = true,
           registered_at = now();

    -- 7. (Re)instalar o trigger. BEFORE INSERT OR UPDATE (de qualquer coluna),
    --    para que nenhuma alteração da coluna de estado escape da validação;
    --    UPDATEs que não mudam o estado são aceitos de imediato pela função.
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trigger, p_schema, p_tabela);
    EXECUTE format(
        'CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I.%I
             FOR EACH ROW EXECUTE FUNCTION bd2_meta.fn_validar_transicao_estado(%L)',
        v_trigger, p_schema, p_tabela, p_coluna);

    RAISE NOTICE 'Binding registrado: %.%.% -> máquina "%" (trigger %).',
                 p_schema, p_tabela, p_coluna, v_machine, v_trigger;
END;
$$;

-- -----------------------------------------------------------------------------
-- registrar_binding (por nome da máquina) — evita depender de IDs gerados
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE bd2_meta.registrar_binding(
    p_schema       text,
    p_tabela       text,
    p_coluna       text,
    p_machine_name text
)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_machine_id integer;
BEGIN
    SELECT m.machine_id INTO v_machine_id
      FROM bd2_meta.state_machine m
     WHERE m.machine_name = p_machine_name;

    IF v_machine_id IS NULL THEN
        RAISE EXCEPTION 'registrar_binding: máquina "%" não existe.', p_machine_name
              USING ERRCODE = 'invalid_parameter_value';
    END IF;

    CALL bd2_meta.registrar_binding(p_schema, p_tabela, p_coluna, v_machine_id);
END;
$$;

-- -----------------------------------------------------------------------------
-- remover_binding: remove o trigger e desativa o binding (sem trigger órfão)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE bd2_meta.remover_binding(
    p_schema text,
    p_tabela text,
    p_coluna text
)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_trigger text;
BEGIN
    SELECT b.trigger_name INTO v_trigger
      FROM bd2_meta.state_binding b
     WHERE b.schema_name = p_schema
       AND b.table_name  = p_tabela
       AND b.column_name = p_coluna;

    IF v_trigger IS NULL THEN
        RAISE NOTICE 'remover_binding: não há binding para %.%.%; nada a fazer.', p_schema, p_tabela, p_coluna;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = p_schema AND c.relname = p_tabela
    ) THEN
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trigger, p_schema, p_tabela);
    END IF;

    UPDATE bd2_meta.state_binding
       SET active = false
     WHERE schema_name = p_schema
       AND table_name  = p_tabela
       AND column_name = p_coluna;

    RAISE NOTICE 'Binding removido: %.%.% (trigger % excluído, binding desativado).',
                 p_schema, p_tabela, p_coluna, v_trigger;
END;
$$;

-- Apenas o administrador (dono) registra/remove bindings.
REVOKE ALL ON PROCEDURE bd2_meta.registrar_binding(text, text, text, integer) FROM PUBLIC;
REVOKE ALL ON PROCEDURE bd2_meta.registrar_binding(text, text, text, text)    FROM PUBLIC;
REVOKE ALL ON PROCEDURE bd2_meta.remover_binding(text, text, text)            FROM PUBLIC;

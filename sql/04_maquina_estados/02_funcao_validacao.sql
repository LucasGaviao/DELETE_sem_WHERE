-- =============================================================================
-- Parte 1 — Questão 5 (2/4): Função de Trigger Genérica de Validação do DTE
-- Arquivo: sql/04_maquina_estados/02_funcao_validacao.sql
-- Objeto:
--   bd2_meta.fn_validar_transicao_estado() RETURNS trigger
--
-- Uma única função serve qualquer tabela/coluna:
--   - a tabela vem de TG_TABLE_SCHEMA / TG_TABLE_NAME;
--   - a coluna vem do argumento do trigger (TG_ARGV[0]);
--   - o valor é lido de forma genérica com to_jsonb(NEW) ->> coluna;
--   - a máquina, os estados e as transições vêm de bd2_meta (dados).
-- Não há nenhum nome de tabela, coluna ou estado fixo no código.
--
-- Regras:
--   INSERT : valor não nulo; estado existe e está ativo; se a política da
--            máquina for INITIAL_ONLY, o estado deve ser o inicial.
--   UPDATE : se o estado não mudou (IS NOT DISTINCT FROM) -> aceita;
--            senão: novo valor não nulo, estados antigo e novo ativos,
--            estado antigo NÃO terminal e aresta (antigo -> novo) cadastrada.
--   DELETE : fora do escopo do motor (não é transição de estado).
--   Falha segura: binding ausente/inativo ou máquina inativa -> rejeita.
--
-- Códigos de erro:
--   23514 check_violation                  -> violação do DTE
--   55000 object_not_in_prerequisite_state -> binding ausente/inativo (falha segura)
-- =============================================================================

CREATE OR REPLACE FUNCTION bd2_meta.fn_validar_transicao_estado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_coluna      text;
    v_alvo        text;
    v_machine_id  integer;
    v_machine     text;
    v_policy      text;
    v_novo        text;
    v_antigo      text;
    v_def_novo    bd2_meta.state_definition%ROWTYPE;
    v_def_antigo  bd2_meta.state_definition%ROWTYPE;
    v_row_novo    jsonb;
BEGIN
    IF TG_WHEN <> 'BEFORE' OR TG_LEVEL <> 'ROW' OR TG_OP NOT IN ('INSERT', 'UPDATE') THEN
        RAISE EXCEPTION 'fn_validar_transicao_estado deve ser usada como trigger BEFORE INSERT OR UPDATE ... FOR EACH ROW.';
    END IF;

    IF TG_NARGS <> 1 THEN
        RAISE EXCEPTION 'fn_validar_transicao_estado espera exatamente 1 argumento (nome da coluna de estado); recebeu %.', TG_NARGS;
    END IF;

    v_coluna := TG_ARGV[0];
    v_alvo   := format('%I.%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME, v_coluna);

    -- 1. Localizar binding ativo + máquina ativa (falha segura: na dúvida, rejeita)
    SELECT b.machine_id, m.machine_name, m.insert_policy
      INTO v_machine_id, v_machine, v_policy
      FROM bd2_meta.state_binding b
      JOIN bd2_meta.state_machine m ON m.machine_id = b.machine_id
     WHERE b.schema_name = TG_TABLE_SCHEMA
       AND b.table_name  = TG_TABLE_NAME
       AND b.column_name = v_coluna
       AND b.active
       AND m.active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DTE [%]: não há binding ativo (ou a máquina está inativa) para esta coluna; operação rejeitada (falha segura).', v_alvo
              USING ERRCODE = 'object_not_in_prerequisite_state',
                    HINT = 'Use CALL bd2_meta.registrar_binding(...) ou bd2_meta.remover_binding(...).';
    END IF;

    -- 2. Ler o valor de estado de forma genérica
    v_row_novo := to_jsonb(NEW);
    IF NOT (v_row_novo ? v_coluna) THEN
        RAISE EXCEPTION 'DTE [%]: a coluna não existe na tabela (renomeada?); operação rejeitada.', v_alvo
              USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    v_novo := v_row_novo ->> v_coluna;

    -- 3. UPDATE sem mudança de estado: nada a validar
    IF TG_OP = 'UPDATE' THEN
        v_antigo := to_jsonb(OLD) ->> v_coluna;
        IF v_novo IS NOT DISTINCT FROM v_antigo THEN
            RETURN NEW;
        END IF;
    END IF;

    -- 4. Novo estado: não nulo, existente e ativo
    IF v_novo IS NULL THEN
        RAISE EXCEPTION 'DTE [% / máquina %]: o estado não pode ser nulo.', v_alvo, v_machine
              USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_def_novo
      FROM bd2_meta.state_definition d
     WHERE d.machine_id = v_machine_id
       AND d.state_code = v_novo;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DTE [% / máquina %]: estado "%" não existe.', v_alvo, v_machine, v_novo
              USING ERRCODE = 'check_violation';
    ELSIF NOT v_def_novo.active THEN
        RAISE EXCEPTION 'DTE [% / máquina %]: estado "%" está inativo.', v_alvo, v_machine, v_novo
              USING ERRCODE = 'check_violation';
    END IF;

    -- 5. INSERT: política de nascimento
    IF TG_OP = 'INSERT' THEN
        IF v_policy = 'INITIAL_ONLY' AND NOT v_def_novo.is_initial THEN
            RAISE EXCEPTION 'DTE [% / máquina %]: uma nova linha deve nascer no estado inicial; "%" não é inicial.',
                            v_alvo, v_machine, v_novo
                  USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;

    -- 6. UPDATE: estado antigo e aresta (antigo -> novo)
    IF v_antigo IS NULL THEN
        -- Só ocorre se a linha foi gravada sem o trigger (antes do binding ou
        -- com o trigger desabilitado). registrar_binding impede essa situação.
        RAISE EXCEPTION 'DTE [% / máquina %]: estado atual é nulo; transição para "%" rejeitada.', v_alvo, v_machine, v_novo
              USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_def_antigo
      FROM bd2_meta.state_definition d
     WHERE d.machine_id = v_machine_id
       AND d.state_code = v_antigo;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DTE [% / máquina %]: estado atual "%" não existe na máquina; transição rejeitada.', v_alvo, v_machine, v_antigo
              USING ERRCODE = 'check_violation';
    ELSIF NOT v_def_antigo.active THEN
        RAISE EXCEPTION 'DTE [% / máquina %]: estado atual "%" está inativo; transição rejeitada.', v_alvo, v_machine, v_antigo
              USING ERRCODE = 'check_violation';
    ELSIF v_def_antigo.is_terminal THEN
        RAISE EXCEPTION 'DTE [% / máquina %]: "%" é estado terminal; nenhuma transição é permitida (tentativa: "%" -> "%").',
                        v_alvo, v_machine, v_antigo, v_antigo, v_novo
              USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM bd2_meta.state_transition t
         WHERE t.machine_id = v_machine_id
           AND t.from_state = v_antigo
           AND t.to_state   = v_novo
    ) THEN
        RAISE EXCEPTION 'DTE [% / máquina %]: transição "%" -> "%" não é permitida pelo diagrama.',
                        v_alvo, v_machine, v_antigo, v_novo
              USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION bd2_meta.fn_validar_transicao_estado() IS
    'Trigger genérico de validação de DTE. Argumento: nome da coluna de estado. Configuração em bd2_meta.state_*.';

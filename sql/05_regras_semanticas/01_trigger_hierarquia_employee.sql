-- =============================================================================
-- Parte 2 — Questão 2: Trigger Semântico R-TRG-01 (Hierarquia sem Ciclos)
-- Arquivo: sql/05_regras_semanticas/01_trigger_hierarquia_employee.sql
--
-- Regra: employee.reports_to deve formar uma hierarquia acíclica; nenhum
-- funcionário pode ser, direta ou indiretamente, superior de si mesmo.
--
-- Por que é semântica: a FK employee_reports_to_fkey só garante que o
-- superior existe; uma CHECK só enxerga a própria linha (pegaria A -> A, mas
-- não A -> B -> C -> A).
--
-- Mecanismo:
--   BEFORE INSERT OR UPDATE OF reports_to, employee_id ON public.employee
--   1. auto-referência -> rejeita;
--   2. pg_advisory_xact_lock serializa alterações de hierarquia;
--   3. sobe a cadeia de superiores a partir de NEW.reports_to (WITH RECURSIVE,
--      com proteção contra laço) e rejeita se encontrar NEW.employee_id.
--
-- Concorrência:
--   READ COMMITTED (padrão): o lock é obtido num comando e a CTE roda no
--   comando seguinte, com snapshot novo -> enxerga a hierarquia já
--   confirmada pela transação que segurava o lock.
--   REPEATABLE READ / SERIALIZABLE: o snapshot é fixo; por isso a cadeia lida
--   é travada com FOR SHARE. Se outra transação alterou um desses superiores
--   depois do snapshot, o PostgreSQL aborta com erro de serialização (40001)
--   e a aplicação deve repetir a transação. Testado em 04_concorrencia.sh.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_employee_sem_ciclo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_cadeia  integer[];
    v_ciclo   boolean;
BEGIN
    IF NEW.reports_to IS NULL THEN
        RETURN NEW;                       -- raiz da hierarquia: nada a verificar
    END IF;

    IF TG_OP = 'UPDATE'
       AND NEW.reports_to  IS NOT DISTINCT FROM OLD.reports_to
       AND NEW.employee_id IS NOT DISTINCT FROM OLD.employee_id THEN
        RETURN NEW;                       -- hierarquia não mudou
    END IF;

    IF NEW.reports_to = NEW.employee_id THEN
        RAISE EXCEPTION 'R-TRG-01: o funcionário % não pode ser superior de si mesmo.', NEW.employee_id
              USING ERRCODE = 'check_violation';
    END IF;

    -- Serializa alterações concorrentes de hierarquia (liberado no fim da transação)
    PERFORM pg_advisory_xact_lock(hashtext('bd2:R-TRG-01:public.employee.reports_to'));

    -- Cadeia de superiores a partir do novo superior.
    -- Ciclo se algum elo É o funcionário alterado, ou SE REPORTA a ele
    -- (o segundo caso cobre linhas do mesmo comando ainda não visíveis por
    --  employee_id, p.ex. INSERT de várias linhas que se referenciam).
    WITH RECURSIVE cadeia AS (
        SELECT e.employee_id, e.reports_to, ARRAY[e.employee_id] AS caminho
          FROM public.employee e
         WHERE e.employee_id = NEW.reports_to
        UNION ALL
        SELECT e.employee_id, e.reports_to, c.caminho || e.employee_id
          FROM public.employee e
          JOIN cadeia c ON e.employee_id = c.reports_to
         WHERE e.employee_id <> ALL (c.caminho)          -- proteção contra laço
    )
    SELECT array_agg(employee_id),
           bool_or(employee_id = NEW.employee_id OR reports_to = NEW.employee_id)
      INTO v_cadeia, v_ciclo
      FROM cadeia;

    IF v_ciclo THEN
        RAISE EXCEPTION 'R-TRG-01: definir % como superior de % criaria um ciclo na hierarquia (cadeia: %).',
                        NEW.reports_to, NEW.employee_id, array_to_string(v_cadeia, ' -> ')
              USING ERRCODE = 'check_violation';
    END IF;

    -- Snapshot fixo: travar a cadeia para detectar alteração concorrente
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        PERFORM 1
          FROM public.employee e
         WHERE e.employee_id = ANY (v_cadeia)
           FOR SHARE;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_employee_sem_ciclo
    BEFORE INSERT OR UPDATE OF reports_to, employee_id ON public.employee
    FOR EACH ROW EXECUTE FUNCTION public.fn_employee_sem_ciclo();

-- Auditoria: a hierarquia atual (seed) precisa ser acíclica antes de ativar a regra.
DO $$
DECLARE
    v_ciclos int;
BEGIN
    WITH RECURSIVE sobe AS (
        SELECT e.employee_id AS origem, e.reports_to AS atual, 1 AS nivel
          FROM public.employee e
         WHERE e.reports_to IS NOT NULL
        UNION ALL
        SELECT s.origem, e.reports_to, s.nivel + 1
          FROM sobe s
          JOIN public.employee e ON e.employee_id = s.atual
         WHERE e.reports_to IS NOT NULL
           AND s.atual <> s.origem
           AND s.nivel < (SELECT count(*) FROM public.employee)
    )
    SELECT count(DISTINCT origem) INTO v_ciclos FROM sobe WHERE atual = origem;

    ASSERT v_ciclos = 0, format('R-TRG-01: a hierarquia atual já contém %s funcionário(s) em ciclo.', v_ciclos);
    RAISE NOTICE 'R-TRG-01 instalado: hierarquia atual de employee é acíclica.';
END $$;

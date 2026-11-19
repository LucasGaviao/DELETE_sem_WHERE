-- =============================================================================
-- Testes Automatizados — Parte 1, Questões 1 a 4
-- Arquivo: sql/06_testes/01_testes_parte1_q1_a_q4.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Testes Q1 (listar_indices) e Q3 (listar_foreign_keys)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_cnt int;
    v_key_cols text[];
    v_inc_cols text[];
    v_is_partial boolean;
    v_pos1_local text;
    v_pos2_local text;
BEGIN
    -- Q1: Verificar exclusão de schemas de sistema por padrão
    SELECT count(*) INTO v_cnt
      FROM bd2_meta.vw_indices
     WHERE schema_name IN ('pg_catalog', 'information_schema');
    ASSERT v_cnt = 0, 'Q1: vw_indices não deve retornar schemas de sistema por padrão';

    -- Q1: Verificar índices do Chinook em public
    SELECT count(*) INTO v_cnt
      FROM bd2_meta.listar_indices('public', false);
    ASSERT v_cnt > 0, 'Q1: deveria listar índices no schema public';

    -- Q1: Testar índice composto + INCLUDE + parcial em tabela auxiliar
    CREATE TABLE bd2_demo.teste_idx (
        id int PRIMARY KEY,
        a int NOT NULL,
        b text NOT NULL,
        c int
    );
    CREATE INDEX idx_teste_composto_inc_parcial
        ON bd2_demo.teste_idx (a, b)
        INCLUDE (c)
        WHERE a > 0;

    SELECT key_columns, include_columns, is_partial
      INTO v_key_cols, v_inc_cols, v_is_partial
      FROM bd2_meta.listar_indices('bd2_demo', false)
     WHERE table_name = 'teste_idx'
       AND index_name = 'idx_teste_composto_inc_parcial';

    ASSERT v_key_cols = ARRAY['a', 'b'], format('Q1: key_columns esperado {a,b}, obtido %s', v_key_cols);
    ASSERT v_inc_cols = ARRAY['c'], format('Q1: include_columns esperado {c}, obtido %s', v_inc_cols);
    ASSERT v_is_partial = true, 'Q1: is_partial deveria ser true';

    -- Q3: Verificar autorreferência em employee
    SELECT count(*) INTO v_cnt
      FROM bd2_meta.listar_foreign_keys('public')
     WHERE local_table = 'employee'
       AND local_column = 'reports_to'
       AND ref_table = 'employee'
       AND ref_column = 'employee_id';
    ASSERT v_cnt = 1, 'Q3: autorreferência employee.reports_to -> employee.employee_id não encontrada';

    -- Q3: Testar FK composta na ordem correta
    CREATE TABLE bd2_demo.teste_pai_composto (
        k1 int NOT NULL,
        k2 int NOT NULL,
        PRIMARY KEY (k1, k2)
    );
    CREATE TABLE bd2_demo.teste_filho_composto (
        id int PRIMARY KEY,
        fk1 int NOT NULL,
        fk2 int NOT NULL,
        CONSTRAINT fk_composta_teste FOREIGN KEY (fk1, fk2)
            REFERENCES bd2_demo.teste_pai_composto (k1, k2)
    );

    SELECT local_column INTO v_pos1_local
      FROM bd2_meta.listar_foreign_keys('bd2_demo')
     WHERE constraint_name = 'fk_composta_teste' AND key_position = 1;
    SELECT local_column INTO v_pos2_local
      FROM bd2_meta.listar_foreign_keys('bd2_demo')
     WHERE constraint_name = 'fk_composta_teste' AND key_position = 2;

    ASSERT v_pos1_local = 'fk1' AND v_pos2_local = 'fk2',
        'Q3: pareamento posicional de FK composta incorreto';

    DROP TABLE bd2_demo.teste_filho_composto;
    DROP TABLE bd2_demo.teste_pai_composto;
    DROP TABLE bd2_demo.teste_idx;

    RAISE NOTICE 'OK: Testes Q1 e Q3 passaram.';
END $$;

-- -----------------------------------------------------------------------------
-- 2. Testes Q2 (remover_indices_tabela)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_resumo jsonb;
    v_cnt int;
    v_falhou boolean := false;
BEGIN
    -- Caso positivo: tabela auxiliar com índice independente + PK + UNIQUE
    CREATE TABLE bd2_demo.teste_rem_idx (
        id int PRIMARY KEY,
        codigo text UNIQUE,
        valor int
    );
    CREATE INDEX idx_teste_rem_valor ON bd2_demo.teste_rem_idx (valor);

    -- 2.1 Remover apenas índices independentes (padrão)
    CALL bd2_meta.remover_indices_tabela('bd2_demo', 'teste_rem_idx', false, false, v_resumo);

    SELECT count(*) INTO v_cnt
      FROM bd2_meta.listar_indices('bd2_demo', false)
     WHERE table_name = 'teste_rem_idx';
    ASSERT v_cnt = 2, format('Q2: esperados 2 índices de constraint preservados, encontrados %s', v_cnt);

    -- 2.2 Remover incluindo constraints (PK e UNIQUE)
    CALL bd2_meta.remover_indices_tabela('bd2_demo', 'teste_rem_idx', true, false, v_resumo);

    SELECT count(*) INTO v_cnt
      FROM bd2_meta.listar_indices('bd2_demo', false)
     WHERE table_name = 'teste_rem_idx';
    ASSERT v_cnt = 0, format('Q2: esperados 0 índices após p_incluir_constraints=true, encontrados %s', v_cnt);

    DROP TABLE bd2_demo.teste_rem_idx;

    -- Caso negativo: tentar remover PK de public.employee sem CASCADE deve falhar (FKs dependentes)
    BEGIN
        CALL bd2_meta.remover_indices_tabela('public', 'employee', true, false, v_resumo);
    EXCEPTION WHEN dependent_objects_still_exist THEN
        v_falhou := true;
    END;
    ASSERT v_falhou, 'Q2: remoção da PK de employee sem CASCADE deveria falhar por dependência de FK';

    RAISE NOTICE 'OK: Testes Q2 passaram.';
END $$;

-- Q2 com p_cascade: remover TODOS os índices de uma tabela cuja PK é referenciada
DO $$
DECLARE
    v_resumo jsonb;
    v_idx    int;
    v_fk     int;
BEGIN
    CREATE TABLE bd2_demo.q2_pai   (id int PRIMARY KEY, nome text);
    CREATE INDEX q2_pai_nome_idx ON bd2_demo.q2_pai (nome);
    CREATE TABLE bd2_demo.q2_filho (id int PRIMARY KEY, pai_id int REFERENCES bd2_demo.q2_pai (id));

    CALL bd2_meta.remover_indices_tabela('bd2_demo', 'q2_pai', p_incluir_constraints => true, p_cascade => true, p_resumo => v_resumo);

    SELECT count(*) INTO v_idx FROM bd2_meta.listar_indices('bd2_demo') WHERE table_name = 'q2_pai';
    SELECT count(*) INTO v_fk  FROM bd2_meta.listar_foreign_keys('bd2_demo') WHERE local_table = 'q2_filho';
    ASSERT v_idx = 0, format('Q2 (CASCADE): esperados 0 índices em q2_pai, encontrados %s', v_idx);
    ASSERT v_fk  = 0, format('Q2 (CASCADE): a FK de q2_filho deveria ter sido removida junto, encontradas %s', v_fk);

    DROP TABLE bd2_demo.q2_filho, bd2_demo.q2_pai;
    RAISE NOTICE 'OK: Testes Q2 (CASCADE) passaram.';
END $$;

-- -----------------------------------------------------------------------------
-- 3. Testes Q4 (gerar_ddl_tabelas)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_ddl text;
    v_tbl_orig int;
    v_tbl_clone int;
    v_pk_orig int;
    v_pk_clone int;
    v_fk_orig int;
    v_fk_clone int;
    v_fk_falhou boolean := false;
BEGIN
    SELECT bd2_meta.gerar_ddl_tabelas('public', 'chinook_clone', true) INTO v_ddl;
    ASSERT v_ddl IS NOT NULL AND length(v_ddl) > 100, 'Q4: DDL gerado vazio ou inválido';

    -- Executar o DDL gerado para validar sintaxe e integridade estrutural
    EXECUTE v_ddl;

    SELECT count(*) INTO v_tbl_orig FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r';
    SELECT count(*) INTO v_tbl_clone FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'chinook_clone' AND c.relkind = 'r';
    ASSERT v_tbl_orig = 11 AND v_tbl_clone = 11,
        format('Q4: contagem de tabelas divergente (orig=%s, clone=%s)', v_tbl_orig, v_tbl_clone);

    SELECT count(*) INTO v_pk_orig FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'public' AND c.contype = 'p';
    SELECT count(*) INTO v_pk_clone FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'chinook_clone' AND c.contype = 'p';
    ASSERT v_pk_orig = v_pk_clone,
        format('Q4: contagem de PKs divergente (orig=%s, clone=%s)', v_pk_orig, v_pk_clone);

    SELECT count(*) INTO v_fk_orig FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'public' AND c.contype = 'f';
    SELECT count(*) INTO v_fk_clone FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = 'chinook_clone' AND c.contype = 'f';
    ASSERT v_fk_orig = v_fk_clone,
        format('Q4: contagem de FKs divergente (orig=%s, clone=%s)', v_fk_orig, v_fk_clone);

    -- Testar se FK no clone bloqueia inserção órfã
    BEGIN
        INSERT INTO chinook_clone.album (album_id, title, artist_id) VALUES (1, 'Teste', 999999);
    EXCEPTION WHEN foreign_key_violation THEN
        v_fk_falhou := true;
    END;
    ASSERT v_fk_falhou, 'Q4: FK no schema chinook_clone deveria rejeitar artist_id inexistente';

    DROP SCHEMA chinook_clone CASCADE;

    RAISE NOTICE 'OK: Testes Q4 passaram.';
END $$;

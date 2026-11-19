-- =============================================================================
-- Parte 2 — Questão 3 (1/2): Papéis e Permissões (bd2_owner e bd2_app)
-- Arquivo: sql/05_regras_semanticas/00_roles_e_permissoes.sql
--
-- Modelo (exigência: "criar um usuário que somente tenha acesso à manipulação
-- dos dados envolvidos através do procedimento definido"):
--
--   bd2_owner  NOLOGIN, não superusuário. Dono da procedure R-SP-01
--              (SECURITY DEFINER): a procedure executa com os privilégios
--              dele, que são apenas os necessários para criar a fatura.
--   bd2_app    LOGIN, o "usuário da aplicação". Nenhum privilégio de DML (nem
--              de leitura) em invoice / invoice_line; somente EXECUTE na
--              procedure (concedido em 03_procedure_criar_fatura.sql).
--
-- Papéis são objetos do CLUSTER (sobrevivem a DROP DATABASE): o script é
-- idempotente e reaplica os atributos se os papéis já existirem.
--
-- Senha: bd2_app recebe uma senha de DEMONSTRAÇÃO (padrão 'bd2_app'), para que
-- seja possível conectar de fato como esse usuário:
--     psql -h localhost -U bd2_app -d chinook_serial
-- Outra senha pode ser passada com psql -v bd2_app_senha=... (o run_all.sh usa
-- a variável de ambiente BD2_APP_PASSWORD). Em produção, a senha não ficaria
-- no código.
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bd2_owner') THEN
        CREATE ROLE bd2_owner;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bd2_app') THEN
        CREATE ROLE bd2_app;
    END IF;
END $$;

ALTER ROLE bd2_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
ALTER ROLE bd2_app   LOGIN   NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;

\if :{?bd2_app_senha}
\else
    \set bd2_app_senha 'bd2_app'
\endif
ALTER ROLE bd2_app PASSWORD :'bd2_app_senha';

COMMENT ON ROLE bd2_owner IS 'BD2: dono da procedure R-SP-01 (SECURITY DEFINER); não faz login.';
COMMENT ON ROLE bd2_app   IS 'BD2: usuário da aplicação; manipula faturas somente via public.criar_fatura_com_itens.';

-- -----------------------------------------------------------------------------
-- bd2_app: garantir que NÃO há nenhum privilégio direto sobre as tabelas.
-- (Defensivo: nada foi concedido, mas o script pode rodar sobre um banco
--  em que alguém concedeu algo antes.)
-- -----------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM bd2_app;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM bd2_app;

-- -----------------------------------------------------------------------------
-- bd2_owner: privilégios mínimos para a procedure R-SP-01 funcionar
-- -----------------------------------------------------------------------------
-- Leitura do cliente (dados de cobrança) e da faixa (preço oficial)
GRANT SELECT ON public.customer, public.track TO bd2_owner;

-- INSERT ... RETURNING exige SELECT além de INSERT (verificado em PG 16).
-- SELECT em invoice_line também é usado pelo trigger A de R-TRG-02.
GRANT SELECT, INSERT ON public.invoice, public.invoice_line TO bd2_owner;

-- O trigger B de R-TRG-02 (executado no contexto do bd2_owner durante a
-- procedure) atualiza invoice.total.
GRANT UPDATE (total) ON public.invoice TO bd2_owner;

-- Defaults SERIAL das PKs
GRANT USAGE ON SEQUENCE public.invoice_invoice_id_seq,
                        public.invoice_line_invoice_line_id_seq TO bd2_owner;

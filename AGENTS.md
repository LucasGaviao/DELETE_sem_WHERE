# Instruções para Agentes de Programação (`AGENTS.md`)

Projeto acadêmico de **Banco de Dados II** (UFF — Prof. Rodrigo Salvador Monteiro) em **PostgreSQL 16**.
Antes de alterar ou implementar qualquer módulo, leia os documentos em `docs/` e os enunciados em `docs/especificacao/`.

## Fatos Verificados do Ambiente

- **SGBD alvo:** PostgreSQL 16 (`postgres:16-alpine` via Docker Compose).
- **Esquema exemplo:** Chinook Database v1.4.5, variante **`Chinook_PostgreSql_SerialPKs.sql`** (`sql/00_ambiente/Chinook_PostgreSql_SerialPKs.sql`, SHA-256: `847361ebbd17aaa18b5423831bf3bfc7ab1f0ad3c62c5bfe4770242bec5ddaf1`).
- **Banco criado pelo script do Chinook:** `chinook_serial` (o script executa `DROP DATABASE IF EXISTS chinook_serial; CREATE DATABASE chinook_serial; \c chinook_serial;`).
- **Nomenclatura real no banco:** todas as 11 tabelas ficam no schema `public` com nomes em **`snake_case` minúsculo** (`album`, `artist`, `customer`, `employee`, `genre`, `invoice`, `invoice_line`, `media_type`, `playlist`, `playlist_track`, `track`) e colunas em `snake_case` (`invoice_id`, `unit_price`, `reports_to`, `support_rep_id`, etc.). **Nunca use CamelCase com aspas (`"Invoice"`, `"InvoiceId"`).**
- **Roles são objetos do cluster:** `bd2_owner` e `bd2_app` sobrevivem a `DROP DATABASE`. Scripts de criação e remoção de roles devem ser sempre idempotentes.

## Regras Obrigatórias de Implementação

1. **Inspeção prévia:** antes de codificar, inspecione o banco real (`\dt`, `\d <tabela>`, catálogos do PostgreSQL).
2. **Generalidade nos módulos 1 a 3 (`01_catalogos`, `02_administracao`, `03_ddl_dinamico`, `04_maquina_estados`):** proibido usar nomes fixos de tabelas, índices ou colunas do Chinook nesses módulos.
3. **SQL dinâmico seguro:** use sempre `format('%I', ...)` / `format('%L', ...)` e qualifique objetos por schema. Nunca concatene identificadores manualmente.
4. **Remoção de índices (Parte 1 — Q2):** diferencie índices independentes de índices que sustentam constraints (`pg_constraint`). Ao fazer join com `pg_constraint`, filtre obrigatoriamente por:
   ```sql
   con.conindid = i.indexrelid
   AND con.conrelid = i.indrelid
   AND con.contype IN ('p', 'u', 'x')
   ```
   (Sem isso, `conindid` casa FKs de outras tabelas que referenciam a PK!). Nunca aplique `CASCADE` sem parâmetro explícito (`p_cascade = true`).
5. **Gerador de `CREATE TABLE` (Parte 1 — Q4):** função retorna o texto DDL (`RETURNS text`), **não executa**. Gere em duas fases: (A) `CREATE TABLE` + PK; (B) `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY` montadas a partir de `conkey`/`confkey` com schema de destino explícito.
6. **Máquina de Estados / DTE (Parte 1 — Q5):** estados e transições são dados em `bd2_meta`. A procedure `registrar_binding` deve ser idempotente (`ON CONFLICT ... DO UPDATE`). Inclua `remover_binding`. Comportamento *fail-closed* (se binding inativo ou ausente, rejeitar). Demonstre em `public.invoice.status` **e** em uma segunda tabela (`bd2_demo.pedido_demo`) com outro nome de coluna (`situacao`).
7. **Parte 2 — Ordem e Dependências:**
   - `00_roles_e_permissoes.sql` antes das procedures (`bd2_owner` precisa de `SELECT` além de `INSERT` em `invoice` por causa do `INSERT ... RETURNING`).
   - `01_trigger_hierarquia_employee.sql` (R-TRG-01: prevenção de ciclo em `employee.reports_to` com CTE recursiva + `pg_advisory_xact_lock`).
   - `02_integridade_invoice_total.sql` (R-TRG-02: triggers A + C mantendo `invoice.total = SUM(unit_price * quantity)`). **Deve ser instalado antes de R-SP-01.**
   - `03_procedure_criar_fatura.sql` (R-SP-01: `criar_fatura_com_itens(int, jsonb, INOUT p_invoice_id int DEFAULT NULL)` — chamada com 2 argumentos, devolve o id criado — com `SECURITY DEFINER`, `SET search_path = pg_catalog, public, pg_temp` (`pg_temp` por último), `OWNER TO bd2_owner`, `EXECUTE` apenas para `bd2_app`; nos `GRANT`/`ALTER` a assinatura é `(integer, jsonb, integer)`).
8. **Testes:** cada requisito deve ter casos positivos e negativos automatizados (`DO $$ ... ASSERT ... $$` com `psql -v ON_ERROR_STOP=1`), sem depender de IDs fixos mágicos não controlados, além de teste de concorrência com sessões `psql` paralelas (`sql/06_testes/04_concorrencia.sh`). Use o harness comum (`\ir lib/harness.sql` + `pg_temp.caso(...)` / `pg_temp.verifica(...)` e, no fim, `\set bloco`, `\set evid_nome` e `\ir lib/resumo.sql`).
9. **Entrega:** relatório em PDF + código. O relatório (`relatorio/relatorio.tex`, LaTeX padrão, sem cores) é texto formal e enxuto — não reproduz código nem saídas completas; os números citados vêm de `relatorio/numeros.tex`, gerado a partir de `evidencias/`; após mudar código, rode `./run_all.sh`, `python3 relatorio/gerar_relatorio.py` e `./empacotar_entrega.sh`.

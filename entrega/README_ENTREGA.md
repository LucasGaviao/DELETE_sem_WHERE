# Banco de Dados II — Trabalho em Grupo (Partes 1 e 2)

Prof. Rodrigo Salvador Monteiro — UFF

Este pacote contém o **relatório** (`Relatorio_Trabalho_BD2.pdf`) e todo o **código** necessário para executar as
questões das Partes 1 e 2 em **PostgreSQL 16** sobre o esquema **Chinook** (v1.4.5, variante `SerialPKs`).

## Conteúdo

| Item | Descrição |
|---|---|
| `Relatorio_Trabalho_BD2.pdf` | Relatório: enunciado, solução adotada e resultado de cada questão |
| `sql/00_ambiente/` | Script oficial do Chinook e verificação do ambiente |
| `sql/01_catalogos/` | Parte 1 — Q1 (índices) e Q3 (chaves estrangeiras) |
| `sql/02_administracao/` | Parte 1 — Q2 (procedimento que remove os índices de uma tabela) |
| `sql/03_ddl_dinamico/` | Parte 1 — Q4 (geração dinâmica de `CREATE TABLE`) |
| `sql/04_maquina_estados/` | Parte 1 — Q5 (motor genérico de diagrama de transição de estados + cenário) |
| `sql/05_regras_semanticas/` | Parte 2 — Q1 a Q4 (papéis, triggers e stored procedure) |
| `sql/06_testes/` | Testes automatizados (positivos, negativos e de concorrência) |
| `sql/07_evidencias/` | Geração das saídas usadas no relatório |
| `run_all.sh` / `run_all.ps1` | Executam tudo do zero (banco, instalação, testes e evidências) |
| `docker-compose.yml` | Ambiente PostgreSQL 16 padronizado |
| `evidencias/` | Saídas da execução que gerou o relatório |

## Como executar

A execução **recria o banco `chinook_serial`**, instala todos os scripts na ordem correta, roda todos os testes e
grava as saídas em `evidencias/` (substituindo as que acompanham o pacote, que são as da execução que gerou o
relatório). Ao final aparece `Execução concluída com sucesso!`; se algum teste falhar, a
execução é interrompida com código de saída diferente de zero.

Todos os comandos abaixo são executados **dentro da pasta `Trabalho_BD2/`** extraída do zip.

### Opção 1 — Docker (recomendado)

Pré-requisitos: Docker com Docker Compose, a **porta `5432` livre** (nenhum outro PostgreSQL usando essa porta;
caso contrário o `docker compose up` falha com `port is already allocated`) e nenhum outro container chamado
`bd2_postgres`.

```bash
docker compose up -d --wait

# Linux / macOS / Git Bash (usa o psql local, ou o do container se não houver psql instalado):
./run_all.sh
```

```powershell
# Windows (PowerShell) — sobe o container e executa tudo dentro dele:
.\run_all.ps1
# se o Windows bloquear scripts (execution policy):
powershell -ExecutionPolicy Bypass -File .\run_all.ps1
```

**Porta 5432 ocupada?** Crie um arquivo `.env` a partir do `.env.example` com outra porta (ex.: `POSTGRES_PORT=5433`).
O `run_all.ps1` funciona sem mais nada; para o `./run_all.sh` com psql local, informe também `PGPORT=5433 ./run_all.sh`.
(Se mudar também `POSTGRES_PASSWORD` no `.env`, informe a mesma senha em `PGPASSWORD`, pois o `run_all.sh` não lê o
`.env`.)

Para abrir um terminal SQL no banco depois da execução:

```bash
docker compose exec postgres psql -U postgres -d chinook_serial
```

### Opção 2 — PostgreSQL 16 já instalado

Com o cliente `psql` no PATH e um usuário **superusuário** (o script cria o banco e os papéis `bd2_owner`/`bd2_app`):

```bash
PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=<senha> ./run_all.sh
```

> Atenção: o script do Chinook executa `DROP DATABASE IF EXISTS chinook_serial`.

## Exemplos de uso no `psql`

Alguns exemplos alteram dados (por exemplo, o estado da fatura 1); para voltar ao estado original, basta executar
`./run_all.sh` novamente.

```sql
-- P1-Q1 / Q3: índices e chaves estrangeiras
SELECT * FROM bd2_meta.listar_indices('public');
SELECT * FROM bd2_meta.listar_foreign_keys('public');

-- P1-Q2: remove TODOS os índices de uma tabela (inclusive os de PK/UNIQUE);
--        aqui dentro de uma transação desfeita, para não alterar o Chinook
BEGIN;
CALL bd2_meta.remover_indices_tabela('public', 'invoice_line', p_incluir_constraints => true);
SELECT count(*) FROM bd2_meta.listar_indices('public') WHERE table_name = 'invoice_line';  -- 0
ROLLBACK;

-- P1-Q4: DDL do esquema exemplo
SELECT bd2_meta.gerar_ddl_tabelas('public', 'public', true);

-- P1-Q5: transições de estado (máquina INVOICE_STATE em invoice.status)
UPDATE invoice SET status = 'PAGO' WHERE invoice_id = 1;      -- aceita (PENDENTE -> PAGO)
UPDATE invoice SET status = 'PENDENTE' WHERE invoice_id = 1;  -- rejeitada (PAGO é terminal)
```

### Usuário da aplicação (Parte 2 — Q3)

O usuário `bd2_app` tem uma senha de demonstração, **`bd2_app`**, e só consegue manipular faturas pela procedure:

```bash
# com psql instalado na máquina (pede a senha: bd2_app)
psql -h localhost -U bd2_app -d chinook_serial

# só com Docker: conecta pelo IP do container, que exige senha (bd2_app)
docker compose exec postgres sh -c 'psql -h "$(hostname -i)" -U bd2_app -d chinook_serial'
```

> Dentro do container, conexões a `localhost` usam autenticação `trust` (padrão da imagem oficial do PostgreSQL) e
> não pedem senha; por isso o segundo comando usa o IP do container.

```sql
CALL public.criar_fatura_com_itens(1, '[{"track_id": 1, "quantity": 2}]');   -- cria a fatura
CALL public.criar_fatura_com_itens(1, '[]');                                 -- rejeitada: fatura sem itens
INSERT INTO invoice (customer_id, invoice_date, total) VALUES (1, now(), 0); -- permission denied
SELECT * FROM invoice;                                                       -- permission denied
```

# Banco de Dados II — Trabalho Final em Grupo (UFF)

Repositório oficial do trabalho em grupo da disciplina **Banco de Dados II** (Prof. Rodrigo Salvador Monteiro — UFF), desenvolvido em **PostgreSQL 16** sobre o esquema **Chinook Database v1.4.5 (`SerialPKs`)**.

---

## 1. Especificação doAmbiente e Reprodutibilidade

| Item | Valor Padronizado |
|---|---|
| **SGBD** | PostgreSQL `16` (imagem Docker oficial `postgres:16-alpine`) |
| **Esquema Exemplo** | [Chinook Database v1.4.5](https://github.com/lerocha/chinook-database/releases/tag/v1.4.5) |
| **Variante Utilizada** | `Chinook_PostgreSql_SerialPKs.sql` (`sql/00_ambiente/Chinook_PostgreSql_SerialPKs.sql`) |
| **SHA-256 da Variante** | `847361ebbd17aaa18b5423831bf3bfc7ab1f0ad3c62c5bfe4770242bec5ddaf1` |
| **Nome do Banco Criado** | `chinook_serial` (schema principal: `public`, tabelas e colunas em `snake_case`) |
| **Schemas Auxiliares** | `bd2_meta` (motor DTE e utilitários genéricos), `bd2_demo` (tabelas de demonstração) |

---

## 2. Como Executar o Ambiente (Docker Compose)

Todos os integrantes do grupo podem subir exatamente a mesma versão do PostgreSQL 16 sem precisar instalar o servidor localmente.

### Pré-requisitos
- **Docker** e **Docker Compose** (Docker Desktop no Windows/macOS ou Docker Engine no Linux)
- **Git**

### Passo a Passo Rápido

1. **Subir o container do PostgreSQL 16:**
   ```bash
   docker compose up -d
   ```

2. **Executar a carga limpa do Chinook + scripts + verificação inicial:**
   - **No Windows (PowerShell):**
     ```powershell
     .\run_all.ps1
     ```
   - **No Linux / macOS / Git Bash:**
     ```bash
     ./run_all.sh
     ```

3. **Abrir um terminal interativo `psql` conectado ao banco `chinook_serial`:**
   ```bash
   docker compose exec postgres psql -U postgres -d chinook_serial
   ```

---

## 3. Estrutura do Repositório

```text
trabalho_final_bd2/
├── README.md                      # Guia principal, ambiente e instruções para o grupo
├── AGENTS.md                      # Contexto e regras técnicas para agentes (Antigravity / Claude Code)
├── docker-compose.yml             # Ambiente PostgreSQL 16 padronizado
├── .env.example                   # Variáveis de ambiente padrão
├── run_all.sh                     # Script de recriação limpa, carga e testes (Bash)
├── run_all.ps1                    # Wrapper para execução no Windows (PowerShell)
├── docs/
│   ├── especificacao/             # Enunciados do professor (PDFs) e planejamento técnico v3
│   │   ├── Especificacao Trabalho - Parte 1.pdf
│   │   ├── Especificacao Trabalho - Parte 2.pdf
│   │   └── planejamento_bd2_v3.md
│   ├── arquitetura.md             # Arquitetura em 4 blocos, schemas e ordem de execução
│   ├── decisoes.md                # Decisões técnicas (D1..D9) e pendências com o professor
│   ├── regras-semanticas.md       # Descrição textual das regras semânticas (Parte 2 - Q1)
│   └── roteiro-demonstracao.md    # Passo a passo para apresentação e validação
├── sql/
│   ├── 00_ambiente/
│   │   ├── Chinook_PostgreSql_SerialPKs.sql   # Base oficial v1.4.5
│   │   └── 00_verificar_ambiente.sql          # Criação de schemas e auditoria inicial
│   ├── 01_catalogos/
│   │   ├── 01_listar_indices.sql              # Parte 1 - Q1
│   │   └── 02_listar_foreign_keys.sql         # Parte 1 - Q3
│   ├── 02_administracao/
│   │   └── 01_remover_indices.sql             # Parte 1 - Q2
│   ├── 03_ddl_dinamico/
│   │   └── 01_gerar_create_table.sql          # Parte 1 - Q4
│   ├── 04_maquina_estados/
│   │   ├── 01_tabelas_configuracao.sql        # Parte 1 - Q5 (metadados DTE)
│   │   ├── 02_funcao_validacao.sql            # Parte 1 - Q5 (trigger function genérica)
│   │   ├── 03_procedures_registro.sql         # Parte 1 - Q5 (registrar/remover binding)
│   │   └── 04_demo.sql                        # Parte 1 - Q5 (cenário de teste em 2 tabelas)
│   ├── 05_regras_semanticas/
│   │   ├── 00_roles_e_permissoes.sql          # Parte 2 - Q3 (bd2_owner e bd2_app)
│   │   ├── 01_trigger_hierarquia_employee.sql # Parte 2 - Q2 (R-TRG-01: ciclo em employee)
│   │   ├── 02_integridade_invoice_total.sql   # Parte 2 - Q4 (R-TRG-02: invoice.total)
│   │   └── 03_procedure_criar_fatura.sql      # Parte 2 - Q3 (R-SP-01: criar_fatura_com_itens)
│   └── 06_testes/
│       └── 00_suite_testes.sql                # Testes automatizados positivos e negativos
└── evidencias/                    # Logs e saídas de execução comprovando os testes
```

---

## 4. Rastreabilidade das Questões

| Parte | Questão | Descrição Resumida | Arquivo(s) Alvo |
|---|---|---|---|
| **Parte 1** | **Q1** | Listar índices, tabelas e colunas via catálogo | `sql/01_catalogos/01_listar_indices.sql` |
| **Parte 1** | **Q2** | Procedure que remove todos os índices de uma tabela informada | `sql/02_administracao/01_remover_indices.sql` |
| **Parte 1** | **Q3** | Listar chaves estrangeiras, tabelas e colunas via catálogo | `sql/01_catalogos/02_listar_foreign_keys.sql` |
| **Parte 1** | **Q4** | Script/função que gera dinamicamente `CREATE TABLE` (colunas, PK, FK) | `sql/03_ddl_dinamico/01_gerar_create_table.sql` |
| **Parte 1** | **Q5** | Solução genérica de validação de Diagrama de Transição de Estados (DTE) + teste | `sql/04_maquina_estados/01..04_*.sql` |
| **Parte 2** | **Q1** | Criar regras semânticas e descrevê-las textualmente | `docs/regras-semanticas.md` |
| **Parte 2** | **Q2** | Implementar triggers que validem as regras semânticas | `sql/05_regras_semanticas/01_trigger_hierarquia_employee.sql` |
| **Parte 2** | **Q3** | Implementar stored procedures + usuário restrito por permissões | `sql/05_regras_semanticas/00_roles_e_permissoes.sql` e `03_procedure_criar_fatura.sql` |
| **Parte 2** | **Q4** | Garantir integridade de `Invoice.Total = SUM(UnitPrice * Quantity)` | `sql/05_regras_semanticas/02_integridade_invoice_total.sql` |

---

## 5. Fluxo de Trabalho Git para o Grupo

1. Clone o repositório e suba o ambiente com `docker compose up -d`.
2. Crie uma branch por tarefa/questão (ex.: `feat/p1-q1-listar-indices`, `feat/p1-q5-maquina-estados`, `feat/p2-regras-semanticas`).
3. Antes de abrir um Pull Request, execute `./run_all.sh` (ou `.\run_all.ps1`) para garantir que todos os scripts rodam do zero sem erros (`ON_ERROR_STOP=1`).

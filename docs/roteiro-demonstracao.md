# Roteiro de Demonstração e Avaliação (`roteiro-demonstracao.md`)

Este documento descreve o passo a passo para executar e demonstrar cada requisito do trabalho (Parte 1 e Parte 2) em ambiente limpo.

## 1. Subindo o Ambiente

```bash
# 1. Subir o container PostgreSQL 16
docker compose up -d

# 2. Executar toda a carga + scripts + bateria de testes
# No Linux / macOS / Git Bash:
./run_all.sh

# No Windows (PowerShell):
.\run_all.ps1
```

## 2. Roteiro por Questão

### Parte 1
1. **Questão 1 (Catálogo — Listagem de Índices):** `sql/01_catalogos/01_listar_indices.sql`
2. **Questão 2 (PL/pgSQL — Remoção de Índices de uma Tabela):** `sql/02_administracao/01_remover_indices.sql`
3. **Questão 3 (Catálogo — Listagem de Chaves Estrangeiras):** `sql/01_catalogos/02_listar_foreign_keys.sql`
4. **Questão 4 (PL/pgSQL — Geração Dinâmica de `CREATE TABLE`):** `sql/03_ddl_dinamico/01_gerar_create_table.sql`
5. **Questão 5 (PL/pgSQL — Motor Genérico de Máquina de Estados / DTE):** `sql/04_maquina_estados/01..04_*.sql`

### Parte 2
1. **Questão 1 (Descrição Textual das Regras Semânticas):** `docs/regras-semanticas.md`
2. **Questão 2 (Validação via Triggers — `R-TRG-01`):** `sql/05_regras_semanticas/01_trigger_hierarquia_employee.sql`
3. **Questão 3 (Validação via Stored Procedure + Permissões — `R-SP-01`):** `sql/05_regras_semanticas/00_roles_e_permissoes.sql` e `03_procedure_criar_fatura.sql`
4. **Questão 4 (Integridade de `Invoice.Total` — `R-TRG-02`):** `sql/05_regras_semanticas/02_integridade_invoice_total.sql`

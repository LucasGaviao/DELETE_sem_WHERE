# Decisões de Projeto e Pendências (`decisoes.md`)

Este documento registra as decisões arquiteturais adotadas pelo grupo e as pendências de alinhamento com o Prof. Rodrigo Salvador Monteiro.

---

## 1. Pendências de Confirmação com o Professor (todas resolvidas)

Conforme o enunciado da Parte 1 (*"O SGBD escolhido deve ser informado antes do início da execução do trabalho e a escolha deverá ter a concordância do professor"*):

- [x] **P1 — Escolha do SGBD:** Confirmar o uso do **PostgreSQL** com o professor. *(Confirmado.)*
- [x] **P2 — Versão do SGBD:** Confirmar a versão do PostgreSQL utilizada no ambiente de avaliação/laboratório. *(Decisão do grupo: **PostgreSQL 16**, fixado via Docker `postgres:16-alpine`; versão declarada no relatório.)*
- [x] **P3 — Formato de entrega:** *(Definido: **relatório em PDF** + **código necessário para executar tudo o que foi pedido** nos enunciados. O relatório contém a resposta de cada questão das Partes 1 e 2 — explicação, código SQL e evidência de execução dos testes. O código deve rodar do zero em ambiente limpo seguindo as instruções do README. Sem apresentação ao vivo.)*
- [x] **P4 — Uso de schemas auxiliares:** *(Decisão do grupo: objetos de infraestrutura em `bd2_meta` e de demonstração em `bd2_demo`; Chinook original intacto em `public`. Justificativa registrada no relatório.)*
- [x] **P5 — Quantidade de regras semânticas (Parte 2 — Q1):** *(Resolvido pelo enunciado da Parte 2: "Deverá ser entregue pelo menos 1 caso implementado através de triggers e 1 caso implementado através de procedimentos armazenados." As 3 regras — `R-TRG-01`, `R-TRG-02` (Q4) e `R-SP-01` — atendem ao mínimo.)*

---

## 2. Decisões Técnicas Adotadas (`D1`–`D8`)

| ID | Tópico | Decisão Adotada | Justificativa |
|---|---|---|---|
| **D1** | Variante do Chinook | `Chinook_PostgreSql_SerialPKs.sql` (v1.4.5) | Possui `SERIAL` (`nextval`) nas PKs e sequences sincronizadas (`max(invoice_id) = 412`), permitindo inserções sem informar ID manual na procedure R-SP-01 e nos testes. |
| **D2** | Remoção de Índices (P1-Q2) | Remove apenas índices independentes por padrão; constraints (`p`, `u`, `x`) e `CASCADE` são *opt-in* | Índices que sustentam PK/UNIQUE/EXCLUDE exigem `ALTER TABLE ... DROP CONSTRAINT`. Filtro `conrelid = i.indrelid AND contype IN ('p','u','x')` evita atingir FKs externas. **Relatório:** mostrar explicitamente a chamada que remove *todos* os índices (`p_incluir_constraints => true`, e `p_cascade => true` quando houver FKs externas) e justificar o padrão seguro. |
| **D3** | Escopo do Gerador DDL (P1-Q4) | Escopo mínimo exigido (colunas, tipos, `NOT NULL`, PK, FK) em 2 fases; retorna `text` | Evita necessidade de ordenação topológica em FKs cíclicas/autorreferenciadas (`employee.reports_to`) e remapeia explicitamente o schema de destino via `conkey`/`confkey`. |
| **D4** | Motor DTE (P1-Q5) | Motor dirigido por tabelas em `bd2_meta` + 2 tabelas de demonstração (`public.invoice.status` e `bd2_demo.pedido_demo.situacao`) | Comprova generalidade e reusabilidade da função de trigger única sem qualquer código específico de tabela ou coluna. |
| **D5** | Regras via Trigger (P2-Q2) | `R-TRG-01` (hierarquia acíclica em `employee.reports_to`) e `R-TRG-02` (`invoice.total`) | Regras semânticas clássicas que não podem ser expressas apenas por constraints declarativas (`CHECK`, `FK`, `UNIQUE`). |
| **D6** | Regra via Stored Procedure (P2-Q3) | `R-SP-01` (`criar_fatura_com_itens(customer_id, itens jsonb)`) | Garante que toda fatura criada pela aplicação já nasça com ao menos 1 item válido em `invoice_line`. |
| **D7** | Integridade de `Invoice.Total` (P2-Q4) | Triggers `BEFORE INSERT OR UPDATE OF total ON invoice` (A) + `AFTER INSERT OR UPDATE OR DELETE ON invoice_line` (C) | Cobre inserções, atualizações, exclusões, trocas de `invoice_id` e tentativas de edição direta de `invoice.total`. |
| **D8** | Modelo de Permissões (P2-Q3) | `bd2_owner` (`NOLOGIN`, dono da procedure com `SECURITY DEFINER`) e `bd2_app` (`LOGIN`, apenas `EXECUTE` na procedure) | Impede que o usuário `bd2_app` execute DML direto em `invoice` ou `invoice_line`, forçando a passagem pela validação semântica da procedure. |
| **D9** | Ambiente de Execução | Docker Compose com `postgres:16-alpine` | Padroniza a versão exata do PostgreSQL e ferramentas (`psql`, `pgbench`) entre todos os integrantes do grupo (Windows/Linux/macOS). |

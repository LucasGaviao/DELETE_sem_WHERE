# Banco de Dados II — Planejamento técnico (PostgreSQL) — v3

**Finalidade:** especificação de análise e arquitetura para orientar o grupo e servir de contexto a um agente de programação (Claude Code / Antigravity). Não é a implementação final: define contratos, decisões, riscos, critérios de aceite e testes.

**Origem:** consolida `planejamento_bd2_postgresql.md` (v1) e `planejamento_bd2.md` (v2), corrigido após execução real contra **PostgreSQL 16.15 + Chinook 1.4.5** (ver §14).

---

## 0. Como ler este documento

| Marca | Significado |
|---|---|
| **[EXIGÊNCIA]** | Está explícito nos PDFs do professor |
| **[PROPOSTA]** | Decisão de projeto recomendada |
| **[PENDENTE]** | Precisa de confirmação do grupo/professor |
| **[VERIFICADO]** | Executado e confirmado em PG 16.15 + Chinook 1.4.5 |
| **[NÃO VERIFICADO]** | Raciocínio/documentação; o agente deve testar antes de confiar |

**Regra de ouro para o agente:** os trechos de código deste documento são *referências*, não verdade absoluta. Em v2 havia esqueletos com bugs reais (ver §14). Todo código deve ser executado e testado antes de ser considerado pronto.

---

## 1. Escopo e rastreabilidade

### 1.1 Parte 1 [EXIGÊNCIA]

| # | Exigência | Entrega | Módulo |
|---|---|---|---|
| 1.1 | Listar índices (tabelas e colunas) via catálogo | Consulta/view parametrizada por schema | §4.1 |
| 1.2 | Procedimento que remove todos os índices de uma tabela (parâmetro) | Procedure PL/pgSQL | §4.2 |
| 1.3 | Listar chaves estrangeiras (tabelas e colunas) via catálogo | Consulta/view | §4.3 |
| 1.4 | Gerar dinamicamente `CREATE TABLE` (colunas, tipo, obrigatoriedade, PK, FK) | Função que retorna texto DDL | §4.4 |
| 1.5 | Validar estados e transições conforme DTE; **quanto mais genérico, melhor**; com cenário de teste | Motor configurável + demo | §5 |

### 1.2 Parte 2 [EXIGÊNCIA]

| # | Exigência | Entrega | Módulo |
|---|---|---|---|
| 2.1 | Criar regras semânticas e **descrevê-las textualmente** no trabalho | `docs/regras-semanticas.md` | §6 |
| 2.2 | Triggers que validem as regras | R-TRG-01, R-TRG-02 | §6.2, §7 |
| 2.3 | Stored procedures que validem as regras + **usuário que só manipule os dados via a procedure** | R-SP-01 + roles | §6.3, §8 |
| 2.4 | Garantir `Invoice.Total = Σ UnitPrice × Quantity` | R-TRG-02 | §7 |

**Mínimo obrigatório:** ≥ 1 caso por trigger e ≥ 1 caso por procedure.

### 1.3 Arquitetura em quatro blocos

1. **Inspeção de metadados** (somente leitura sobre catálogos).
2. **Administração e DDL dinâmico** (rotinas parametrizadas).
3. **Motor configurável de estados** (tabelas de configuração + função de trigger genérica + procedure de registro).
4. **Integridade semântica** (regras Chinook, triggers, procedure, permissões, testes).

Módulos 1–3 não podem conhecer tabelas do Chinook. O módulo 4 pode.

---

## 2. Decisões

### 2.1 Pendências que dependem do professor [PENDENTE] — fazer **antes** de codar

O enunciado da Parte 1 diz que o SGBD deve ser informado antes do início e **ter a concordância do professor**. Nenhuma versão anterior listava isso.

1. Confirmar PostgreSQL com o professor (e registrar a confirmação).
2. Perguntar a versão de PostgreSQL do laboratório/ambiente de correção.
3. Perguntar o formato de entrega (relatório PDF? scripts? apresentação?). Os PDFs não dizem.
4. Perguntar se os objetos de demonstração podem criar schemas próprios (`bd2_meta`, `bd2_demo`) ou se devem ficar em `public`.
5. Perguntar quantas regras semânticas próprias se espera além de `Invoice.Total` (ver §6.4).

### 2.2 Decisões com default recomendado [PROPOSTA]

| # | Decisão | Default |
|---|---|---|
| D1 | Variante Chinook | **`Chinook_PostgreSql_SerialPKs.sql`** (ver §3.2) |
| D2 | Remoção de índices | Só independentes por padrão; PK/UNIQUE/EXCLUDE por *opt-in*; `CASCADE` por *opt-in* separado |
| D3 | Escopo do gerador DDL | Mínimo exigido; declarar limites; não alegar "clone completo" |
| D4 | DTE | Demo em `invoice.status` (extensão do grupo) **+** segunda tabela em `bd2_demo` (obrigatória) |
| D5 | Regra de trigger | R-TRG-01 (ciclo em `employee.reports_to`) e R-TRG-02 (`invoice.total`) |
| D6 | Regra de procedure | R-SP-01 `criar_fatura_com_itens(customer_id, itens jsonb)` |
| D7 | `Invoice.Total` | Row-level: trigger A + trigger C obrigatórios; B (lock) opcional (ver §7.3) |
| D8 | Papéis | `bd2_owner` (NOLOGIN, dono da procedure) e `bd2_app` (LOGIN, só `EXECUTE`) |

---

## 3. Ambiente e Chinook [VERIFICADO]

### 3.1 Fatos do script real (v1.4.5)

- Tabelas no schema **`public`**, em **minúsculas com sublinhado**: `album`, `artist`, `customer`, `employee`, `genre`, `invoice`, `invoice_line`, `media_type`, `playlist`, `playlist_track`, `track` (11 tabelas).
- Colunas em snake_case: `invoice_id`, `unit_price`, `reports_to`, `support_rep_id`…
- **Os esqueletos de v1/v2 usavam `"Invoice"`, `"InvoiceId"`, `"ReportsTo"` (CamelCase com aspas): isso não existe no script atual e nenhum deles executaria.** Toda a Parte 2 foi reescrita em snake_case no Apêndice A.
- Cada script faz `DROP DATABASE IF EXISTS` + `CREATE DATABASE` + `\c`: precisa ser executado com **`psql`** (não com clientes gráficos), e destrói um banco homônimo.
- Nomes de banco criados: `chinook` (canônica), `chinook_serial`, `chinook_auto_increment`.
- SHA-256 dos arquivos usados na verificação (registrar no README do projeto):
  - `Chinook_PostgreSql.sql` — `e3fde5c1…db695e`
  - `Chinook_PostgreSql_SerialPKs.sql` — `847361eb…c5ddaf1`
  - `Chinook_PostgreSql_AutoIncrementPKs.sql` — `a277ce8e…3696e`
- Dados originais: `invoice.total` já bate com Σ das linhas (0 divergências). Mesmo assim, **auditar antes de ativar os triggers** (§7.1).

### 3.2 Por que SerialPKs [VERIFICADO]

| Variante | PK | Consequência |
|---|---|---|
| `PostgreSql` (canônica) | `INT NOT NULL`, **sem default** | `INSERT INTO invoice(...)` sem `invoice_id` falha (`null value ... violates not-null`). A procedure R-SP-01 e vários testes precisariam gerar IDs manualmente (`max()+1` é corrida) |
| `SerialPKs` | `SERIAL` (`nextval`) | Funciona sem ID; sequence já sincronizada com o seed (confirmado: `last_value = max(invoice_id) = 412`) |
| `AutoIncrementPKs` | `GENERATED ALWAYS AS IDENTITY` | Inserir ID explícito falha sem `OVERRIDING SYSTEM VALUE`; ruim para testes que fixam IDs |

Consequência para o gerador DDL (§4.4): em SerialPKs as colunas têm `DEFAULT nextval(...)`. O escopo mínimo ignora defaults; o relatório deve dizer isso.

### 3.3 Cuidados de ambiente

- **Roles são do cluster, não do banco.** `CREATE ROLE bd2_app` sobrevive a `DROP DATABASE` e quebra a reexecução. Os scripts de roles devem ser idempotentes (`DO $$ ... IF NOT EXISTS ...`) e o harness deve limpar (`DROP OWNED BY`, `DROP ROLE IF EXISTS`).
- Registrar `SELECT version()` no README. Verificação feita em 16.15; confirmar com o professor a versão do laboratório (§2.1).
- Rotinas genéricas: schema como parâmetro, identificadores com `format('%I', ...)`, nunca concatenação.

### 3.4 Schemas

- `public`: Chinook.
- `bd2_meta`: motor DTE e rotinas genéricas.
- `bd2_demo`: tabelas de demonstração que não devem poluir o Chinook.
- Extensões acadêmicas (`invoice.status`, `bd2_demo.pedido_demo`) devem ser **identificadas como extensão do grupo** no relatório.

---

## 4. Parte 1 — Catálogos e DDL dinâmico

### 4.1 Listagem de índices (Q1)

**Catálogos:** `pg_index`, `pg_class` (índice e tabela), `pg_namespace`, `pg_attribute`, `pg_am`; funções `pg_get_indexdef`, `pg_get_expr`.

**Saída:** schema/tabela, índice, método de acesso, colunas-chave (em ordem), colunas `INCLUDE`, flags `unico`/`primario`/`exclusao`/`parcial`, definição.

**Pontos técnicos**
- `indnkeyatts` (colunas-chave) ≠ `indnatts` (inclui `INCLUDE`).
- `indkey` é `int2vector` e **começa em 0** (diferente de arrays SQL, que começam em 1) [NÃO VERIFICADO — documentação]. Posição com valor `0` = expressão, não coluna.
- Atalho robusto: `pg_get_indexdef(indexrelid, k, true)` devolve o texto da coluna/expressão na posição `k`, tratando expressões sem lógica extra.
- Incluir índices de PK/UNIQUE (o enunciado diz "todos"). Excluir schemas de sistema por padrão (`pg_catalog`, `information_schema`, `pg_toast`), com parâmetro para incluí-los.
- Índices de FK do Chinook (`invoice_customer_id_idx` etc.) são independentes e existem no seed [VERIFICADO].

**Aceite:** sem nomes de tabela fixos; compostos na ordem; PK/UNIQUE identificados; parcial/expressão/`INCLUDE` distinguíveis.

### 4.2 Remoção de índices (Q2)

**Contrato:** `bd2_meta.remover_indices_tabela(p_schema text, p_tabela text, p_incluir_constraints bool DEFAULT false, p_cascade bool DEFAULT false)`. Retorna resumo (objeto, tipo, ação, resultado).

**Armadilha central:** índice que sustenta PK/UNIQUE/EXCLUDE pertence a uma constraint; não se usa `DROP INDEX`, e sim `ALTER TABLE ... DROP CONSTRAINT`.

**BUG CORRIGIDO vs v2 [VERIFICADO]:** o `LEFT JOIN pg_constraint con ON con.conindid = i.indexrelid` do esqueleto de v2 também casa **constraints de FK**, pois `conindid` de uma FK aponta para o índice único referenciado. Em `employee`, o índice `employee_pkey` retornou 3 linhas: a PK, `customer_support_rep_id_fkey` (tabela `customer`) e `employee_reports_to_fkey`. O loop de v2 tentaria `DROP CONSTRAINT` de FKs de outras tabelas. Filtro correto:

```sql
LEFT JOIN pg_constraint con
       ON con.conindid = i.indexrelid
      AND con.conrelid = i.indrelid          -- constraint da própria tabela
      AND con.contype IN ('p','u','x')       -- nunca 'f'
```

**Fluxo:** validar tabela → classificar índices (independente / p / u / x) → `DROP INDEX` dos independentes → se `p_incluir_constraints`, `DROP CONSTRAINT` com `RESTRICT` (ou `CASCADE` só se `p_cascade`) → retornar resumo. Sem `COMMIT` interno (atomicidade da chamada).

**Para os testes (Chinook):** usar tabelas cuja PK **não** é referenciada, como `invoice_line` e `playlist_track` (a maioria das outras PKs é referenciada por FK e `RESTRICT` vai falhar, o que também é um teste válido: "falha limpa, nada alterado").

**Aceite:** funciona em ≥ 2 tabelas sem nomes fixos; nunca `DROP INDEX` em índice de constraint; nunca `CASCADE` sem parâmetro; informa o que removeu e o que preservou.

### 4.3 Listagem de chaves estrangeiras (Q3)

**Catálogos:** `pg_constraint` (`contype = 'f'`), `pg_class`, `pg_namespace`, `pg_attribute`.

**Pareamento por posição:** `conkey[i]` ↔ `confkey[i]`. Forma segura (PG ≥ 9.4):

```sql
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS u(attnum_local, attnum_ref, pos)
```

**Saída:** constraint, schema/tabela/coluna local, schema/tabela/coluna referenciada, posição, `confupdtype`, `confdeltype`, `confmatchtype`, `condeferrable`, `condeferred`, `convalidated`.

**Casos que o Chinook cobre:** autorreferência `employee.reports_to → employee.employee_id`; várias FKs apontando para a mesma PK (`employee_pkey` é referenciada por `customer.support_rep_id` e `employee.reports_to`) [VERIFICADO].

**Aceite:** origem/destino corretos; composta pareada na ordem (testar com tabela auxiliar, pois o Chinook só tem FKs simples); autorreferência presente; filtro por schema.

### 4.4 Gerador de `CREATE TABLE` (Q4)

**Contrato:** `bd2_meta.gerar_ddl_tabelas(p_schema_origem text, p_schema_destino text, p_incluir_fks bool DEFAULT true) RETURNS text`. **Retorna texto; não executa.**

**Mínimo exigido:** por coluna — nome, tipo (`format_type(atttypid, atttypmod)`), `NOT NULL`, ordem; por tabela — PK (simples/composta) e FKs (simples/compostas).

**Duas fases:** (A) todos os `CREATE TABLE` + PK; (B) `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY`. Evita ordenação topológica e lida com autorreferência.

**Ponto de projeto que v2 contradizia:** v2 mandava usar `pg_get_constraintdef` **e** "remapear schema nas FKs". Mas `pg_get_constraintdef` devolve `REFERENCES customer(customer_id)` sem schema (visto no `\d`), então clonar para outro schema exigiria reescrever texto — frágil. **Recomendação:** PK pode usar `pg_get_constraintdef`; **FK deve ser montada a partir dos arrays** (`conkey`/`confkey` + nomes de coluna) com `schema_destino` explícito, preservando `ON UPDATE/DELETE`, `MATCH`, `DEFERRABLE` se no escopo.

**Limites a declarar:** defaults/`nextval`/sequences, `IDENTITY`, `UNIQUE`, `CHECK`, índices, comentários, tabelas particionadas, estrangeiras, herança. Considerar apenas `relkind = 'r'`; avisar sobre o resto.

**Teste:** gerar → executar em `chinook_clone` → comparar por catálogo contagens de tabelas, colunas, PKs, FKs (esperado no Chinook: 11 tabelas) → inserts que violem PK/FK devem falhar. **Critério central:** adicionar tabela ao schema de origem não exige alterar o gerador (testar criando uma tabela nova antes de gerar).

---

## 5. Parte 1 — Motor genérico de máquina de estados (Q5)

### 5.1 Princípio

Estados e transições são **dados**. Proibido: `IF tabela = 'invoice'` ou `IF estado = 'PENDENTE'` dentro da função genérica.

### 5.2 Modelo (`bd2_meta`)

- `state_machine(machine_id PK, machine_name UNIQUE, description, insert_policy CHECK IN ('INITIAL_ONLY','ANY_VALID_STATE'), active)`
- `state_definition(machine_id, state_code, description, is_initial, is_terminal, active, PK(machine_id, state_code))`; índice único parcial `ON (machine_id) WHERE is_initial` (no máximo 1 inicial).
- `state_transition(machine_id, from_state, to_state, description, PK(machine_id, from_state, to_state))`, FKs compostas para `state_definition`. Impedir aresta saindo de estado terminal (trigger de validação ou check na procedure de cadastro).
- `state_binding(binding_id, schema_name, table_name, column_name, machine_id, active)`.

**BUG CORRIGIDO vs v2 [VERIFICADO]:** v2 definia `UNIQUE(schema_name, table_name, column_name)` **e** fazia `UPDATE ... SET active=false` seguido de `INSERT` novo na `registrar_binding`. Na segunda chamada para a mesma coluna, o `INSERT` viola o UNIQUE (reproduzido: `duplicate key value violates unique constraint`). Opções:
- (preferida) manter o UNIQUE e registrar com `INSERT ... ON CONFLICT (schema_name, table_name, column_name) DO UPDATE SET machine_id = EXCLUDED.machine_id, active = true`;
- ou trocar o UNIQUE por índice único parcial `WHERE active`.

### 5.3 Execução

1. **Função de trigger genérica** `bd2_meta.fn_validar_transicao_estado()`; recebe a coluna em `TG_ARGV[0]`; identifica a tabela por `TG_TABLE_SCHEMA`/`TG_TABLE_NAME`; lê o valor por `to_jsonb(NEW) ->> coluna`.
2. **Procedure** `bd2_meta.registrar_binding(schema, tabela, coluna, machine_id)`: valida existência (via catálogo), faz upsert do binding, (re)instala o trigger com nome determinístico (`'trg_fsm_' || substr(md5(schema||'.'||tabela||'.'||coluna), 1, 24)`, respeita o limite de 63 caracteres), `BEFORE INSERT OR UPDATE OF <coluna>`.
3. **Procedure** `bd2_meta.remover_binding(...)`: remove trigger e desativa binding (evita trigger órfão). *(v2 perdeu isto de v1.)*
4. Fail-closed: sem binding ativo → `RAISE EXCEPTION`.

O PostgreSQL não tem trigger DML global; a **função** é genérica, a **instalação** é por tabela. Trigger chama função que `RETURNS trigger`; procedure é outro objeto (`CALL`).

### 5.4 Regras de validação

**INSERT:** valor não nulo; existe e está ativo na máquina; se `INITIAL_ONLY`, precisa ser inicial.
**UPDATE:** se `IS NOT DISTINCT FROM` → aceita (outras colunas mudaram); senão: novo não nulo, ambos ativos, antigo **não** terminal, existe aresta `(antigo → novo)`.
**DELETE:** fora do motor.

Limitação v1: coluna `text`/`varchar`. [NÃO VERIFICADO] A função de v2 §5.6 (esqueleto) não foi executada nesta rodada; o agente deve testá-la integralmente.

### 5.5 Demo (extensão do grupo)

- `ALTER TABLE public.invoice ADD COLUMN status text NOT NULL DEFAULT 'PENDENTE';`
- Máquina `INVOICE_STATE`: `PENDENTE` (inicial), `PAGO` e `CANCELADO` (terminais); transições `PENDENTE→PAGO`, `PENDENTE→CANCELADO`.
- **Segunda tabela obrigatória** `bd2_demo.pedido_demo(id, situacao text)` com máquina `NOVO → EM_ANDAMENTO → CONCLUIDO`, nome de coluna **diferente**, reutilizando a mesma função sem alterá-la (prova de generalidade).

| Operação | Esperado |
|---|---|
| Inserir com estado inicial | Aceitar |
| Inserir com estado terminal (`INITIAL_ONLY`) | Rejeitar |
| `PENDENTE→PAGO`, `PENDENTE→CANCELADO` | Aceitar |
| `PAGO→PENDENTE`, `CANCELADO→PAGO` | Rejeitar |
| Atualizar coluna não-estado | Aceitar |
| Estado inexistente | Rejeitar |
| Binding inativo + INSERT | Rejeitar (fail-closed) |
| Re-registrar binding da mesma coluna | Aceitar (regressão do bug acima) |
| Segunda tabela/outra máquina | Funciona sem mudar a função |

**Efeito colateral:** a coluna `status` entra no `invoice`; qualquer teste do gerador DDL feito depois a incluirá (esperado), e o `INSERT` de R-SP-01 usa o `DEFAULT 'PENDENTE'`.

### 5.6 Segurança

`SECURITY INVOKER` basta se `bd2_meta.state_*` for legível. Se usar `DEFINER`: `SET search_path = pg_catalog, bd2_meta`, objetos qualificados, dono não-superusuário, `REVOKE ... FROM PUBLIC`. Revogar escrita em `bd2_meta.state_*` de não-administradores.

---

## 6. Parte 2 — Regras semânticas

### 6.1 Critérios de escolha

Regra não expressável por PK/FK/NOT NULL/UNIQUE/CHECK local; relevante ao Chinook; evento de violação identificável; teste positivo e negativo; justificativa do mecanismo.

### 6.2 R-TRG-01 (trigger) — hierarquia de `employee` sem ciclos [VERIFICADO]

**Texto:** `employee.reports_to` deve formar hierarquia acíclica; ninguém pode ser, direta ou indiretamente, seu próprio superior.
**Por que é semântica:** a FK garante que o superior existe; não impede A→B→C→A.
**Mecanismo:** `BEFORE INSERT OR UPDATE OF reports_to` + CTE recursiva com caminho visitado + `pg_advisory_xact_lock` para serializar alterações de hierarquia.
**Verificado em PG 16:** ciclo (1←2←3, tentar 1→3) rejeitado; auto-referência rejeitada; atualização válida aceita (código no Apêndice A.2).
**Nuance de concorrência:** o lock avança para o próximo *statement* PL/pgSQL, que em `READ COMMITTED` ganha novo snapshot e enxerga o commit da outra transação. Em `REPEATABLE READ`/`SERIALIZABLE` o snapshot é fixo; documentar. A corrida entre duas sessões **não foi testada**; fazer teste de duas sessões.

### 6.3 R-SP-01 (procedure) — fatura nasce com ≥ 1 item [VERIFICADO]

**Texto:** toda fatura criada pelo sistema operacional deve ter ao menos uma `invoice_line` ao fim da operação.
**Por que é semântica:** "pelo menos um filho" não é expressável por FK/NOT NULL.
**Mecanismo:** `criar_fatura_com_itens(p_customer_id int, p_itens jsonb)`, `SECURITY DEFINER`, `SET search_path = pg_catalog, public`, sem `COMMIT` interno. Detalhes de permissão em §8; código em A.3.

**Dependência:** a procedure insere `total = 0` e confia na regra R-TRG-02 para totalizar. Sem os triggers de §7, a fatura sai com `total = 0.00` e linhas somando 2,97 (observado). Portanto **R-SP-01 só está correta com R-TRG-02 instalada**, e o teste deve ser executado com ambos.

### 6.4 Regras adicionais (opcional) [PENDENTE]

O enunciado pede "regras" (plural) na Q1 e a Q4 é uma regra à parte; R-TRG-01 + R-SP-01 + R-TRG-02 somam três. Se o professor esperar mais, candidatas baratas: (a) `customer.support_rep_id` deve apontar a empregado com `title` de suporte de vendas — **[NÃO VERIFICADO]** contra os dados; (b) `invoice_line.unit_price` coerente com `track.unit_price` no momento da venda — avaliar impacto no seed. Não implementar antes da resposta do professor; duas regras bem testadas valem mais que cinco rasas.

### 6.5 Matriz de rastreabilidade

| ID | Regra | Tabelas | Mecanismo | Evento | Testes |
|---|---|---|---|---|---|
| R-TRG-01 | Hierarquia sem ciclos | `employee.reports_to` | Trigger + advisory lock | INSERT/UPDATE | ciclo, auto-ref, válido, 2 sessões |
| R-SP-01 | Fatura nasce com ≥ 1 item | `invoice`, `invoice_line` | Procedure + roles | CALL | vazio, cliente/faixa inexistente, DML direto negado, válido |
| R-TRG-02 | `total = Σ` itens | `invoice.total`, `invoice_line` | Triggers | INSERT/UPDATE/DELETE | T1–T11 (§7.4) |

---

## 7. Parte 2 — `Invoice.Total`

### 7.1 Regra e pré-requisito

`invoice.total = COALESCE(SUM(invoice_line.unit_price * invoice_line.quantity), 0)` por `invoice_id`.

Pré-requisito: consulta de auditoria antes de ativar os triggers. No Chinook 1.4.5, resultado = 0 divergências [VERIFICADO]. Se houver divergência, decidir entre corrigir os dados (um `UPDATE` único) ou rejeitar a ativação.

### 7.2 Eventos a cobrir

INSERT/DELETE de linha; UPDATE de `unit_price`/`quantity`; mudança de `invoice_id` (recalcular origem **e** destino); INSERT de cabeçalho; UPDATE manual de `total`; fatura sem linhas (`0`).

### 7.3 Arquitetura [VERIFICADO — T1..T9]

- **Trigger A** `BEFORE INSERT OR UPDATE OF total ON invoice`: sobrescreve `NEW.total` com o valor calculado. Não executa UPDATE (sem recursão).
- **Trigger C** `AFTER INSERT OR UPDATE OR DELETE ON invoice_line`: recalcula cada fatura afetada (nova e antiga se mudou).
- **Trigger B (opcional/hardening)** `BEFORE ... ON invoice_line`: `SELECT ... FOR UPDATE` na(s) fatura(s), em ordem de `invoice_id`.

**Reavaliação do lock B (revisão de v1/v2).** v1/v2 apresentavam B como necessário para evitar deadlock e total obsoleto. Nesta rodada, com a versão enxuta (A + C, onde o recálculo é um `UPDATE ... SET total = (subselect)` que já toma o lock de linha), **não consegui reproduzir** nenhum deadlock nem total divergente: 6 pares de sessões com `pg_sleep` dentro da transação e 3 rodadas de 60 `INSERT`s simultâneos na mesma fatura terminaram com `total = soma` tanto **com** quanto **sem** B. O deadlock descrito em v2 vale para o desenho em que o AFTER faz um `SELECT ... FOR UPDATE` explícito (upgrade de `KEY SHARE`), que não é o desenho recomendado aqui.

Recomendação: implementar A + C; incluir B apenas se o grupo conseguir demonstrar um cenário que o justifique, ou como camada defensiva documentada. Se incluir, manter a ordem determinística e testar UPDATE que troca `invoice_id`. Em `REPEATABLE READ`/`SERIALIZABLE` pode haver erro de serialização; o cliente deve repetir.

**Retorno de trigger de DELETE:** `RETURN COALESCE(NEW, OLD)` funcionou em PG 16 [VERIFICADO]; para portabilidade a versões antigas e clareza, preferir `IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW;`.

### 7.4 Matriz de testes

| ID | Ação | Esperado |
|---|---|---|
| T1 | Fatura sem linhas | `total = 0` |
| T2 | 1 linha | preço × qtd |
| T3 | 2 linhas | soma |
| T4 / T5 | UPDATE `quantity` / `unit_price` | recalculado |
| T6 | DELETE linha | diminui |
| T7 | DELETE última linha | `0` |
| T8 | Mover linha entre faturas | **ambas** recalculadas |
| T9 | UPDATE direto em `total` | corrigido pelo trigger A |
| T10 | Inserção em lote (`INSERT ... SELECT`) | total final correto |
| T11 | N sessões inserindo na mesma fatura | `total = Σ`, sem erro (script de concorrência, §9.2) |
| T12 | `INSERT ... ON CONFLICT DO UPDATE` em linha | total correto [NÃO VERIFICADO] |

T1–T9 passaram [VERIFICADO]; T10, T12 não foram executados.

### 7.5 Limites a documentar

`TRUNCATE invoice_line` não dispara trigger de linha (negar o privilégio a `bd2_app` ou criar trigger de statement); `ALTER TABLE ... DISABLE TRIGGER` e `session_replication_role = replica` contornam; superusuário/dono contornam. `numeric(10,2)` (nunca ponto flutuante).

---

## 8. Permissões (R-SP-01)

**Objetivo [EXIGÊNCIA]:** usuário que só manipule os dados envolvidos **através** da procedure.

| Papel | Atributos | Privilégios |
|---|---|---|
| `bd2_owner` | `NOLOGIN`, não superusuário, **dono da procedure** | `SELECT` em `customer`, `track`; `INSERT` **e `SELECT`** em `invoice`, `invoice_line`; `UPDATE` em `invoice` (trigger C); `USAGE` nas sequences usadas pelos defaults |
| `bd2_app` | `LOGIN`, não dono de tabelas, não membro de papel que devolva DML | `EXECUTE` só na procedure; **sem** DML em `invoice`/`invoice_line` |

**ACHADO [VERIFICADO]:** a procedure falhou com `permission denied for table invoice` quando `bd2_owner` tinha só `INSERT`: o `INSERT ... RETURNING invoice_id` exige `SELECT`. Após conceder `SELECT`, o `CALL` passou. v1/v2 diziam apenas "privilégios mínimos".

Outros passos:
- `ALTER PROCEDURE ... OWNER TO bd2_owner` (ou criá-la já como `bd2_owner`), senão `SECURITY DEFINER` roda como o criador (provavelmente superusuário).
- `REVOKE ALL ON PROCEDURE ... FROM PUBLIC` antes do `GRANT EXECUTE` ao `bd2_app`.
- Testes com `SET ROLE bd2_app` (ou conexão própria): `INSERT` direto → `permission denied` **[VERIFICADO]**; `SELECT` direto em `invoice` → negado **[VERIFICADO]** (decidir se `bd2_app` precisa de leitura; se sim, conceder `SELECT` explicitamente); `CALL` com `[]` → `R-SP-01`; `CALL` válido → fatura com itens.
- Limite: superusuário e `bd2_owner` ainda contornam (declarar no relatório).

---

## 9. Testes e harness

### 9.1 Princípios

- Casos positivos **e** negativos por regra; sem IDs fixos do seed (usar `RETURNING`/seleção controlada; IDs de teste em faixa alta como `9xxxxx` e limpeza no fim).
- Testes SQL em blocos `DO $$ ... ASSERT ... $$`; erro esperado capturado com `EXCEPTION WHEN ...`.
- Executar com `psql -v ON_ERROR_STOP=1`; exit code ≠ 0 em falha.
- `ASSERT` depende de `plpgsql.check_asserts` (default `on`).

### 9.2 Concorrência

SQL puro em um único `DO` não prova concorrência. Usar script shell que dispara várias sessões `psql` em segundo plano (padrão verificado: 60 `INSERT`s paralelos na mesma fatura, depois comparar `total` com a soma) ou `pgbench -f`. Para R-TRG-01, duas sessões com `BEGIN; UPDATE ...; pg_sleep(...)` cruzadas (A→B e B→A).

### 9.3 Reexecução limpa

`run_all.sh`: recria banco → carrega Chinook fixado → aplica scripts em ordem → roda testes → imprime resumo. Limpar roles (§3.3). Registrar saída em `evidencias/`.

---

## 10. Estrutura do repositório

```text
bd2-trabalho/
├── README.md                      # versão PG, variante+hash do Chinook, ordem, resultado esperado
├── AGENTS.md                      # brief curto para o agente (§13), lido automaticamente por ferramentas
├── run_all.sh
├── docs/
│   ├── regras-semanticas.md       # texto das regras (exigência 2.1)
│   ├── arquitetura.md
│   ├── decisoes.md                # decisões D1..D8 e respostas do professor
│   └── roteiro-demonstracao.md
├── sql/
│   ├── 00_ambiente/00_verificar_ambiente.sql
│   ├── 01_catalogos/{01_listar_indices,02_listar_foreign_keys}.sql
│   ├── 02_administracao/01_remover_indices.sql
│   ├── 03_ddl_dinamico/01_gerar_create_table.sql
│   ├── 04_maquina_estados/{01_tabelas_configuracao,02_funcao_validacao,03_procedures_registro,04_demo}.sql
│   ├── 05_regras_semanticas/
│   │   ├── 00_roles_e_permissoes.sql      # antes das procedures
│   │   ├── 01_trigger_hierarquia_employee.sql
│   │   ├── 02_integridade_invoice_total.sql   # antes da procedure (dependência §6.3)
│   │   └── 03_procedure_criar_fatura.sql
│   └── 06_testes/…                # um arquivo por módulo + 06_concorrencia.sh
└── evidencias/
```

*(v2 posicionava `invoice_total` depois da procedure; a dependência real exige a ordem acima.)*

---

## 11. Ordem de implementação

1. Fechar pendências com o professor (§2.1) e registrar.
2. Ambiente: Chinook SerialPKs, versão, hash, `run_all.sh` mínimo.
3. Q1 e Q3 (catálogos) → Q2 → Q4.
4. Tabelas de configuração DTE → função → procedures de registro → demo + segunda tabela.
5. Roles → R-TRG-01 → **R-TRG-02 (`invoice.total`)** → R-SP-01.
6. Testes de concorrência.
7. Reexecução limpa completa; relatório requisito → arquivo → teste → evidência.

Fazer primeiro: **D1 (variante), D4 (demo DTE), D3 (escopo DDL)**, pois afetam todos os demais módulos.

---

## 12. Riscos prioritários

| Risco | Mitigação |
|---|---|
| Código copiado dos esqueletos antigos com nomes CamelCase | Usar só snake_case; inspecionar o banco real antes de codar |
| Join `conindid` sem filtro de `contype`/`conrelid` | Filtro de §4.2 + teste em `employee` |
| `registrar_binding` quebrando na 2ª chamada | Upsert (§5.2) + teste de regressão |
| INSERT sem ID na variante canônica | Usar SerialPKs |
| `RETURNING` sem `SELECT` para `bd2_owner` | Grants de §8 |
| Procedure dependente de R-TRG-02 | Ordem de instalação + teste conjunto |
| Roles persistem entre bancos | Setup idempotente + limpeza |
| FK do clone aponta para schema errado | Montar FK a partir de arrays (§4.4) |
| `CASCADE`/`DROP CONSTRAINT` destrutivo | `RESTRICT` por padrão; opt-in explícito |
| `TRUNCATE`/`DISABLE TRIGGER` ignoram triggers | Privilégio negado a `bd2_app`; documentar |
| Concorrência afirmada sem teste | Script de §9.2 |

---

## 13. Brief para o agente de implementação

Salvar como `AGENTS.md` (ou colar como primeiro prompt). Antes de usar no Antigravity, confirmar qual arquivo de instruções ele lê; no Claude Code, o equivalente é `CLAUDE.md`.

> Projeto acadêmico de Banco de Dados II em PostgreSQL. Leia `docs/` e os PDFs do professor. **Antes de gerar código, inspecione o banco real** (`\dt`, `\d <tabela>`, catálogos) e apresente um plano de arquivos e dependências.
>
> Fatos já verificados (reconfirme no ambiente): Chinook 1.4.5, schema `public`, nomes **snake_case minúsculos** (`invoice_line`, `invoice_id`…), usar variante `SerialPKs`; scripts do Chinook se executam com `psql` e recriam o banco; roles são do cluster.
>
> Regras:
> 1. Sem listas fixas de tabelas/índices/colunas nos módulos de catálogo e DDL.
> 2. SQL dinâmico com `format('%I', ...)` e objetos qualificados por schema.
> 3. Índice comum ≠ índice de constraint (`conindid` filtrado por `conrelid` e `contype IN ('p','u','x')`). Sem `CASCADE` implícito.
> 4. DDL em duas fases; FKs montadas a partir de `conkey`/`confkey`; **retornar texto, não executar**.
> 5. DTE: tabelas de configuração + função de trigger genérica + procedure de registro idempotente (upsert) + remoção de binding. Fail-closed. Segunda tabela de demo com outro nome de coluna.
> 6. Parte 2: R-TRG-01 (ciclo), R-TRG-02 (`invoice.total`: triggers A + C; B só se justificado), R-SP-01 (procedure `SECURITY DEFINER`, `search_path` fixo, dono `bd2_owner` com `SELECT`+`INSERT`, `bd2_app` só com `EXECUTE`).
> 7. Instalar R-TRG-02 **antes** de R-SP-01 e testar os dois juntos.
> 8. Testes positivos e negativos, sem IDs fixos do seed, com `ON_ERROR_STOP=1`. Concorrência com sessões `psql` paralelas.
> 9. Não afirme suporte ao que não implementou. Extensões do grupo (`invoice.status`, `bd2_demo.*`) são marcadas como tal.
> 10. Trate os trechos do Apêndice A como referência: execute-os, refatore se quiser, e **não os considere corretos sem teste**.
>
> Ao finalizar: execute em banco descartável recém-criado e reporte arquivos, ordem, testes executados/falhos, limitações e pendências. Não substitua execução real por exemplos escritos.

---

## 14. Registro de verificação e changelog

### 14.1 Ambiente da verificação

PostgreSQL 16.15 (Ubuntu 24.04), Chinook 1.4.5 (três variantes). O que **não** foi testado: PG ≠ 16; função DTE completa; teste de concorrência do lock de `employee`; T10 e T12; geração e execução do DDL clone; remoção de índices; consultas de catálogo completas.

### 14.2 Resultados

| Item | Resultado |
|---|---|
| Schema e nomes reais | `public`, snake_case; esqueletos CamelCase de v1/v2 **não executam** |
| Join `conindid` (v2 §3.2) | **Bug:** casa FKs; 3 linhas para `employee_pkey` |
| `registrar_binding` 2× (v2 §5.7) | **Bug:** viola UNIQUE |
| INSERT sem ID (variante canônica) | **Falha** (`not-null`); SerialPKs resolve |
| Procedure/roles (v2 §6.3) | Falha por falta de `SELECT` ao `bd2_owner`; após correção, OK |
| DML/SELECT direto por `bd2_app` | Negado |
| R-TRG-01 | Ciclo e auto-ref rejeitados; válido aceito |
| R-TRG-02 T1–T9 | Passaram |
| Concorrência `invoice.total` | Sem divergência/deadlock, **com e sem** lock B (nenhuma falha reproduzida) |
| `RETURN COALESCE(NEW,OLD)` em DELETE | Funciona em PG 16 (não era bug) |
| Auditoria dos totais do seed | 0 divergências |

### 14.3 Integridade dos arquivos de entrada

`planejamento_bd2.md` (v2) está **completo** e com blocos de código balanceados (26 delimitadores); não houve truncamento. Em relação a v1, v2 perdeu e este v3 restaura: exclusão de schemas de sistema por padrão na listagem de índices; exigência de que o papel operacional não seja membro de outro papel que devolva DML; operação de remoção/desativação de binding e trigger órfão; lista de objetos fora de escopo do gerador; regra "não inventar colunas/políticas do Chinook"; e a observação sobre o que "todos os índices" significa. v2 acrescentou e v3 mantém: esqueletos (corrigidos), análise de concorrência (recalibrada), troubleshooting (incorporado aos riscos) e harness de testes.

### 14.4 Mudanças principais v2 → v3

nomes snake_case; variante SerialPKs; pendências com o professor; correção de `conindid`; correção de `registrar_binding`; FK do DDL a partir de arrays; grants do `bd2_owner`; dependência R-SP-01 → R-TRG-02 e reordenação; lock B rebaixado a opcional; roles idempotentes; marcação [VERIFICADO]/[NÃO VERIFICADO]; `AGENTS.md`.

---

## 15. Referências

- Chinook: https://github.com/lerocha/chinook-database
- PostgreSQL: catálogos (`pg_index`, `pg_constraint`, `pg_class`), PL/pgSQL, triggers, `CREATE TRIGGER`, `CREATE PROCEDURE`, `CREATE FUNCTION` (SECURITY DEFINER), `DROP INDEX`, advisory locks — https://www.postgresql.org/docs/current/
- Enunciados: `Especificacao_Trabalho_-_Parte_1.pdf`, `Especificacao_Trabalho_-_Parte_2.pdf`.

---

# Apêndice A — Referências verificadas (snake_case, PG 16 + SerialPKs)

> Executados nesta rodada. Servem de ponto de partida; o agente deve refatorar, comentar e testar.

## A.1 `invoice.total` (triggers A e C; B opcional)

```sql
-- A) proteção do valor armazenado
CREATE OR REPLACE FUNCTION public.fn_invoice_total_before() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.total := COALESCE((SELECT SUM(unit_price * quantity)
                           FROM public.invoice_line
                          WHERE invoice_id = NEW.invoice_id), 0);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_invoice_total_before
  BEFORE INSERT OR UPDATE OF total ON public.invoice
  FOR EACH ROW EXECUTE FUNCTION public.fn_invoice_total_before();

-- C) recálculo após mudança nas linhas (nova e antiga fatura)
CREATE OR REPLACE FUNCTION public.fn_invoiceline_recalc() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v int;
BEGIN
  FOR v IN
    SELECT DISTINCT x FROM unnest(ARRAY[
      CASE WHEN TG_OP <> 'DELETE' THEN NEW.invoice_id END,
      CASE WHEN TG_OP <> 'INSERT' THEN OLD.invoice_id END]) AS x
     WHERE x IS NOT NULL
  LOOP
    UPDATE public.invoice i
       SET total = COALESCE((SELECT SUM(unit_price * quantity)
                               FROM public.invoice_line
                              WHERE invoice_id = i.invoice_id), 0)
     WHERE i.invoice_id = v;
  END LOOP;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_invoiceline_recalc
  AFTER INSERT OR UPDATE OR DELETE ON public.invoice_line
  FOR EACH ROW EXECUTE FUNCTION public.fn_invoiceline_recalc();

-- B) opcional: lock da fatura em ordem determinística
CREATE OR REPLACE FUNCTION public.fn_invoiceline_lock() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM 1 FROM public.invoice WHERE invoice_id = NEW.invoice_id FOR UPDATE;
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM 1 FROM public.invoice WHERE invoice_id = OLD.invoice_id FOR UPDATE;
  ELSE
    PERFORM 1 FROM public.invoice WHERE invoice_id IN (OLD.invoice_id, NEW.invoice_id)
     ORDER BY invoice_id FOR UPDATE;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
```

## A.2 R-TRG-01 — ciclo em `employee`

```sql
CREATE OR REPLACE FUNCTION public.fn_employee_sem_ciclo() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_ciclo boolean;
BEGIN
  IF NEW.reports_to IS NULL THEN RETURN NEW; END IF;
  IF NEW.reports_to = NEW.employee_id THEN
    RAISE EXCEPTION 'R-TRG-01: funcionário não pode ser superior de si mesmo';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('R-TRG-01:employee.hierarchy'));
  WITH RECURSIVE cadeia AS (
    SELECT e.employee_id, e.reports_to, ARRAY[e.employee_id] AS caminho
      FROM public.employee e WHERE e.employee_id = NEW.reports_to
    UNION ALL
    SELECT e.employee_id, e.reports_to, c.caminho || e.employee_id
      FROM public.employee e JOIN cadeia c ON e.employee_id = c.reports_to
     WHERE e.employee_id <> ALL (c.caminho))
  SELECT EXISTS (SELECT 1 FROM cadeia WHERE employee_id = NEW.employee_id) INTO v_ciclo;
  IF v_ciclo THEN RAISE EXCEPTION 'R-TRG-01: a alteração criaria um ciclo na hierarquia'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_employee_sem_ciclo
  BEFORE INSERT OR UPDATE OF reports_to ON public.employee
  FOR EACH ROW EXECUTE FUNCTION public.fn_employee_sem_ciclo();
```

## A.3 R-SP-01 + papéis

```sql
-- roles (tornar idempotente no script real)
CREATE ROLE bd2_owner NOLOGIN;
CREATE ROLE bd2_app LOGIN PASSWORD '...';   -- definir senha de teste fora do versionamento

GRANT SELECT          ON public.customer, public.track                TO bd2_owner;
GRANT SELECT, INSERT  ON public.invoice, public.invoice_line          TO bd2_owner;
GRANT UPDATE          ON public.invoice                               TO bd2_owner;  -- trigger C
GRANT USAGE ON SEQUENCE public.invoice_invoice_id_seq,
                        public.invoice_line_invoice_line_id_seq       TO bd2_owner;

CREATE OR REPLACE PROCEDURE public.criar_fatura_com_itens(p_customer_id int, p_itens jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_id int; v_item jsonb;
BEGIN
  IF p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' OR jsonb_array_length(p_itens) = 0 THEN
    RAISE EXCEPTION 'R-SP-01: informe ao menos 1 item';
  END IF;
  INSERT INTO public.invoice(customer_id, invoice_date, billing_address, billing_city, billing_country, total)
    SELECT customer_id, now(), address, city, country, 0
      FROM public.customer WHERE customer_id = p_customer_id
    RETURNING invoice_id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'cliente % inexistente', p_customer_id; END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_itens) LOOP
    IF (v_item->>'quantity')::int <= 0 THEN RAISE EXCEPTION 'quantidade inválida: %', v_item; END IF;
    INSERT INTO public.invoice_line(invoice_id, track_id, unit_price, quantity)
      SELECT v_id, t.track_id, t.unit_price, (v_item->>'quantity')::int
        FROM public.track t WHERE t.track_id = (v_item->>'track_id')::int;
    IF NOT FOUND THEN RAISE EXCEPTION 'track inexistente: %', v_item->>'track_id'; END IF;
  END LOOP;
END $$;

ALTER  PROCEDURE public.criar_fatura_com_itens(int, jsonb) OWNER TO bd2_owner;
REVOKE ALL     ON PROCEDURE public.criar_fatura_com_itens(int, jsonb) FROM PUBLIC;
GRANT EXECUTE  ON PROCEDURE public.criar_fatura_com_itens(int, jsonb) TO bd2_app;
```

*(Nota: a validação `quantity <= 0` foi acrescentada em relação ao que foi executado e deve ser coberta por teste.)*

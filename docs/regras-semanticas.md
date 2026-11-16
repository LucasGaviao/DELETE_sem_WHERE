# Regras Semânticas — Parte 2 (`regras-semanticas.md`)

Este documento atende à **Questão 1 da Parte 2**, descrevendo textualmente as regras semânticas definidas sobre o esquema Chinook, por que elas não podem ser garantidas apenas pela estrutura declarativa do modelo relacional, e como foram implementadas.

---

## Resumo e Rastreabilidade

| Código | Nome da Regra | Tabelas Envolvidas | Mecanismo | Script SQL |
|---|---|---|---|---|
| **R-TRG-01** | Hierarquia Acíclica de Funcionários | `public.employee` (`employee_id`, `reports_to`) | Trigger `BEFORE INSERT OR UPDATE` + CTE Recursiva + Advisory Lock | `sql/05_regras_semanticas/01_trigger_hierarquia_employee.sql` |
| **R-TRG-02** | Integridade do Total da Fatura (Questão 4) | `public.invoice` (`total`), `public.invoice_line` (`unit_price`, `quantity`) | Triggers `BEFORE` em `invoice` (A) e `AFTER` em `invoice_line` (C) | `sql/05_regras_semanticas/02_integridade_invoice_total.sql` |
| **R-SP-01** | Criação Atômica de Fatura com Itens Obrigatórios | `public.invoice`, `public.invoice_line`, `public.customer`, `public.track` | Stored Procedure (`SECURITY DEFINER`) + Controle de Permissões (`bd2_owner` / `bd2_app`) | `sql/05_regras_semanticas/03_procedure_criar_fatura.sql` |

---

## 1. `R-TRG-01` — Hierarquia Acíclica de Funcionários (`employee.reports_to`)

### Descrição Textual da Regra
Na tabela `employee`, o relacionamento de subordinação representado pela coluna `reports_to` (que referencia `employee_id` da própria tabela) deve formar uma **árvore/floresta direcionada acíclica (DAG)**. Nenhum funcionário pode ser, direta ou indiretamente, subordinado a si mesmo (por exemplo: `A -> B -> C -> A`).

### Por que o Modelo Relacional Estrutural não garante
- A chave estrangeira (`employee_reports_to_fkey`) garante apenas que o `reports_to` informado existe como `employee_id`.
- Uma restrição `CHECK (reports_to <> employee_id)` impediria apenas a autorreferência direta de comprimento 1 (`A -> A`), mas é incapaz de consultar outras linhas da tabela para detectar ciclos indiretos (`A -> B -> A` ou `A -> B -> C -> A`).

### Mecanismo de Implementação
- Trigger `BEFORE INSERT OR UPDATE OF reports_to ON public.employee FOR EACH ROW`.
- Serialização via `pg_advisory_xact_lock` para evitar que duas transações simultâneas fechem um ciclo concorrentemente.
- Busca em profundidade/largura com `WITH RECURSIVE` subindo a cadeia de `reports_to` a partir de `NEW.reports_to` e verificando se `NEW.employee_id` aparece no caminho.

---

## 2. `R-TRG-02` — Consistência Redundante de `Invoice.Total` (Questão 4)

### Descrição Textual da Regra
Para toda fatura em `public.invoice`, o valor da coluna `total` deve ser sempre igual à soma de `unit_price * quantity` de todos os registros de `public.invoice_line` associados ao seu `invoice_id`, ou `0.00` caso a fatura não possua itens:
$$\text{invoice.total} = \text{COALESCE}\left(\sum (\text{invoice\_line.unit\_price} \times \text{invoice\_line.quantity}),\, 0.00\right)$$

### Por que o Modelo Relacional Estrutural não garante
- Restrições `CHECK` e colunas geradas (`GENERATED ALWAYS AS`) no PostgreSQL não podem referenciar outras tabelas nem executar funções de agregação (`SUM`) sobre uma tabela filha (`invoice_line`).

### Mecanismo de Implementação
Combinação de dois triggers:
1. **Trigger A (`trg_invoice_total_before`):** `BEFORE INSERT OR UPDATE OF total ON public.invoice FOR EACH ROW` — calcula e sobrescreve `NEW.total` a partir das linhas existentes em `invoice_line`, impedindo adulteração manual do cabeçalho.
2. **Trigger C (`trg_invoiceline_recalc`):** `AFTER INSERT OR UPDATE OR DELETE ON public.invoice_line FOR EACH ROW` — recalcula `invoice.total` para o `NEW.invoice_id` e/ou `OLD.invoice_id` (cobrindo inclusive transferência de item entre duas faturas).

---

## 3. `R-SP-01` — Fatura Deve Nascer com Pelo Menos Um Item Válido

### Descrição Textual da Regra
Toda fatura criada pelo usuário operacional da aplicação (`bd2_app`) deve obrigatoriamente conter **pelo menos um item de fatura (`invoice_line`)** com quantidade estritamente positiva (`quantity > 0`) e faixa (`track_id`) válida já no ato de sua criação, tomando o preço unitário oficial (`track.unit_price`) vigente no cadastro.

### Por que o Modelo Relacional Estrutural não garante
- Chaves estrangeiras no modelo relacional são definidas do lado N (`invoice_line`) apontando para o lado 1 (`invoice`). Isso impede que um item exista sem fatura, mas **não impede que uma fatura seja inserida sem itens** (cardinalidade mínima 1 no lado N).

### Mecanismo de Implementação (Stored Procedure + Permissões)
- **Stored Procedure:** `public.criar_fatura_com_itens(p_customer_id int, p_itens jsonb)` criada com `SECURITY DEFINER` e `SET search_path = pg_catalog, public`, pertencente ao papel `bd2_owner` (`NOLOGIN`).
- **Validações na Procedure:** verifica que `p_itens` é um array JSON não vazio, que o cliente existe, que cada item tem `quantity > 0` e `track_id` existente, insere o cabeçalho em `invoice` e os itens em `invoice_line` na mesma transação (acionando automaticamente o cálculo de `total` via `R-TRG-02`).
- **Isolamento por Permissões:** o usuário `bd2_app` (`LOGIN`) **não possui** privilégios de `INSERT`, `UPDATE`, `DELETE` ou `TRUNCATE` em `public.invoice` nem em `public.invoice_line`, possuindo exclusivamente `GRANT EXECUTE ON PROCEDURE public.criar_fatura_com_itens(int, jsonb)`.

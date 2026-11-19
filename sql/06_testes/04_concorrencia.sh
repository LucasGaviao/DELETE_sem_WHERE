#!/bin/sh
# =============================================================================
# Testes de concorrência — sessões psql REAIS em paralelo
# Arquivo: sql/06_testes/04_concorrencia.sh
#
# Um único bloco DO não prova concorrência (é uma só sessão). Aqui várias
# conexões psql rodam ao mesmo tempo, em segundo plano.
#
#   C1  R-TRG-02  N sessões inserindo itens na MESMA fatura -> total = Σ, sem erro
#   C2  R-TRG-02  N sessões movendo itens entre 2 faturas em sentidos opostos
#                 -> sem deadlock, ambos os totais corretos
#   C3  R-TRG-01  2 sessões cruzadas (A -> B e B -> A), READ COMMITTED
#                 -> uma é rejeitada por ciclo; hierarquia final acíclica
#   C4  R-TRG-01  idem, com a 2ª sessão em REPEATABLE READ
#                 -> rejeitada (ciclo ou erro de serialização 40001)
#   C5  R-SP-01   N sessões bd2_app chamando a procedure ao mesmo tempo
#                 -> N faturas, todas com itens e total correto
#   L1  R-SP-01   CONEXÃO REAL como bd2_app (login com senha, sem SET ROLE):
#                 senha errada recusada; CALL aceito; INSERT/SELECT diretos negados
#
# Conexão: variáveis padrão do libpq (PGHOST, PGPORT, PGUSER, PGPASSWORD) e
# CHINOOK_DB. Sem psql local, usa o container (docker compose exec).
# Script POSIX sh (roda também no sh do container Alpine).
# =============================================================================
set -eu

DB="${CHINOOK_DB:-chinook_serial}"
N="${N_SESSOES:-30}"

SENHA_APP="${BD2_APP_PASSWORD:-bd2_app}"

# Conexão como o usuário da aplicação (bd2_app), autenticando com SENHA.
# Na imagem oficial do PostgreSQL, conexões a localhost DENTRO do container
# usam 'trust' (sem senha); por isso, dentro do container, o login usa o IP
# do próprio container, que cai na regra 'scram-sha-256' do pg_hba.
# Uso: sqlapp_com_senha <senha> <argumentos do psql...>
if command -v psql >/dev/null 2>&1; then
    sql() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
    APP_HOST="${PGHOST:-localhost}"
    if [ -f /.dockerenv ] && { [ "$APP_HOST" = localhost ] || [ "$APP_HOST" = 127.0.0.1 ]; }; then
        APP_HOST=$(hostname -i | awk '{print $1}')
    fi
    sqlapp_com_senha() {
        senha=$1; shift
        PGHOST="$APP_HOST" PGUSER=bd2_app PGPASSWORD="$senha" psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"
    }
else
    sql() { docker compose exec -T postgres psql -U "${PGUSER:-postgres}" -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
    sqlapp_com_senha() {
        senha=$1; shift
        docker compose exec -T -e PGPASSWORD="$senha" postgres \
            sh -c 'psql -h "$(hostname -i | awk "{print \$1}")" -U bd2_app -X -q -At -v ON_ERROR_STOP=1 -d "$0" "$@"' "$DB" "$@"
    }
fi
sqlapp() { sqlapp_com_senha "$SENHA_APP" "$@"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FALHAS=0

ok()    { echo "[OK] $*"; }
falha() { echo "[FALHOU] $*"; FALHAS=$((FALHAS + 1)); }

# Executa SQL em segundo plano; grava o código de saída em $TMP/<nome>.rc
bg() {
    nome=$1; shift
    ( if sql "$@" >"$TMP/$nome.out" 2>&1; then echo 0; else echo 1; fi >"$TMP/$nome.rc" ) &
}
conta_falhas() { cat "$TMP"/"$1"*.rc | grep -c '^1$' || true; }

echo "=================================================================="
echo "Testes de concorrência (N = $N sessões paralelas) e de conexão real"
echo "=================================================================="

# -----------------------------------------------------------------------------
# C1 — R-TRG-02: N inserções simultâneas na mesma fatura
# -----------------------------------------------------------------------------
CLI=$(sql -c "SELECT min(customer_id) FROM public.customer")
INV1=$(sql -c "INSERT INTO public.invoice (customer_id, invoice_date, total) VALUES ($CLI, now(), 0) RETURNING invoice_id")

i=1
while [ "$i" -le "$N" ]; do
    bg "c1_$i" -c "BEGIN;
        INSERT INTO public.invoice_line (invoice_id, track_id, unit_price, quantity)
        SELECT $INV1, track_id, unit_price, 1 + ($i % 3)
          FROM public.track ORDER BY track_id OFFSET $i LIMIT 1;
        SELECT pg_sleep(0.05);
        COMMIT;"
    i=$((i + 1))
done
wait

ERR=$(conta_falhas c1_)
RES=$(sql -c "SELECT total = soma_itens AND qtd_itens = $N FROM bd2_demo.vw_auditoria_invoice_total WHERE invoice_id = $INV1")
TOT=$(sql -c "SELECT total || ' = ' || soma_itens FROM bd2_demo.vw_auditoria_invoice_total WHERE invoice_id = $INV1")
if [ "$ERR" -eq 0 ] && [ "$RES" = "t" ]; then
    ok "C1 R-TRG-02: $N inserções paralelas na mesma fatura; total $TOT; 0 erros"
else
    falha "C1 R-TRG-02: erros=$ERR, total/soma ok=$RES ($TOT)"; cat "$TMP"/c1_*.out
fi

# -----------------------------------------------------------------------------
# C2 — R-TRG-02: movimentação cruzada de itens entre duas faturas
# -----------------------------------------------------------------------------
INV2=$(sql -c "INSERT INTO public.invoice (customer_id, invoice_date, total) VALUES ($CLI, now(), 0) RETURNING invoice_id")
# metade dos itens vai para a fatura 2 antes do teste
sql -c "UPDATE public.invoice_line SET invoice_id = $INV2
         WHERE invoice_id = $INV1 AND invoice_line_id % 2 = 0" >/dev/null

j=1
for LINHA in $(sql -c "SELECT invoice_line_id FROM public.invoice_line WHERE invoice_id IN ($INV1, $INV2) ORDER BY 1"); do
    # cada sessão troca o item de fatura: 1 -> 2 ou 2 -> 1 (sentidos opostos ao mesmo tempo)
    bg "c2_$j" -c "BEGIN;
        UPDATE public.invoice_line
           SET invoice_id = CASE invoice_id WHEN $INV1 THEN $INV2 ELSE $INV1 END
         WHERE invoice_line_id = $LINHA;
        SELECT pg_sleep(0.05);
        COMMIT;"
    j=$((j + 1))
done
wait

ERR=$(conta_falhas c2_)
DEADLOCKS=$(cat "$TMP"/c2_*.out | grep -c 'deadlock' || true)
RES=$(sql -c "SELECT bool_and(total = soma_itens) AND sum(qtd_itens) = $N
                FROM bd2_demo.vw_auditoria_invoice_total WHERE invoice_id IN ($INV1, $INV2)")
if [ "$ERR" -eq 0 ] && [ "$RES" = "t" ]; then
    ok "C2 R-TRG-02: $N movimentações cruzadas entre 2 faturas; ambos os totais corretos; 0 deadlocks"
else
    falha "C2 R-TRG-02: erros=$ERR, deadlocks=$DEADLOCKS, totais ok=$RES"; cat "$TMP"/c2_*.out
fi

sql -c "DELETE FROM public.invoice_line WHERE invoice_id IN ($INV1, $INV2);
        DELETE FROM public.invoice      WHERE invoice_id IN ($INV1, $INV2);"

# -----------------------------------------------------------------------------
# C3/C4 — R-TRG-01: duas sessões tentam fechar um ciclo ao mesmo tempo
# -----------------------------------------------------------------------------
EA=$(sql -c "INSERT INTO public.employee (last_name, first_name) VALUES ('CONC_A', 'Teste') RETURNING employee_id")
EB=$(sql -c "INSERT INTO public.employee (last_name, first_name) VALUES ('CONC_B', 'Teste') RETURNING employee_id")

ciclo_cruzado() {
    rotulo=$1; isolamento=$2
    sql -c "UPDATE public.employee SET reports_to = NULL WHERE employee_id IN ($EA, $EB)"

    # Sessão 1: A passa a reportar a B e segura a transação por 3 s
    bg "${rotulo}_s1" -c "BEGIN;
        UPDATE public.employee SET reports_to = $EB WHERE employee_id = $EA;
        SELECT pg_sleep(3);
        COMMIT;"
    sleep 1
    # Sessão 2 (snapshot tirado ANTES do commit da sessão 1): B passa a reportar a A
    bg "${rotulo}_s2" -c "BEGIN ISOLATION LEVEL $isolamento;
        SELECT count(*) FROM public.employee;
        UPDATE public.employee SET reports_to = $EA WHERE employee_id = $EB;
        COMMIT;"
    wait

    RC1=$(cat "$TMP/${rotulo}_s1.rc"); RC2=$(cat "$TMP/${rotulo}_s2.rc")
    MSG2=$(grep -oE 'R-TRG-01[^.]*|could not serialize access[^.]*' "$TMP/${rotulo}_s2.out" | head -1 || true)
    ESTADO=$(sql -c "SELECT string_agg(last_name || '->' || COALESCE(reports_to::text, 'NULL'), ', ' ORDER BY last_name)
                       FROM public.employee WHERE employee_id IN ($EA, $EB)")
    CICLO=$(sql -c "SELECT count(*) FROM public.employee a JOIN public.employee b ON a.reports_to = b.employee_id
                     WHERE b.reports_to = a.employee_id AND a.employee_id IN ($EA, $EB)")

    if [ "$RC1" = 0 ] && [ "$RC2" = 1 ] && [ -n "$MSG2" ] && [ "$CICLO" = 0 ]; then
        ok "$rotulo R-TRG-01 ($isolamento): sessão 1 confirmou; sessão 2 rejeitada ($MSG2); estado final: $ESTADO (sem ciclo)"
    else
        falha "$rotulo R-TRG-01 ($isolamento): rc1=$RC1 rc2=$RC2 msg='$MSG2' ciclo=$CICLO estado=$ESTADO"
        cat "$TMP/${rotulo}_s1.out" "$TMP/${rotulo}_s2.out"
    fi
}

ciclo_cruzado C3 "READ COMMITTED"
ciclo_cruzado C4 "REPEATABLE READ"

sql -c "UPDATE public.employee SET reports_to = NULL WHERE employee_id IN ($EA, $EB);
        DELETE FROM public.employee WHERE employee_id IN ($EA, $EB);"

# -----------------------------------------------------------------------------
# C5 — R-SP-01: N chamadas simultâneas da procedure pelo usuário bd2_app
# -----------------------------------------------------------------------------
T1=$(sql -c "SELECT min(track_id) FROM public.track")
k=1
while [ "$k" -le "$N" ]; do
    bg "c5_$k" -c "SET ROLE bd2_app;
        CALL public.criar_fatura_com_itens($CLI,
             '[{\"track_id\": $((T1 + k)), \"quantity\": 1}, {\"track_id\": $((T1 + k + 1)), \"quantity\": 2}]');"
    k=$((k + 1))
done
wait

ERR=$(conta_falhas c5_)
IDS=$(cat "$TMP"/c5_*.out | grep -E '^[0-9]+$' | paste -sd, -)
if [ -n "$IDS" ]; then
    RES=$(sql -c "SELECT count(*) = $N AND bool_and(total = soma_itens AND qtd_itens = 2)
                    FROM bd2_demo.vw_auditoria_invoice_total WHERE invoice_id IN ($IDS)")
else
    RES=f
fi
if [ "$ERR" -eq 0 ] && [ "$RES" = "t" ]; then
    ok "C5 R-SP-01: $N chamadas paralelas como bd2_app; $N faturas, todas com 2 itens e total correto"
else
    falha "C5 R-SP-01: erros=$ERR, faturas ok=$RES"; cat "$TMP"/c5_*.out
fi
[ -n "$IDS" ] && sql -c "DELETE FROM public.invoice_line WHERE invoice_id IN ($IDS);
                         DELETE FROM public.invoice      WHERE invoice_id IN ($IDS);"

# -----------------------------------------------------------------------------
# L1 — R-SP-01: conexão real como bd2_app (login com senha, sem SET ROLE)
# -----------------------------------------------------------------------------
QUEM=$(sqlapp -c "SELECT current_user || '/' || session_user" 2>"$TMP/l1_login.err" || echo "FALHA_LOGIN")
# a senha é de fato exigida? (uma senha errada deve ser recusada)
if sqlapp_com_senha "senha-errada-$$" -c "SELECT 1" >/dev/null 2>"$TMP/l1_senha.err"; then
    SENHA_EXIGIDA="não (o pg_hba deste servidor usa trust para esta conexão)"
else
    SENHA_EXIGIDA=$(grep -oE 'password authentication failed for user "?[a-z0-9_]+"?' "$TMP/l1_senha.err" | head -1 | tr -d '"' || true)
    [ -n "$SENHA_EXIGIDA" ] || SENHA_EXIGIDA="erro inesperado: $(head -1 "$TMP/l1_senha.err")"
fi
INV_APP=$(sqlapp -c "CALL public.criar_fatura_com_itens($CLI, '[{\"track_id\": $T1, \"quantity\": 3}]')" 2>"$TMP/l1_call.err" || true)
if sqlapp -c "INSERT INTO public.invoice (customer_id, invoice_date, total) VALUES ($CLI, now(), 0)" >/dev/null 2>"$TMP/l1_ins.err"; then
    INS="ACEITO"
else
    INS=$(grep -oE 'permission denied[^"]*' "$TMP/l1_ins.err" | head -1 || true)
fi
if sqlapp -c "SELECT count(*) FROM public.invoice" >/dev/null 2>"$TMP/l1_sel.err"; then
    SEL="ACEITO"
else
    SEL=$(grep -oE 'permission denied[^"]*' "$TMP/l1_sel.err" | head -1 || true)
fi
OK_FATURA=f
if echo "$INV_APP" | grep -qE '^[0-9]+$'; then
    OK_FATURA=$(sql -c "SELECT total = soma_itens AND qtd_itens = 1 FROM bd2_demo.vw_auditoria_invoice_total WHERE invoice_id = $INV_APP")
fi
if [ "$QUEM" = "bd2_app/bd2_app" ] && [ "$OK_FATURA" = t ] && [ -n "$INS" ] && [ "$INS" != ACEITO ] \
   && [ -n "$SEL" ] && [ "$SEL" != ACEITO ]; then
    ok "L1 R-SP-01: login real como bd2_app com senha (senha errada: $SENHA_EXIGIDA); CALL criou a fatura $INV_APP; INSERT direto: $INS; SELECT direto: $SEL"
else
    falha "L1 R-SP-01: usuario=$QUEM fatura=$INV_APP ok=$OK_FATURA insert='$INS' select='$SEL'"
    cat "$TMP"/l1_*.err
fi
echo "$INV_APP" | grep -qE '^[0-9]+$' && sql -c "DELETE FROM public.invoice_line WHERE invoice_id = $INV_APP;
                                                 DELETE FROM public.invoice      WHERE invoice_id = $INV_APP;"

# -----------------------------------------------------------------------------
# Auditoria final
# -----------------------------------------------------------------------------
DIV=$(sql -c "SELECT count(*) FROM bd2_demo.vw_auditoria_invoice_total WHERE total <> soma_itens")
[ "$DIV" = 0 ] && ok "Auditoria final: 0 faturas com total divergente" || falha "Auditoria final: $DIV faturas divergentes"

echo "------------------------------------------------------------------"
if [ "$FALHAS" -eq 0 ]; then
    echo "OK: Testes de concorrência passaram."
else
    echo "FALHA: $FALHAS teste(s) de concorrência falharam."
    exit 1
fi

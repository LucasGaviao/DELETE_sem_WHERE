#!/usr/bin/env bash
# =============================================================================
# empacotar_entrega.sh — Monta o pacote de entrega (relatório + código).
#
# Pré-requisitos (nesta ordem):
#   1. ./run_all.sh                         -> evidências atualizadas
#   2. python3 relatorio/gerar_relatorio.py -> relatorio/Relatorio_Trabalho_BD2.pdf
#
# Saída: dist/Trabalho_BD2.zip (e a pasta dist/Trabalho_BD2/ correspondente)
# Ficam de fora os arquivos internos do grupo (AGENTS.md, docs/, fonte LaTeX
# do relatório, .git). O README do pacote é entrega/README_ENTREGA.md.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

NOME="Trabalho_BD2"
DIST="dist"
DEST="$DIST/$NOME"
PDF="relatorio/Relatorio_Trabalho_BD2.pdf"
LOG="evidencias/run_all.log"

falha() { echo "ERRO: $*" >&2; exit 1; }

# --- Verificações: só empacota uma execução bem-sucedida e um relatório atual
[ -f "$LOG" ] || falha "$LOG não existe; execute ./run_all.sh"
grep -q 'Execução concluída com sucesso!' "$LOG" || falha "a última execução do run_all.sh não terminou com sucesso"
! grep -q 'FALHOU' "$LOG" || falha "há casos FALHOU em $LOG"
[ -f "$PDF" ] || falha "$PDF não existe; execute python3 relatorio/gerar_relatorio.py"
[ "$PDF" -nt "$LOG" ] || falha "o PDF é mais antigo que a última execução; gere o relatório novamente"
if grep -q 'preencher relatorio/integrantes.txt' relatorio/numeros.tex 2>/dev/null; then
    echo "AVISO: os nomes dos integrantes ainda não foram preenchidos (relatorio/integrantes.txt)." >&2
fi

# --- Montagem
rm -rf "$DEST" "$DIST/$NOME.zip"
mkdir -p "$DEST"

cp "$PDF" "$DEST/"
cp entrega/README_ENTREGA.md "$DEST/README.md"
cp docker-compose.yml .env.example run_all.sh run_all.ps1 .gitattributes "$DEST/"
cp -r sql evidencias "$DEST/"
rm -f "$DEST/evidencias/README.md"
chmod +x "$DEST/run_all.sh" "$DEST/sql/06_testes/04_concorrencia.sh"

# --- Compactação
( cd "$DIST" && zip -qr "$NOME.zip" "$NOME" )

echo "Pacote gerado: $DIST/$NOME.zip"
( cd "$DIST" && unzip -l "$NOME.zip" | tail -n 1 )

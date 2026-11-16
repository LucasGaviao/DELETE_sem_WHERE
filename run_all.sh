#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Executa a recriação limpa do banco Chinook, aplica todos os
# módulos SQL em ordem e executa a suíte de testes.
# Pode ser executado dentro do container Docker ou na máquina host (se psql
# estiver instalado ou via docker compose exec).
# =============================================================================
set -euo pipefail

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
export PGPASSWORD

DB_ADMIN="${POSTGRES_DB:-postgres}"
DB_TARGET="${CHINOOK_DB:-chinook_serial}"

# Detecta se psql está disponível localmente; caso contrário, usa o container bd2_postgres
run_psql() {
    if command -v psql >/dev/null 2>&1; then
        psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -v ON_ERROR_STOP=1 "$@"
    else
        docker compose exec -T postgres psql -U "$PGUSER" -v ON_ERROR_STOP=1 "$@"
    fi
}

echo "=================================================================="
echo "1. Resetando banco ($DB_TARGET) e limpando roles do cluster"
echo "=================================================================="
run_psql -d "$DB_ADMIN" <<SQL
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = '$DB_TARGET'
   AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS $DB_TARGET;

DO \$\$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bd2_app') THEN
        EXECUTE 'DROP OWNED BY bd2_app CASCADE';
        EXECUTE 'DROP ROLE bd2_app';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bd2_owner') THEN
        EXECUTE 'DROP OWNED BY bd2_owner CASCADE';
        EXECUTE 'DROP ROLE bd2_owner';
    END IF;
END \$\$;
SQL

echo "=================================================================="
echo "2. Carregando Chinook Database v1.4.5 (SerialPKs) -> $DB_TARGET"
echo "=================================================================="
run_psql -d "$DB_ADMIN" -f sql/00_ambiente/Chinook_PostgreSql_SerialPKs.sql >/dev/null

echo "=================================================================="
echo "3. Verificando ambiente inicial (00_verificar_ambiente.sql)"
echo "=================================================================="
run_psql -d "$DB_TARGET" -f sql/00_ambiente/00_verificar_ambiente.sql

# Executa em ordem os arquivos .sql dos módulos 01 a 06 (quando implementados)
for dir in \
    sql/01_catalogos \
    sql/02_administracao \
    sql/03_ddl_dinamico \
    sql/04_maquina_estados \
    sql/05_regras_semanticas \
    sql/06_testes
do
    if [ -d "$dir" ]; then
        for file in "$dir"/*.sql; do
            [ -e "$file" ] || continue
            echo "------------------------------------------------------------------"
            echo "Executando: $file"
            run_psql -d "$DB_TARGET" -f "$file"
        done
    fi
done

echo "=================================================================="
echo "Execução concluída com sucesso!"
echo "=================================================================="

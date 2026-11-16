# =============================================================================
# run_all.ps1 — Atalho PowerShell (Windows) para subir o PostgreSQL 16 via
# Docker Compose e executar o pipeline completo (run_all.sh) dentro do container.
# =============================================================================
$ErrorActionPreference = "Stop"

Write-Host "==> Verificando container PostgreSQL 16 (docker compose)..." -ForegroundColor Cyan
docker compose up -d --wait

Write-Host "==> Executando pipeline completo (run_all.sh) no container..." -ForegroundColor Cyan
docker compose exec -T postgres sh /workspace/run_all.sh

# =============================================================================
# run_all.ps1 — Atalho PowerShell (Windows) para subir o PostgreSQL 16 via
# Docker Compose e executar o pipeline completo (run_all.sh) dentro do container.
#
# Se o Windows bloquear a execução de scripts, rode:
#   powershell -ExecutionPolicy Bypass -File .\run_all.ps1
# =============================================================================
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

Write-Host "==> Verificando container PostgreSQL 16 (docker compose)..." -ForegroundColor Cyan
docker compose up -d --wait
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: não foi possível subir o container (a porta 5432 está livre?)." -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "==> Executando pipeline completo (run_all.sh) no container..." -ForegroundColor Cyan
docker compose exec -T postgres sh /workspace/run_all.sh
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: a execução falhou (código $LASTEXITCODE). Veja evidencias\run_all.log." -ForegroundColor Red
    exit $LASTEXITCODE
}
Write-Host "==> Concluído. Saídas em evidencias\." -ForegroundColor Green

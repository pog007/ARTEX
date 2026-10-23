# ARTEX install script (Windows): 1) all-Docker  2) local build & run
#
# Usage (from the repo root, in PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
# pipe text to native tools (psql) as UTF-8 instead of ASCII
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }
function Ask($p, $d = '') {
  $prompt = if ($d -ne '') { "$p [$d]" } else { $p }
  $a = Read-Host $prompt
  if ([string]::IsNullOrEmpty($a)) { $d } else { $a }
}
function Rand {
  $chars = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  $bytes = New-Object byte[] 24
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}
function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
# native commands don't throw on failure; check the exit code explicitly
# (plain $args, not param(): "-d"/"-e" must reach the native tool, not bind to common parameters)
function Run {
  $exe, $rest = $args
  & $exe @rest
  if ($LASTEXITCODE -ne 0) { Die "$exe $($rest -join ' ') failed (exit $LASTEXITCODE)" }
}
# run silently and return success; EAP=Continue because PS 5.1 turns redirected
# native stderr into terminating errors under 'Stop'
function Test-Native {
  $ErrorActionPreference = 'Continue'
  $exe, $rest = $args
  & $exe @rest *> $null
  $LASTEXITCODE -eq 0
}
# BOM-less UTF-8: Go's JSON parser rejects a BOM
function WriteUtf8($path, $text) {
  [System.IO.File]::WriteAllText((Join-Path $PWD $path), $text, (New-Object System.Text.UTF8Encoding $false))
}

# -- docker environment check ------------------------------------
function Ensure-Docker {
  if ((Have docker) -and (Test-Native docker compose version)) {
    if (-not (Test-Native docker info)) { Die "docker is installed but the engine is not running; start Docker Desktop and retry" }
    Ok "docker and docker compose detected"; return
  }
  Warn "docker / docker compose not detected"
  Die "please install Docker Desktop (https://www.docker.com/products/docker-desktop/ or: winget install Docker.DockerDesktop) and retry"
}

# -- 1) All-Docker -----------------------------------------------
function Install-Docker {
  Ensure-Docker
  if (-not (Test-Path .env)) {
    $lines = if (Test-Path .env.example) { Get-Content .env.example } else { @() }
    $pw  = Ask 'Postgres password (press Enter to generate randomly)' (Rand)
    $key = Ask 'ANTHROPIC_API_KEY (may be empty, configure later in the UI)' ''
    $lines = $lines | ForEach-Object {
      if ($_ -like 'POSTGRES_PASSWORD=*') { "POSTGRES_PASSWORD=$pw" }
      elseif ($_ -like 'ANTHROPIC_API_KEY=*') { "ANTHROPIC_API_KEY=$key" }
      else { $_ }
    }
    WriteUtf8 '.env' (($lines -join "`n") + "`n")
    Ok ".env generated (POSTGRES_PASSWORD set)"
  } else {
    Info "reusing existing .env"
  }
  Info "pulling images and starting..."
  docker compose pull
  if ($LASTEXITCODE -ne 0) { Warn "docker compose pull failed; trying with local images" }
  Run docker compose up -d
  Ok "started -> http://localhost:8787"
  Info "view logs: docker compose logs -f artex"
}

# -- 2) Local build & run ----------------------------------------
function Install-Local {
  Write-Host "Database setup:"
  Write-Host "  1) Connect to an existing PostgreSQL"
  Write-Host "  2) Start a PostgreSQL with Docker (requires docker)"
  switch (Ask 'Choose' '1') {
    '2' {
      Ensure-Docker
      $pw = Ask 'Postgres password (press Enter for random)' (Rand)
      $names = docker ps -a --format '{{.Names}}'
      if ($names -contains 'artex-pg') {
        Info "reusing existing artex-pg container"
        Run docker start artex-pg | Out-Null
      } else {
        Run docker run -d --name artex-pg -p 5432:5432 `
          -e POSTGRES_USER=artex -e "POSTGRES_PASSWORD=$pw" -e POSTGRES_DB=artex `
          -v artex-pg:/var/lib/postgresql/data postgres:16-alpine
      }
      # POSTGRES_PASSWORD only applies to an empty volume; force the chosen password
      # so config.json matches even when the artex-pg volume is reused
      Info "waiting for PostgreSQL..."
      for ($i = 0; $i -lt 30; $i++) {
        if (Test-Native docker exec artex-pg pg_isready -h 127.0.0.1 -U artex -d artex) { break }
        Start-Sleep -Seconds 1
      }
      # the password goes through stdin, not argv, to avoid Windows argument quoting
      $sqlPw = $pw -replace "'", "''"
      "ALTER USER artex PASSWORD '$sqlPw';" | docker exec -i artex-pg psql -q -U artex -d artex -v ON_ERROR_STOP=1
      if ($LASTEXITCODE -ne 0) { Die "failed to set the artex password" }
      $db = [ordered]@{ host = '127.0.0.1'; port = 5432; user = 'artex'; password = $pw; dbname = 'artex'; sslmode = 'disable' }
    }
    default {
      $db = [ordered]@{
        host     = Ask 'Database host' '127.0.0.1'
        port     = [int](Ask 'Port' '5432')
        user     = Ask 'User' 'artex'
        password = Ask 'Password' ''
        dbname   = Ask 'Database name' 'artex'
        sslmode  = Ask 'sslmode (disable/require)' 'disable'
      }
    }
  }

  # generate config.json (ConvertTo-Json escapes quotes/backslashes in the password)
  WriteUtf8 'config.json' ((@{ database = $db } | ConvertTo-Json) + "`n")
  Ok "config.json generated"

  # go environment check
  if (-not (Have go)) { Die "Go not detected; please install Go (>=1.26) first: https://go.dev/dl/" }
  Ok "Go: $(go version)"

  $env:CGO_ENABLED = '0'
  # embedding the frontend requires node to produce the static assets
  if ((Have npm.cmd) -and (Have node)) {
    $nodeVer = [version]((node -v).TrimStart('v'))
    if ($nodeVer -lt [version]'20.9.0') { Die "Node $nodeVer detected; Next.js needs Node >= 20.9 (nvm-windows: nvm install 22 && nvm use 22)" }
    Info "building frontend static assets..."
    Push-Location web
    try {
      Run npm.cmd ci
      # build:static uses POSIX "NEXT_EXPORT=1 next build", which cmd.exe can't run
      $env:NEXT_EXPORT = '1'
      Run npx.cmd next build
    } finally {
      Remove-Item Env:NEXT_EXPORT -ErrorAction SilentlyContinue
      Pop-Location
    }
    if (Test-Path server\webui\dist) { Remove-Item -Recurse -Force server\webui\dist }
    New-Item -ItemType Directory -Force server\webui | Out-Null
    Copy-Item -Recurse web\out server\webui\dist
    Info "compiling embedded single binary..."
    Run go build -tags embedui -trimpath -o artex.exe ./cmd/artex
  } else {
    Warn "npm not detected: building a backend WITHOUT the embedded frontend (run npm run dev separately for the frontend)"
    Run go build -o artex.exe ./cmd/artex
  }
  Ok "build complete -> .\artex.exe"

  Info "starting... (Ctrl-C to exit)"
  & .\artex.exe
}

Write-Host "=============================="
Write-Host "  ARTEX Install"
Write-Host "  1) All-Docker install"
Write-Host "  2) Run locally (go build)"
Write-Host "=============================="
switch (Ask 'Choose' '1') {
  '1' { Install-Docker }
  '2' { Install-Local }
  default { Die "invalid choice" }
}

<#
.SYNOPSIS
  env-repro / verify.ps1 — check the reproduced environment against the pinned manifest.

.DESCRIPTION
  irm https://raw.githubusercontent.com/c0a2302825/env-repro/main/scripts/verify.ps1 | iex

  Exit code 0 = every check passed.

.NOTES
  Runs on Windows PowerShell 5.1 and PowerShell 7+.
#>

$ErrorActionPreference = 'Continue'
$Raw = 'https://raw.githubusercontent.com/c0a2302825/env-repro/main'

$script:Pass = 0; $script:Fail = 0; $script:Warn = 0
function Ok  { param($m) Write-Host "  PASS  $m" -ForegroundColor Green;  $script:Pass++ }
function No  { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red;    $script:Fail++ }
function Wn  { param($m) Write-Host "  WARN  $m" -ForegroundColor Yellow; $script:Warn++ }

function Has-Cmd { param($n) return [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function First16 { param($p) if (Test-Path $p) { (Get-FileHash $p -Algorithm SHA256).Hash.ToLower().Substring(0,16) } else { $null } }

Write-Host "`nenv-repro verification`n" -ForegroundColor White

$H = $env:USERPROFILE

# ------------------------------------------------------------------ 1. tools
Write-Host "[1/5] toolchain"
function Check-Ver {
    param($Cmd, $Want, $Label)
    if (-not (Has-Cmd $Cmd)) { No "$Label`: not on PATH"; return }
    $raw = (& $Cmd --version 2>&1 | Out-String).Trim()
    $line = ($raw -split "`n")[0].Trim()
    if ($line -like "*$Want*") { Ok "$Label $Want" }
    else { Wn "$Label`: expected $Want, got '$($line.Substring(0,[Math]::Min(40,$line.Length)))'" }
}
Check-Ver 'opencode' '1.18.29' 'opencode'
Check-Ver 'claude'   '2.1.233' 'claude'
Check-Ver 'node'     'v26'     'node'
Check-Ver 'rg'       '15.2.0'  'ripgrep'
Check-Ver 'jq'       '1.7.1'   'jq'
Check-Ver 'gh'       '2.100.0' 'gh'

# python must be miniconda (or anaconda) and precede other pythons
$py = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $py) { No "python: not on PATH" }
elseif ($py.Source -match '(miniconda3|anaconda3)') { Ok "python -> $($py.Source)" }
else { Wn "python resolves to $($py.Source), expected miniconda3 — check PATH order" }

# ------------------------------------------------------------------ 2. config
Write-Host "`n[2/5] config files"
foreach ($f in @(
    '.config\opencode\opencode.jsonc',
    '.config\opencode\.opencode.json',
    '.config\opencode\package.json',
    '.claude\settings.json',
    '.agents\.skill-lock.json')) {
    if (Test-Path (Join-Path $H $f)) { Ok $f } else { No "$f missing" }
}
if (Test-Path (Join-Path $H '.config\opencode\node_modules\@opencode-ai\plugin')) {
    Ok "~/.config/opencode/node_modules (@opencode-ai/plugin)"
} else {
    Wn "@opencode-ai/plugin not installed — run: cd ~/.config/opencode; npm install"
}

# ------------------------------------------------------------------ manifest
$M = $null
foreach ($cand in @("$PWD\manifests\env-manifest.json", "$H\env-repro\manifests\env-manifest.json")) {
    if (Test-Path $cand) { $M = Get-Content $cand -Raw | ConvertFrom-Json; Ok "manifest: local ($cand)"; break }
}
if (-not $M) {
    $tmp = Join-Path $env:TEMP 'env-repro-manifest.json'
    try { Invoke-WebRequest -Uri "$Raw/manifests/env-manifest.json" -OutFile $tmp -UseBasicParsing
          $M = Get-Content $tmp -Raw | ConvertFrom-Json; Ok "manifest: fetched from repo" }
    catch { No "cannot obtain manifest"; Write-Host "`nsummary  pass=$script:Pass warn=$script:Warn fail=$script:Fail"; exit 1 }
}

# ------------------------------------------------------------------ 3. skills
Write-Host "`n[3/5] skills"
$skOk = 0
foreach ($s in $M.skills) {
    $f = Join-Path $H ((($s.dest -replace '/','\')) + '\SKILL.md')
    $got = First16 $f
    if (-not $got) { No "skill $($s.name): SKILL.md missing at $($s.dest)"; continue }
    $exp = $s.skillMdSha256.Substring(0, [Math]::Min(16, $s.skillMdSha256.Length))
    if ($got -eq $exp) { Ok "skill $($s.name) ($got)"; $skOk++ }
    else { No "skill $($s.name): sha256 $got != $exp" }
}
Write-Host "  ---- $skOk/$($M.skills.Count) skills verified"

# ------------------------------------------------------------------ 4. links
Write-Host "`n[4/5] directory links (.claude\skills -> .agents\skills)"
foreach ($l in $M.symlinks) {
    $from = Join-Path $H ($l.from -replace '/','\')
    $base = Split-Path $from -Leaf
    if (-not (Test-Path $from)) { No "$base`: not linked"; continue }
    $item = Get-Item $from -Force
    $linked = $item.LinkType -in @('SymbolicLink','Junction')
    if ($linked) { Ok "$base -> $(Split-Path $item.Target -Leaf)" }
    else { Wn "$base is a real directory, expected a link (symlink or junction)" }
}

# ------------------------------------------------------------------ 5. runtime
Write-Host "`n[5/5] runtime state"
if (Has-Cmd 'ollama') {
    Ok "ollama installed"
    $probe = (& ollama list 2>&1 | Out-String)
    if ($probe -match 'NAME|model') { Ok "ollama server running" }
    else { Wn "ollama server not running — matches the captured host; start it from the tray or: ollama serve" }
} else { Wn "ollama not installed (optional)" }

$soffice = Get-Command soffice -ErrorAction SilentlyContinue
if (-not $soffice) {
    $cand = @("$Env:ProgramFiles\LibreOffice\program\soffice.exe",
              "${Env:ProgramFiles(x86)}\LibreOffice\program\soffice.exe") |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($cand) { Ok "LibreOffice present (document QA)" } else { Wn "LibreOffice absent (only needed for pptx/docx -> PDF)" }
} else { Ok "LibreOffice present (document QA)" }

if (Test-Path (Join-Path $H '.local\share\opencode\opencode.db')) {
    Wn "opencode.db exists — session state, not part of the reproduction"
} else { Ok "no session DB (correct: not reproduced)" }

Write-Host "`nsummary  pass=$script:Pass  warn=$script:Warn  fail=$script:Fail" -ForegroundColor White
if ($script:Fail -gt 0) { exit 1 }
Write-Host "Environment matches the manifest.`n" -ForegroundColor Green

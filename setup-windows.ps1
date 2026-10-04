<#
.SYNOPSIS
  env-repro / setup-windows.ps1 — one-paste reproduction of the environment captured 2026-10-05.

.DESCRIPTION
  PowerShell 5.1+ (built into Windows 10/11). Run non-interactively:

    irm https://raw.githubusercontent.com/c0a2302825/env-repro/main/setup-windows.ps1 | iex

  Or save it and run:

    .\setup-windows.ps1

  Every version is pinned to the manifest. Re-running is safe.

.NOTES
  Two Windows-specific realities this script does not paper over:
   - Claude Code is installed via winget, because upstream marks the npm channel deprecated on Windows.
   - miniconda3 must precede other Python installs on PATH, or `python3`/`pip` resolve elsewhere.
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$Repo      = 'c0a2302825/env-repro'
$Raw       = "https://raw.githubusercontent.com/$Repo/main"
$Work      = Join-Path $env:TEMP ("env-repro-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$UserHome  = $env:USERPROFILE
$UnixHome  = $env:USERPROFILE

New-Item -ItemType Directory -Force -Path $Work | Out-Null

function Say  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Warn { param($m) Write-Host "[warn] $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "[fail] $m" -ForegroundColor Red; exit 1 }

function Has-Cmd { param($n) return [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Invoke-External {
    param($Exe, [string[]]$Args)
    Write-Host "    $Exe $($Args -join ' ')" -ForegroundColor DarkGray
    & $Exe @Args
    return $LASTEXITCODE
}

# ------------------------------------------------------------ winget wrapper
$script:WingetMissing = $false

function Ensure-Winget {
    if (Has-Cmd 'winget') { return }
    $script:WingetMissing = $true
    Warn "winget not found. Install App Installer from the Microsoft Store, or install these manually:"
    Warn "  Node.js LTS, Miniconda3, ripgrep, jq, GitHub CLI, Git LFS, LibreOffice, Ollama, Claude Code"
}

function Install-Winget {
    param([string]$Id, [string]$Label)
    if ($script:WingetMissing) { Warn "$Label skipped (no winget)"; return }
    Write-Host "    $Label ($Id)" -ForegroundColor DarkGray
    & winget install --id $Id --exact --source winget `
        --accept-source-agreements --accept-package-agreements `
        --disable-interactivity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {  # already-installed exit code
        Warn "$Label: winget returned $LASTEXITCODE"
    }
}

# ------------------------------------------------------------ prerequisites
Say "Platform check"
if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    Die "This script is for Windows. Use setup-macos.sh instead."
}
$arch = $env:PROCESSOR_ARCHITECTURE
Write-Host "    Windows / $arch"
if ($arch -ne 'ARM64') {
    Write-Host "    captured host is arm64 (Apple M3); most tools are fine on x64, some differ." -ForegroundColor DarkGray
}

# git + curl are needed to fetch pinned skills
foreach ($pair in @(@('git','Git.GitLFS'), @('curl','curl'))) {
    if (-not (Has-Cmd $pair[0])) { Install-Winget $pair[1] $pair[0] }
}
if (-not (Has-Cmd 'git')) { Die "git is required and could not be installed" }

# ------------------------------------------------------------ manifest
Say "Fetching manifest"
$MPath = Join-Path $Work 'env-manifest.json'
try { Invoke-WebRequest -Uri "$Raw/manifests/env-manifest.json" -OutFile $MPath -UseBasicParsing }
catch { Die "manifest download failed: $($_.Exception.Message)" }
$M = Get-Content $MPath -Raw | ConvertFrom-Json
Write-Host "    captured $($M.capturedAt) / $($M.host.cpu)"

# ------------------------------------------------------------ tools
Say "Installing pinned tools"
Ensure-Winget

if (Has-Cmd 'opencode') { Write-Host "    opencode already installed ($(& opencode --version))" -ForegroundColor DarkGray }
else {
    Write-Host "    opencode via npm (opencode-ai@1.18.29)" -ForegroundColor DarkGray
    & npm i -g opencode-ai@1.18.29 2>&1 | Out-Null
}

if (Has-Cmd 'claude') { Write-Host "    claude already installed ($(& claude --version))" -ForegroundColor DarkGray }
else { Install-Winget 'Anthropic.ClaudeCode' 'Claude Code' }

if (Has-Cmd 'node') { Write-Host "    node already installed ($(& node -v))" -ForegroundColor DarkGray }
else { Install-Winget 'OpenJS.NodeJS.LTS' 'Node.js LTS' }

Install-Winget 'Anaconda.Miniconda3'    'Miniconda3'
Install-Winget 'BurntSushi.ripgrep.MSVC' 'ripgrep'
Install-Winget 'jqlang.jq'               'jq'
Install-Winget 'GitHub.cli'              'GitHub CLI'
Install-Winget 'Git.GitLFS'              'Git LFS'
Install-Winget 'Ollama.Ollama'           'Ollama'
Install-Winget 'TheDocumentFoundation.LibreOffice' 'LibreOffice'

# refresh PATH from the machine/user environment so newly installed tools resolve
$env:PATH = [System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('PATH','User')

# ------------------------------------------------------------ PATH: miniconda first
Say "Ensuring miniconda3 precedes other Python installs on PATH"
$condaBin = Join-Path $UserHome 'miniconda3'
$condaBin = Join-Path $condaBin 'Scripts'
$condaRoot = Join-Path $UserHome 'miniconda3'
if (-not (Test-Path (Join-Path $condaRoot 'python.exe'))) {
    $alt = Join-Path $UserHome 'anaconda3'
    if (Test-Path (Join-Path $alt 'python.exe')) { $condaRoot = $alt }
}

if ($env:PATH -notlike "*$condaRoot*") {
    $userPath = [System.Environment]::GetEnvironmentVariable('PATH','User')
    if ($userPath -notlike "*$condaRoot*") {
        [System.Environment]::SetEnvironmentVariable('PATH', "$condaRoot;$condaRoot\Scripts;$userPath", 'User')
        $env:PATH = "$condaRoot;$condaRoot\Scripts;$env:PATH"
        Say "prepended $condaRoot to the user PATH (restart your shell to make it stick)"
    } else {
        $env:PATH = "$condaRoot;$condaRoot\Scripts;$env:PATH"
        Write-Host "    already in user PATH" -ForegroundColor DarkGray
    }
} else {
    Write-Host "    already on PATH" -ForegroundColor DarkGray
}

# ------------------------------------------------------------ skills
Say "Fetching skills at pinned commits"
foreach ($dir in @("$UnixHome\.agents\skills", "$UnixHome\.config\opencode\skills", "$UnixHome\.claude\skills")) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$skillsOk = 0; $skillsBad = 0

function Test-Hash {
    param([string]$Path, [string]$Expected)
    if (-not (Test-Path $Path)) { return 'MISSING' }
    $h = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLower().Substring(0,16)
    if ([string]::IsNullOrEmpty($Expected)) { return $h }
    if ($h -eq $Expected.Substring(0, [Math]::Min(16, $Expected.Length))) { return $h }
    return "MISMATCH($h)"
}

foreach ($s in $M.skills) {
    $dest = Join-Path $UnixHome ($s.dest -replace '/', '\')
    $skillFile = Join-Path $dest 'SKILL.md'

    if (Test-Path $skillFile) {
        $r = Test-Hash $skillFile $s.skillMdSha256
        if ($r -like 'MISMATCH*') { Warn "$($s.name): $($r -replace 'MISMATCH\(','' ) != expected"; $skillsBad++ }
        else { Write-Host "    $($s.name.PadRight(24)) already present" -ForegroundColor DarkGray; $skillsOk++ }
        continue
    }

    if ($s.source -eq 'github') {
        $tmp = Join-Path $Work $s.name
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $repoDir = Join-Path $tmp 'repo'
        Write-Host "    $($s.name.PadRight(24)) $($s.repo)@$($s.ref.Substring(0,8))" -ForegroundColor DarkGray
        & git clone --quiet --filter=blob:none --no-checkout --depth 1 "https://github.com/$($s.repo).git" $repoDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Warn "$($s.name): clone failed"; $skillsBad++; continue }
        Push-Location $repoDir
        & git fetch --quiet --depth 1 origin $s.ref 2>&1 | Out-Null
        & git checkout --quiet $s.ref -- $s.subdir 2>&1 | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
        Pop-Location
        if (-not $ok) { Warn "$($s.name): pinned ref $($s.ref.Substring(0,8)) not fetchable"; $skillsBad++; continue }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -Recurse -Force (Join-Path $repoDir ($s.subdir -replace '/','\')) $dest
    }
    else {
        # vendored: no upstream exists
        Write-Host "    $($s.name.PadRight(24)) vendored (no upstream)" -ForegroundColor DarkGray
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $srcFile = Join-Path $Work ([System.IO.Path]::GetFileName($s.file))
        try { Invoke-WebRequest -Uri "$Raw/$($s.file)" -OutFile $skillFile -UseBasicParsing }
        catch { Warn "$($s.name): vendored download failed"; $skillsBad++; continue }
    }

    $r = Test-Hash $skillFile $s.skillMdSha256
    if ($r -like 'MISMATCH*') { Warn "$($s.name): hash $($r -replace 'MISMATCH\(','') != expected"; $skillsBad++ }
    elseif ($r -eq 'MISSING')  { Warn "$($s.name): SKILL.md not created"; $skillsBad++ }
    else { $skillsOk++ }
}
Write-Host "    ---- $skillsOk/$($M.skills.Count) skills installed ($skillsBad problem(s))"

# ------------------------------------------------------------ symlinks
Say "Linking .claude\skills -> .agents\skills"
foreach ($l in $M.symlinks) {
    $from = Join-Path $UnixHome ($l.from -replace '/', '\')
    $to   = Join-Path $UnixHome ($l.to   -replace '/', '\')
    $base = Split-Path $from -Leaf

    if (Test-Path $from) {
        if ((Get-Item $from).LinkType -eq 'SymbolicLink') {
            Write-Host "    $($base.PadRight(24)) already linked" -ForegroundColor DarkGray
        } else {
            Warn "$base exists and is not a symlink — left untouched"
        }
        continue
    }
    if (-not (Test-Path $to)) { Warn "$base: target missing, skipped"; continue }

    try {
        New-Item -ItemType SymbolicLink -Path $from -Target $to -ErrorAction Stop | Out-Null
        Write-Host "    $($base.PadRight(24)) -> $base" -ForegroundColor DarkGray
    } catch {
        # Developer Mode off => symlinks need elevation. Fall back to a junction,
        # which works for directories without admin rights.
        try {
            New-Item -ItemType Junction -Path $from -Target $to -ErrorAction Stop | Out-Null
            Write-Host "    $($base.PadRight(24)) -> $base (junction)" -ForegroundColor DarkGray
        } catch {
            Warn "$base: could not link. Enable Developer Mode, or run this script as Administrator."
        }
    }
}

# ------------------------------------------------------------ config files
Say "Writing config files"
foreach ($c in $M.configFiles) {
    $dest = Join-Path $UnixHome ($c.dest -replace '/', '\')
    if (Test-Path $dest) {
        Write-Host "    $($c.dest.PadRight(38)) already exists (not overwritten)" -ForegroundColor DarkGray
        continue
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    try {
        Invoke-WebRequest -Uri "$Raw/$($c.template)" -OutFile $dest -UseBasicParsing
        Write-Host "    $($c.dest.PadRight(38)) written" -ForegroundColor DarkGray
    } catch { Warn "$($c.dest): download failed" }
}

# opencode plugin dep
$ocDir = Join-Path $UnixHome '.config\opencode'
if (Test-Path (Join-Path $ocDir 'package.json')) {
    Say "Installing opencode plugin dependency"
    Push-Location $ocDir
    & npm install --silent 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn "npm install in ~/.config/opencode failed" }
    else { Write-Host "    node_modules installed" -ForegroundColor DarkGray }
    Pop-Location
}

# session dir, deliberately empty
New-Item -ItemType Directory -Force -Path "$UnixHome\.local\share\opencode" | Out-Null
Say "Created .local\share\opencode\ (empty — the 443MB session DB is intentionally not reproduced)"

# ------------------------------------------------------------ verify
Say "Verifying"
& powershell -NoProfile -ExecutionPolicy Bypass -Command `
    "irm $Raw/scripts/verify.ps1 | iex" 2>&1 | Out-String | Write-Host

Write-Host @'

------------------------------------------------------------------
Done. Open a NEW PowerShell window so the miniconda3 PATH change
takes effect, then re-run verification:

  irm https://raw.githubusercontent.com/c0a2302825/env-repro/main/scripts/verify.ps1 | iex
------------------------------------------------------------------
'@ -ForegroundColor Green

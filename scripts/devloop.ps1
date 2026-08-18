#!/usr/bin/env pwsh
# devloop.ps1 — CelMerge dev loop (Windows): deploy -> (launch) -> (watch)
#
# Deploy is a robocopy mirror of *.lua/*.json into
#   %APPDATA%\Aseprite\extensions\celmerge
# No zip round-trip, no build step (CelMerge is pure Lua).
#
# Usage:
#   .\scripts\devloop.ps1                          # deploy only (fast)
#   .\scripts\devloop.ps1 -Launch                  # deploy, then open Aseprite
#   .\scripts\devloop.ps1 -Launch -Sprite C:\tmp\test.aseprite
#   .\scripts\devloop.ps1 -Watch                   # redeploy on every file change
#
#   .\scripts\devloop.ps1 -Ref HEAD~3 -Launch      # deploy an older commit's build
#   .\scripts\devloop.ps1 -CleanWorktrees          # remove cached -Ref checkouts
#
# -Ref checks out the given commit/branch/tag into a disposable git worktree
# (under $env:TEMP\celmerge-devloop-worktrees, cached by short SHA) and deploys
# FROM THERE instead of the current working tree. Your working directory and
# current branch are untouched. Handy for bisecting a regression.
#
# Env overrides:
#   $env:ASEPRITE_BIN     path to Aseprite.exe (else auto-detected + cached)
#   $env:EXTENSIONS_DIR   target extension folder

[CmdletBinding()]
param(
    [switch]$Launch,
    [switch]$Watch,
    [string]$Sprite,
    [switch]$VerboseDeploy,
    [string]$Ref,
    [switch]$CleanWorktrees
)

$ErrorActionPreference = 'Stop'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectDir = Split-Path -Parent $ScriptDir
Set-Location $ProjectDir

# ── Defaults ─────────────────────────────────────────────────────────────────
$ExtensionsDir = if ($env:EXTENSIONS_DIR) { $env:EXTENSIONS_DIR }
                 else { Join-Path $env:APPDATA 'Aseprite\extensions\celmerge' }

function Log { param($m) Write-Host "[devloop] $m" }

# ── Historical commits: disposable git worktrees for -Ref ──────────────────────
$WorktreeRoot = Join-Path $env:TEMP 'celmerge-devloop-worktrees'

function Remove-CachedWorktrees {
    if (-not (Test-Path $WorktreeRoot)) { Log 'No cached worktrees.'; return }
    Push-Location $ProjectDir
    try {
        Get-ChildItem $WorktreeRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Log "Removing worktree: $($_.FullName)"
            git worktree remove --force $_.FullName 2>$null
        }
        git worktree prune 2>$null
    } finally { Pop-Location }
    Remove-Item $WorktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
    Log 'Cached worktrees removed.'
}

# Resolves $RefSpec to a commit and returns the path of a (cached) detached
# worktree checked out at that commit. Never touches the caller's own checkout.
function Resolve-RefWorktree {
    param([string]$RefSpec)
    Push-Location $ProjectDir
    try {
        $sha = (git rev-parse --verify "$RefSpec^{commit}" 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $sha) { throw "Unknown git ref: $RefSpec" }
        $sha = $sha.Trim()
        $short = $sha.Substring(0, 10)
        $wtPath = Join-Path $WorktreeRoot $short

        if (-not (Test-Path $wtPath)) {
            if (-not (Test-Path $WorktreeRoot)) { New-Item -ItemType Directory -Path $WorktreeRoot -Force | Out-Null }
            git worktree prune 2>$null | Out-Null
            Log "Creating worktree for $RefSpec ($short)..."
            git worktree add --detach $wtPath $sha | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git worktree add failed for $RefSpec" }
        } else {
            Log "Reusing cached worktree for $short"
        }

        $subject = (git log -1 --format='%h %s (%ci)' $sha)
        Log "Deploying commit: $subject"
        return $wtPath
    } finally { Pop-Location }
}

if ($CleanWorktrees) { Remove-CachedWorktrees; if (-not $Ref) { exit 0 } }
if ($Ref) { $ProjectDir = Resolve-RefWorktree -RefSpec $Ref }

# ── Resolve Aseprite binary (cached detector) ──────────────────────────────────
function Resolve-Aseprite {
    $bin = & (Join-Path $ScriptDir 'Find-Aseprite.ps1') -Quiet
    if ($LASTEXITCODE -ne 0 -or -not $bin) {
        throw 'Aseprite not found. Run scripts\Find-Aseprite.ps1 -Register, or set $env:ASEPRITE_BIN.'
    }
    return $bin.Trim()
}

# ── Deploy: robocopy -> extensions folder ──────────────────────────────────────
$FilePatterns = @('*.lua', '*.json')

function Invoke-Robocopy {
    param([string]$Src, [string]$Dst)
    $roboArgs = @($Src, $Dst) + $FilePatterns + @('/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    if (-not $VerboseDeploy) { $roboArgs += @('/NFL', '/NDL') }
    & robocopy.exe @roboArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($Src -> $Dst), exit $LASTEXITCODE" }
}

function Deploy {
    Log "Deploying to: $ExtensionsDir"
    if (-not (Test-Path $ExtensionsDir)) { New-Item -ItemType Directory -Path $ExtensionsDir -Force | Out-Null }
    Invoke-Robocopy -Src $ProjectDir -Dst $ExtensionsDir
    $global:LASTEXITCODE = 0   # robocopy's success codes leak into $LASTEXITCODE
    Log 'Deploy done.'
}

# ── Run ──────────────────────────────────────────────────────────────────────
Deploy

if ($Launch) {
    $bin = Resolve-Aseprite
    $spriteArg = if ($Sprite) { (Resolve-Path $Sprite).Path } else { $null }
    Log 'Launching Aseprite...'
    if ($spriteArg) { Start-Process $bin -ArgumentList $spriteArg | Out-Null }
    else            { Start-Process $bin | Out-Null }
    Log 'If Aseprite was already running, close that instance first -- extensions only reload on launch.'
}

# ── Watch: redeploy on any source change (Ctrl-C to stop) ───────────────────────
if ($Watch) {
    Log 'Watching for changes (Ctrl-C to stop)...'
    $fsw = New-Object System.IO.FileSystemWatcher $ProjectDir, '*.*'
    $fsw.IncludeSubdirectories = $true
    $fsw.EnableRaisingEvents = $true
    try {
        while ($true) {
            $change = $fsw.WaitForChanged([System.IO.WatcherChangeTypes]::All, 1000)
            if ($change.TimedOut) { continue }
            $name = $change.Name
            if ($name -match '\.(lua|json)$' -and $name -notmatch '\\\.git\\') {
                Log "Changed: $name"
                Start-Sleep -Milliseconds 150   # let the writer finish
                Deploy
            }
        }
    } finally { $fsw.Dispose() }
}

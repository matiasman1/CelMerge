#!/usr/bin/env pwsh
# create_extension.ps1 — package CelMerge into a distributable .aseprite-extension
#
# Usage:
#   .\create_extension.ps1                  # keep current version, zip it
#   .\create_extension.ps1 -Auto             # auto-increment patch version
#   .\create_extension.ps1 -Version 1.2.0    # set a specific version
#   .\create_extension.ps1 -DryRun           # show what would happen, change nothing

param(
    [switch]$Auto,
    [string]$Version,
    [switch]$DryRun,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir

function Log { param($m) if (-not $Quiet) { Write-Host $m } }
function Log-Success { param($m) if (-not $Quiet) { Write-Host $m -ForegroundColor Green } }

# ── Version management ──────────────────────────────────────────────────────
$pkg = Get-Content package.json -Raw | ConvertFrom-Json
$current = $pkg.version
$newVersion = $current

if ($Version) {
    $newVersion = $Version
} elseif ($Auto) {
    if ($current -match '^(\d+)\.(\d+)\.(\d+)$') {
        $newVersion = "$($matches[1]).$($matches[2]).$([int]$matches[3] + 1)"
    } else {
        throw "Current version '$current' is not MAJOR.MINOR.PATCH"
    }
}

if ($newVersion -ne $current) {
    Log "Version: $current -> $newVersion"
    if (-not $DryRun) {
        $pkg.version = $newVersion
        $pkg | ConvertTo-Json -Depth 10 | Set-Content package.json
    }
} else {
    Log "Version: $current (unchanged)"
}

# ── Package ──────────────────────────────────────────────────────────────────
$EXT = 'CelMerge'
$tempZip = Join-Path $scriptDir "$EXT.zip"
$outFile = Join-Path $scriptDir "$EXT.aseprite-extension"

foreach ($f in @($tempZip, $outFile)) {
    if (Test-Path $f) {
        if (-not $DryRun) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        else { Log "[DRY-RUN] Would remove $f" }
    }
}

# Root .lua/.json files only -- CelMerge has no subdirectories to package yet.
$files = Get-ChildItem -Path $scriptDir -File | Where-Object { $_.Extension -in @('.lua', '.json') }
if ($files.Count -eq 0) { throw 'No .lua/.json files found to package' }

if ($DryRun) {
    Log "[DRY-RUN] Would package: $($files.Name -join ', ')"
    exit 0
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($tempZip, 'Create')
try {
    foreach ($file in $files) {
        Log "Adding: $($file.Name)"
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $file.Name) | Out-Null
    }
} finally { $zip.Dispose() }

Rename-Item -Path $tempZip -NewName (Split-Path $outFile -Leaf) -Force
Log-Success "$EXT.aseprite-extension created (version $newVersion)"

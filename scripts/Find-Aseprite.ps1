#!/usr/bin/env pwsh
# Find-Aseprite.ps1 — locate the Aseprite executable on Windows.
#
# Detection order (first hit wins):
#   1. $env:ASEPRITE_BIN                          (explicit override)
#   2. scripts\.aseprite-bin                      (cached result, unless -Refresh)
#   3. aseprite[.exe] on PATH                     (Get-Command)
#   4. Registry Uninstall keys (DisplayName ~ Aseprite)
#   5. Steam: libraryfolders.vdf -> common\Aseprite\Aseprite.exe
#   6. Common fixed install locations
#
# Usage:
#   $bin = & scripts\Find-Aseprite.ps1            # prints/returns the path
#   & scripts\Find-Aseprite.ps1 -Register         # also add its folder to user PATH
#   & scripts\Find-Aseprite.ps1 -Refresh          # ignore cache and re-scan
#
# Can also be dot-sourced to import Find-AsepriteBinary / Register-AsepriteOnPath.

[CmdletBinding()]
param(
    [switch]$Register,   # persist the install dir to the user PATH (and write cache)
    [switch]$Refresh,    # ignore the cache file and re-detect
    [switch]$Quiet       # suppress the human-readable status line on stderr
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$CacheFile = Join-Path $ScriptDir '.aseprite-bin'

function Write-Status { param($m) if (-not $Quiet) { [Console]::Error.WriteLine("[find-aseprite] $m") } }

function Get-SteamLibraryPaths {
    $steam = (Get-ItemProperty 'HKCU:\SOFTWARE\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) {
        $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
    }
    if (-not $steam) { return @() }
    $steam = $steam -replace '/', '\'
    $paths = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        # Lines look like:  "path"   "D:\\SteamLibrary"
        Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches |
            ForEach-Object { $_.Matches } |
            ForEach-Object { $paths += ($_.Groups[1].Value -replace '\\\\', '\') }
    }
    $paths | Select-Object -Unique
}

function Find-AsepriteBinary {
    [CmdletBinding()]
    param([switch]$Refresh)

    # 1. Explicit override -------------------------------------------------------
    if ($env:ASEPRITE_BIN -and (Test-Path $env:ASEPRITE_BIN)) {
        return (Resolve-Path $env:ASEPRITE_BIN).Path
    }

    # 2. Cache -------------------------------------------------------------------
    if (-not $Refresh -and (Test-Path $CacheFile)) {
        $cached = (Get-Content $CacheFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($cached -and (Test-Path $cached)) { return $cached }
    }

    # 3. PATH --------------------------------------------------------------------
    $onPath = Get-Command aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    # 4. Registry uninstall keys -------------------------------------------------
    $uninstall = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($entry in (Get-ItemProperty $uninstall -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Aseprite' })) {
        foreach ($cand in @(
                (Join-Path $entry.InstallLocation 'Aseprite.exe'),
                ($entry.DisplayIcon -replace ',.*$', ''))) {
            if ($cand -and (Test-Path $cand)) { return (Resolve-Path $cand).Path }
        }
    }

    # 5. Steam libraries ---------------------------------------------------------
    foreach ($lib in (Get-SteamLibraryPaths)) {
        $cand = Join-Path $lib 'steamapps\common\Aseprite\Aseprite.exe'
        if (Test-Path $cand) { return (Resolve-Path $cand).Path }
    }

    # 6. Common fixed locations --------------------------------------------------
    foreach ($cand in @(
            "$env:ProgramFiles\Aseprite\Aseprite.exe",
            "${env:ProgramFiles(x86)}\Aseprite\Aseprite.exe",
            "$env:LOCALAPPDATA\Aseprite\Aseprite.exe")) {
        if (Test-Path $cand) { return (Resolve-Path $cand).Path }
    }

    return $null
}

function Register-AsepriteOnPath {
    param([Parameter(Mandatory)][string]$BinPath)

    # Write the resolved path to the cache file so future lookups are instant.
    Set-Content -Path $CacheFile -Value $BinPath -Encoding ASCII -NoNewline
    Write-Status "Cached -> $CacheFile"

    # Add the install directory to the *user* PATH (idempotent, persistent).
    $dir = Split-Path -Parent $BinPath
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($userPath) { $parts = $userPath -split ';' | Where-Object { $_ } }
    if ($parts -notcontains $dir) {
        $newPath = (@($parts) + $dir) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Status "Added to user PATH: $dir (open a new shell to pick it up globally)"
    } else {
        Write-Status "Already on user PATH: $dir"
    }
    # Make it usable in the current session too.
    if (($env:PATH -split ';') -notcontains $dir) { $env:PATH = "$env:PATH;$dir" }
}

# ── Main (skip when dot-sourced: $MyInvocation.InvocationName is '.') ───────────
if ($MyInvocation.InvocationName -ne '.') {
    $bin = Find-AsepriteBinary -Refresh:$Refresh
    if (-not $bin) {
        Write-Status 'ERROR: Aseprite not found. Set $env:ASEPRITE_BIN to the .exe path.'
        exit 1
    }
    Write-Status "Found: $bin"
    if ($Register) { Register-AsepriteOnPath -BinPath $bin }
    elseif (-not (Test-Path $CacheFile)) {
        # First successful detection: seed the cache so repeat runs skip scanning.
        Set-Content -Path $CacheFile -Value $bin -Encoding ASCII -NoNewline
    }
    Write-Output $bin
}

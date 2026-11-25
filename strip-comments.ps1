# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Khvor' Gates contributors
# Strips every comment from Rust sources with rmcm while keeping the licence and provenance block that opens each file, and leaving generated files alone.
param([Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$Paths)

$ErrorActionPreference = 'Stop'
$rmcm = (Resolve-Path (Join-Path $PSScriptRoot '..\..\rmcm.exe')).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

$files = foreach ($p in $Paths) {
    if (Test-Path $p -PathType Container) {
        Get-ChildItem $p -Recurse -File -Filter *.rs | Where-Object { $_.FullName -notmatch '[\\/](target|bindings|module_bindings|MarchingSquaresTerrain|tmp-[^\\/]*)[\\/]|[\\/]server[\\/]build[\\/]' }
    } else { Get-Item $p }
}

$changed = 0
foreach ($f in $files) {
    $before = [System.IO.File]::ReadAllText($f.FullName, $utf8)
    if ($before -match 'AUTOMATICALLY GENERATED') { continue }
    $lines = $before -split "`r?`n"
    $keep = @()
    if ($lines.Count -gt 0 -and $lines[0] -match '^//\s*SPDX-License-Identifier') {
        foreach ($l in $lines) { if ($l -match '^//([^/!]|$)') { $keep += $l } else { break } }
    }
    & $rmcm -i -c 1 $f.FullName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "rmcm failed on $($f.FullName)" }
    $body = [System.IO.File]::ReadAllText($f.FullName, $utf8).TrimStart("`r", "`n")
    $text = if ($keep.Count) { ($keep -join "`n") + "`n`n" + $body } else { $body }
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    if ($before.Contains("`r`n")) { $text = $text -replace "(?<!`r)`n", "`r`n" }
    [System.IO.File]::WriteAllText($f.FullName, $text, $utf8)
    if ($text -ne $before) { $changed++ }
}
Write-Output "files=$(@($files).Count) changed=$changed"

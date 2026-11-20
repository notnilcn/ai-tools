# SPDX-License-Identifier: GPL-3.0-only
#
# twin_verify.ps1 - Windows launcher for twin_verify.py.
#
#   .\twin_verify.ps1 check
#   .\twin_verify.ps1 next
#   .\twin_verify.ps1 set-status TWIN-0001 reference-verified

$ErrorActionPreference = 'Stop'

$Python = Get-Command python -ErrorAction SilentlyContinue
$PythonArgs = @()
if (-not $Python) {
    $Python = Get-Command py -ErrorAction SilentlyContinue
    if ($Python) { $PythonArgs = @('-3') }
}
if (-not $Python) {
    [Console]::Error.WriteLine('twin_verify.ps1: Python 3 is required (python or py -3)')
    exit 2
}

$Script = Join-Path $PSScriptRoot 'twin_verify.py'
& $Python.Source @PythonArgs $Script @args
exit $LASTEXITCODE

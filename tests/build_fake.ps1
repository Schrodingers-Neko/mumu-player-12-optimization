param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
# Compile using Windows PowerShell's .NET Framework so the fake runs under both hosts.
Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'FakeNative.cs') -Raw) -OutputAssembly $OutputPath -OutputType ConsoleApplication

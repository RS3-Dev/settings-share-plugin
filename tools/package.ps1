param([string]$OutputPath, [switch]$Debug)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$pluginRoot = if ($Debug) { Join-Path $repositoryRoot 'examples/settingssharedebug' } else { $repositoryRoot }
$manifest = Get-Content -LiteralPath (Join-Path $pluginRoot 'plugin.json') -Raw | ConvertFrom-Json
if (-not $OutputPath) {
    $OutputPath = Join-Path $repositoryRoot ('artifacts/' + $manifest.name + '-' + $manifest.version + '.zip')
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
# The upload format requires main.lua and plugin.json at the ZIP root.
$packageFiles = @((Join-Path $pluginRoot 'main.lua'), (Join-Path $pluginRoot 'plugin.json'))
if (Test-Path -LiteralPath (Join-Path $pluginRoot 'lib')) { $packageFiles += (Join-Path $pluginRoot 'lib') }
Compress-Archive -Path $packageFiles -DestinationPath $OutputPath -Force
Write-Output $OutputPath

param([string]$BuildRoot = '', [switch]$Test)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/pscompat.ps1')
Assert-PowerShell7
Set-Utf8Console
$backendWorkspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (!$BuildRoot) { $BuildRoot = Join-Path ([IO.Path]::GetTempPath()) ('ict_backend_app_' + (Get-Date -Format 'yyyyMMddTHHmmssfff') + '_' + $PID) }
if ($BuildRoot -match '[^\x00-\x7F]') { throw 'BuildRoot must be ASCII.' }
$auditDir = Join-Path $backendWorkspace ('audit/backend/' + (Get-Date -Format 'yyyyMMddTHHmmssfff') + '_build')
New-Item -ItemType Directory -Path $BuildRoot,$auditDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $backendWorkspace 'src/cj_zh_search') -Destination (Join-Path $BuildRoot 'cj_zh_search') -Recurse
Copy-Item -LiteralPath $PSScriptRoot -Destination (Join-Path $BuildRoot 'backend') -Recurse
$stdx = Join-Path $backendWorkspace 'artifacts/stage1/probes/dependencies/cangjie-stdx-windows-x64-1.0.5.1/windows_x86_64_cjnative/dynamic/stdx'
Copy-Item -LiteralPath $stdx -Destination (Join-Path $BuildRoot 'stdx') -Recurse
$stdx = Join-Path $BuildRoot 'stdx'
. 'C:/Program Files (x86)/Cangjie/envsetup.ps1'
$queue = [Collections.Generic.Queue[string]]::new()
$libs = [Collections.Generic.HashSet[string]]::new()
$queue.Enqueue('stdx.net.http'); $queue.Enqueue('stdx.encoding.json')
while ($queue.Count) {
    $pkg = $queue.Dequeue()
    if (!$libs.Add($pkg)) { continue }
    $scan = & cjc --scan-dependency (Join-Path $stdx ($pkg + '.cjo'))
    if ($LASTEXITCODE) { throw 'stdx dependency scan failed' }
    foreach ($dep in ($scan | ConvertFrom-Json).dependencies) { if (!$dep.isStd) { $queue.Enqueue($dep.package) } }
}
# Structured TOML data is generated only in the task-specific build copy.
$configPath = Join-Path $BuildRoot 'backend/cjpm.toml'
$config = Read-Utf8Text $configPath
$links = ($libs | Sort-Object | ForEach-Object { '-l' + $_ }) -join ' '
$options = "compile-option = '--import-path `"" + $stdx.Replace('\','/') + "`"'`nlink-option = '-L`"" + $stdx.Replace('\','/') + "`" " + $links + "'`n"
$config = $config.Replace('[dependencies]',($options + "`n[dependencies]"))
$target = 'x86_64-w64-mingw32'
$config += "`n[target.x86_64-w64-mingw32.bin-dependencies.package-option]`n"
foreach ($lib in ($libs | Sort-Object)) { $config += '"' + $lib + '" = "' + (Join-Path $stdx ($lib + '.cjo')).Replace('\','/') + '"' + "`n" }
Write-Utf8NoBom $configPath $config
$env:Path = $stdx + ';' + $env:Path
$env:ICT_DATA = Join-Path $backendWorkspace 'src/data/synthetic.runtime.json'
$commands = @('build')
if ($Test) { $commands += 'test' }
$steps = @()
foreach ($command in $commands) {
    Push-Location (Join-Path $BuildRoot 'backend')
    try { $out = @(& cjpm $command 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE } finally { Pop-Location }
    Write-Utf8NoBom (Join-Path $auditDir ($command + '.log')) ($out -join [Environment]::NewLine)
    $steps += @{command=('cjpm ' + $command);exitCode=$code;output=$out}
    $out | ForEach-Object { Write-Host $_ }
    if ($code) { break }
}
$result = @{buildRoot=$BuildRoot;audit=$auditDir;target=$target;stdx='1.0.5.1';libraries=@($libs);steps=$steps;completedAt=(Get-Date -Format o);shell=(Get-HostShellLabel);psVersion=$PSVersionTable.PSVersion.ToString()}
Write-JsonFile (Join-Path $auditDir 'result.json') $result 8
Write-Output ('BuildRoot=' + $BuildRoot + ' Audit=' + $auditDir + ' exit=' + $code)
if ($code) { exit $code }
New-Item -ItemType Directory -Path (Join-Path $backendWorkspace 'temp/backend') -Force | Out-Null
Write-JsonFile (Join-Path $backendWorkspace 'temp/backend/latest-build.json') $result 8

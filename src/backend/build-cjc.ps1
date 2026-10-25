param([string]$BuildRoot = '', [switch]$Test, [string]$AuditDir = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/pscompat.ps1')
Set-Utf8Console

# Fallback build path that bypasses cjpm.
#
# Reason: cjpm 1.0.5 exits with 0xC0000005 / 0xC0000374 in non-interactive sessions
# (see audit/backend/week7_repair_20261024/repair_report.md, finding N-01), while cjc
# in the same session compiles and links the same sources correctly. This script
# reproduces what cjpm build/test would do, using cjc directly, so that compilation
# stays verifiable. It does not replace cjpm when cjpm works.
#
# Output contract mirrors build.ps1: an audit directory with result.json and per-step logs.

$backendWorkspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (!$BuildRoot) { $BuildRoot = Join-Path ([IO.Path]::GetTempPath()) ('ict_cjc_' + (Get-Date -Format 'yyyyMMddTHHmmssfff') + '_' + $PID) }
if ($BuildRoot -match '[^\x00-\x7F]') { throw 'BuildRoot must be ASCII.' }
if (!$AuditDir) { $AuditDir = Join-Path $backendWorkspace ('audit/backend/' + (Get-Date -Format 'yyyyMMddTHHmmssfff') + '_build_cjc') }
New-Item -ItemType Directory -Path $BuildRoot, $AuditDir -Force | Out-Null

$cangjieHome = 'C:\Program Files (x86)\Cangjie'
$envsetup = Join-Path $cangjieHome 'envsetup.ps1'
if (Test-Path $envsetup) { . $envsetup }
$cjc = (Get-Command cjc -ErrorAction SilentlyContinue).Source
if (!$cjc) {
    $candidate = Join-Path $cangjieHome 'bin/cjc.exe'
    if (Test-Path $candidate) { $cjc = $candidate } else { throw 'cjc not found. Install the Cangjie toolchain or run Cangjie envsetup.ps1 first.' }
}

$steps = @()
function Invoke-Step([string]$name, [string]$workdir, [scriptblock]$action) {
    Push-Location $workdir
    try { $out = @(& $action 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE } finally { Pop-Location }
    Write-Utf8NoBom (Join-Path $AuditDir ($name + '.log')) ($out -join [Environment]::NewLine)
    $script:steps += @{ name = $name; exitCode = $code; outputLines = $out.Count; log = ($name + '.log') }
    $out | ForEach-Object { Write-Host $_ }
    if ($code) { throw ($name + ' failed with exit code ' + $code) }
}

# Task-local copies keep the workspace clean and the build root ASCII.
#
# Reusing a BuildRoot is the documented way to keep artifacts across runs, but
# Copy-Item -Destination <existing directory> copies the source INTO that directory.
# On a second run that produced $BuildRoot/backend/backend, left $BuildRoot/backend/src
# untouched, and the compiler then built the PREVIOUS run's sources while the script
# reported success. Remove the destinations first, then verify the copy really matches
# the workspace before compiling anything.
$depCopy = Join-Path $BuildRoot 'cj_zh_search'
$backendCopy = Join-Path $BuildRoot 'backend'
foreach ($stale in @($depCopy, $backendCopy)) {
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Recurse -Force }
}
Copy-Item -LiteralPath (Join-Path $backendWorkspace 'src/cj_zh_search') -Destination $depCopy -Recurse
Copy-Item -LiteralPath $PSScriptRoot -Destination $backendCopy -Recurse
$sourceNames = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter *.cj | ForEach-Object { $_.Name } | Sort-Object)
$copyNames = @(Get-ChildItem -LiteralPath (Join-Path $backendCopy 'src') -Filter *.cj | ForEach-Object { $_.Name } | Sort-Object)
if (($sourceNames -join ',') -ne ($copyNames -join ',')) {
    throw ('Source copy does not match the workspace. workspace=' + ($sourceNames -join ',') + ' copy=' + ($copyNames -join ','))
}
$stdxSource = Join-Path $backendWorkspace 'artifacts/stage1/probes/dependencies/cangjie-stdx-windows-x64-1.0.5.1/windows_x86_64_cjnative/dynamic/stdx'
if (!(Test-Path $stdxSource)) { throw ('stdx dependency not found: ' + $stdxSource) }
# Same nesting hazard as the source copy: remove first so the linked libraries and the
# runtime DLL directory are the ones this run copied.
$stdx = Join-Path $BuildRoot 'stdx'
if (Test-Path -LiteralPath $stdx) { Remove-Item -LiteralPath $stdx -Recurse -Force }
Copy-Item -LiteralPath $stdxSource -Destination $stdx -Recurse
$pkgOut = Join-Path $BuildRoot 'pkgout'
New-Item -ItemType Directory -Path $pkgOut -Force | Out-Null
$env:Path = $stdx + ';' + $pkgOut + ';' + (Split-Path $cjc) + ';' + $env:Path

# Dependency package: compile the sources directly. cjc -p <dir> silently produced no
# artifacts in 1.0.5, so the file list is passed explicitly.
$depSources = @(
    (Join-Path $BuildRoot 'cj_zh_search/src/search.cj'),
    (Join-Path $BuildRoot 'cj_zh_search/src/search_bench.cj')
)
Invoke-Step 'dep' $pkgOut {
    & $cjc "--import-path=$stdx" "-L$stdx" '-lstdx.encoding.json' '--output-type=staticlib' '-o' (Join-Path $pkgOut 'libcj_zh_search.a') @depSources
}

$libs = @(Get-ChildItem $stdx -Filter 'stdx.*.cjo' | ForEach-Object { '-l' + $_.BaseName })
$src = Join-Path $BuildRoot 'backend/src'
$prodSources = @(Get-ChildItem $src -Filter *.cj | Where-Object { $_.Name -notlike '*_test.cj' } | ForEach-Object { $_.FullName })
$allSources = @(Get-ChildItem $src -Filter *.cj | ForEach-Object { $_.FullName })
$mainExe = Join-Path $BuildRoot 'main.exe'

Invoke-Step 'build' $src {
    & $cjc "--import-path=$stdx" "--import-path=$pkgOut" "-L$stdx" "-L$pkgOut" @libs '-lcj_zh_search' '--output-type=exe' '-o' $mainExe @prodSources
}

$testExe = $null
if ($Test) {
    $testExe = Join-Path $BuildRoot 'tests.exe'
    Invoke-Step 'test-compile' $src {
        & $cjc --test "--import-path=$stdx" "--import-path=$pkgOut" "-L$stdx" "-L$pkgOut" @libs '-lcj_zh_search' '-o' $testExe @allSources
    }
    $env:ICT_DATA = Join-Path $backendWorkspace 'src/data/synthetic.runtime.json'
    $env:ICT_STORE = Join-Path $BuildRoot 'test_store.json'
    Invoke-Step 'test-run' $BuildRoot { & $testExe }
}

$cjpmProbe = $null
$cjpm = (Get-Command cjpm -ErrorAction SilentlyContinue).Source
if ($cjpm) {
    Push-Location $BuildRoot
    try { $null = @(& $cjpm --version 2>&1); $cjpmProbe = $LASTEXITCODE } finally { Pop-Location }
}

# Publish the executable where start.ps1 and verify.ps1 look for it.
#
# build.ps1 gets $BuildRoot/backend/target/release/bin/main.exe for free from cjpm's
# layout. The cjc channel writes main.exe at $BuildRoot, so without this step
# "build with cjc, then start/verify" fails with 'Cannot resolve backend executable'
# even though the build succeeded. Publishing here keeps one documented chain.
$publishedDir = Join-Path $BuildRoot 'backend/target/release/bin'
New-Item -ItemType Directory -Path $publishedDir -Force | Out-Null
$publishedExe = Join-Path $publishedDir 'main.exe'
Copy-Item -LiteralPath $mainExe -Destination $publishedExe -Force
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $publishedExe).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $mainExe).Hash) {
    throw 'Published executable does not match the built executable.'
}

# Unit-test counts are read back from the run log instead of being hard-coded.
# The test runner colourises its summary, so ANSI escapes sit between the label and the
# colon ("\e[32mPASSED\e[0m: 28"). Strip them first or the match silently fails and the
# count is recorded as null, which reads like a missing result rather than a parse bug.
$unitTests = $null
if ($testExe) {
    $testLog = Join-Path $AuditDir 'test-run.log'
    if (Test-Path -LiteralPath $testLog) {
        $text = [regex]::Replace((Get-Content -LiteralPath $testLog -Raw), "`e\[[0-9;]*m", '')
        if ($text -match 'PASSED:\s*(\d+),\s*SKIPPED:\s*(\d+),\s*ERROR:\s*(\d+)') {
            $passed = [int]$matches[1]; $skipped = [int]$matches[2]; $errors = [int]$matches[3]
            $failed = 0
            if ($text -match 'FAILED:\s*(\d+)') { $failed = [int]$matches[1] }
            $unitTests = @{ total = $passed + $skipped + $errors + $failed; passed = $passed; skipped = $skipped; error = $errors; failed = $failed }
        } else {
            Write-Warning ('Could not read unit-test counts from ' + $testLog)
        }
    }
}

$result = @{
    buildRoot       = $BuildRoot
    audit           = $AuditDir
    builder         = 'cjc'
    builderReason   = 'cjpm 1.0.5 crashes in non-interactive sessions (N-01); cjc compiles the same sources.'
    cjc             = $cjc
    cjpmVersionExit = $cjpmProbe
    target          = 'x86_64-w64-mingw32'
    stdx            = '1.0.5.1'
    libraries       = $libs
    steps           = $steps
    mainExe         = @{ path = $mainExe; bytes = (Get-Item $mainExe).Length; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $mainExe).Hash.ToLower() }
    testExe         = $(if ($testExe) { @{ path = $testExe; bytes = (Get-Item $testExe).Length; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $testExe).Hash.ToLower() } } else { $null })
    shell           = (Get-HostShellLabel)
    psVersion       = $PSVersionTable.PSVersion.ToString()
    completedAt     = (Get-Date -Format o)
}
Write-JsonFile (Join-Path $AuditDir 'result.json') $result 8
# latest-build.json is the handoff start.ps1 and verify.ps1 read. build.ps1 writes it too;
# the cjc channel must write the same contract or the chain breaks at the next step.
$latestPath = Join-Path $backendWorkspace 'temp/backend/latest-build.json'
$previousBuild = $null
if (Test-Path -LiteralPath $latestPath) {
    $previous = Read-JsonFile $latestPath
    if ($previous.mainExe -and $previous.mainExe.sha256) { $previousBuild = $previous.mainExe.sha256 }
}
Write-JsonFile $latestPath @{
    schema          = 'ict-build-v1'
    builder         = 'cjc'
    builderReason   = 'cjpm 1.0.5 crashes in non-interactive sessions (N-01); cjc compiles the same sources.'
    buildRoot       = $BuildRoot
    audit           = $AuditDir
    mainExe         = @{ path = $publishedExe; bytes = (Get-Item $publishedExe).Length; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $publishedExe).Hash.ToLower() }
    unitTests       = $unitTests
    cjpmVersionExit = $cjpmProbe
    previousBuild   = $previousBuild
    completedAt     = (Get-Date -Format o)
} 8
Write-Output ('BuildRoot=' + $BuildRoot + ' Audit=' + $AuditDir + ' cjpmVersionExit=' + $cjpmProbe)
Write-Output ('main.exe bytes=' + $result.mainExe.bytes + ' sha256=' + $result.mainExe.sha256)
if ($testExe) { Write-Output ('tests.exe bytes=' + $result.testExe.bytes + ' sha256=' + $result.testExe.sha256) }
Write-Output ('published=' + $publishedExe)

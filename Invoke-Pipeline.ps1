<#
.SYNOPSIS
    Executes the full PowerStig CI/CD pipeline in air-gapped mode.

.DESCRIPTION
    Top-level pipeline orchestrator. Runs every stage end-to-end without
    requiring GitHub Actions, Azure Pipelines, or any internet connectivity.

    Stages (in order):
        Initialize    - Validate environment and set up local PSRepository
        Resolve       - Install build-time dependencies from local feed
        Build         - Compile and package the module
        TestHQRM      - Run High Quality Resource Module tests
        TestUnit      - Run Pester unit tests with code coverage
        TestIntegration - Run integration tests (requires WinRM + elevation)
        Package       - Create NuGet .nupkg for distribution
        Publish       - Copy artifacts to the local release store

.PARAMETER StartStage
    Stage to begin from. Useful when resuming a partial run.
    Valid values: Initialize, Resolve, Build, TestHQRM, TestUnit,
                  TestIntegration, Package, Publish
    Default: Initialize

.PARAMETER EndStage
    Stage to stop after (inclusive).
    Default: Publish

.PARAMETER SkipIntegrationTests
    Skip the TestIntegration stage. Use when WinRM is not configured
    or when running without elevated privileges.

.PARAMETER LocalFeedPath
    Path to the pre-bundled .nupkg directory.
    Default: .\Artifacts\LocalFeed

.PARAMETER FeedName
    PSRepository name for the local feed.
    Default: LocalPSStig

.PARAMETER PublishPath
    Local directory to copy completed release artifacts into.
    Default: .\Artifacts\Releases

.PARAMETER ModuleVersion
    Override the computed module version. When omitted, GitVersion is used
    if available; otherwise falls back to the version in source\PowerStig.psd1.

.PARAMETER Clean
    Remove the output\ directory before building.

.PARAMETER WhatIf
    Show what each stage would do without executing.

.EXAMPLE
    .\Invoke-Pipeline.ps1

.EXAMPLE
    .\Invoke-Pipeline.ps1 -SkipIntegrationTests

.EXAMPLE
    .\Invoke-Pipeline.ps1 -StartStage Build -EndStage TestUnit

.EXAMPLE
    .\Invoke-Pipeline.ps1 -ModuleVersion '4.30.0' -Clean
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter()]
    [ValidateSet('Initialize', 'Resolve', 'Build', 'TestHQRM', 'TestUnit', 'TestIntegration', 'Package', 'Publish')]
    [string]$StartStage = 'Initialize',

    [Parameter()]
    [ValidateSet('Initialize', 'Resolve', 'Build', 'TestHQRM', 'TestUnit', 'TestIntegration', 'Package', 'Publish')]
    [string]$EndStage = 'Publish',

    [Parameter()]
    [switch]$SkipIntegrationTests,

    [Parameter()]
    [string]$LocalFeedPath = (Join-Path $PSScriptRoot 'Artifacts\LocalFeed'),

    [Parameter()]
    [string]$FeedName = 'LocalPSStig',

    [Parameter()]
    [string]$PublishPath = (Join-Path $PSScriptRoot 'Artifacts\Releases'),

    [Parameter()]
    [string]$ModuleVersion,

    [Parameter()]
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Set-StrictMode -Version Latest

#region ── Pipeline Infrastructure ─────────────────────────────────────────────

$Script:PipelineRoot    = $PSScriptRoot
$Script:ArtifactsRoot   = Join-Path $PSScriptRoot 'Artifacts'
$Script:OutputDir       = Join-Path $PSScriptRoot 'output'
$Script:TestResultsDir  = Join-Path $PSScriptRoot 'Artifacts\TestResults'
$Script:StageOrder      = @('Initialize','Resolve','Build','TestHQRM','TestUnit','TestIntegration','Package','Publish')
$Script:StartTime       = [datetime]::UtcNow
$Script:StageResults    = [ordered]@{}

function Get-StageIndex { param([string]$Stage) $Script:StageOrder.IndexOf($Stage) }

function Write-Banner {
    param([string]$Title, [string]$Color = 'Cyan')
    $bar = '=' * 72
    Write-Host ''
    Write-Host $bar -ForegroundColor $Color
    Write-Host "  $Title" -ForegroundColor $Color
    Write-Host $bar -ForegroundColor $Color
}

function Write-StageHeader {
    param([string]$Name, [int]$Index, [int]$Total)
    Write-Host ''
    Write-Host ('-' * 72) -ForegroundColor DarkCyan
    Write-Host "  STAGE [$Index/$Total] : $Name" -ForegroundColor Cyan
    Write-Host "  Started : $(([datetime]::UtcNow).ToString('HH:mm:ss')) UTC" -ForegroundColor DarkGray
    Write-Host ('-' * 72) -ForegroundColor DarkCyan
}

function Complete-Stage {
    param([string]$Name, [bool]$Success, [string]$Detail = '')
    $elapsed = ([datetime]::UtcNow - $Script:StageStart).TotalSeconds
    $Script:StageResults[$Name] = @{
        Success = $Success
        Elapsed = $elapsed
        Detail  = $Detail
    }
    if ($Success) {
        Write-Host "  [PASS] $Name - completed in $([math]::Round($elapsed,1))s" -ForegroundColor Green
    }
    else {
        Write-Host "  [FAIL] $Name - failed after $([math]::Round($elapsed,1))s : $Detail" -ForegroundColor Red
    }
}

function Invoke-Stage {
    param(
        [string]$Name,
        [int]$Index,
        [int]$Total,
        [scriptblock]$Action
    )

    $startIdx = Get-StageIndex $StartStage
    $endIdx   = Get-StageIndex $EndStage
    $thisIdx  = Get-StageIndex $Name

    # Skip stages outside the requested window
    if ($thisIdx -lt $startIdx -or $thisIdx -gt $endIdx) {
        $Script:StageResults[$Name] = @{ Success = $true; Elapsed = 0; Detail = 'skipped' }
        return
    }

    # Skip integration tests when requested
    if ($Name -eq 'TestIntegration' -and $SkipIntegrationTests) {
        Write-Host "`n  [SKIP] $Name (SkipIntegrationTests specified)" -ForegroundColor DarkYellow
        $Script:StageResults[$Name] = @{ Success = $true; Elapsed = 0; Detail = 'skipped by parameter' }
        return
    }

    Write-StageHeader -Name $Name -Index $Index -Total $Total
    $Script:StageStart = [datetime]::UtcNow

    try {
        if ($PSCmdlet.ShouldProcess($Name, 'Execute pipeline stage')) {
            & $Action
        }
        Complete-Stage -Name $Name -Success $true
    }
    catch {
        Complete-Stage -Name $Name -Success $false -Detail $_.Exception.Message
        Write-Host ''
        Write-Host "  Error detail: $_" -ForegroundColor Red
        Write-Host "  Stack trace:`n$($_.ScriptStackTrace)" -ForegroundColor DarkGray
        Write-PipelineSummary
        exit 1
    }
}

function Write-PipelineSummary {
    $total   = ([datetime]::UtcNow - $Script:StartTime).TotalSeconds
    Write-Banner "Pipeline Summary  ($(([datetime]::UtcNow).ToString('yyyy-MM-dd HH:mm')) UTC)" 'Cyan'
    foreach ($stage in $Script:StageOrder) {
        if (-not $Script:StageResults.Contains($stage)) { continue }
        $r = $Script:StageResults[$stage]
        if ($r.Detail -eq 'skipped' -or $r.Detail -eq 'skipped by parameter') {
            Write-Host ("  {0,-20} {1}" -f $stage, 'SKIPPED') -ForegroundColor DarkGray
        }
        elseif ($r.Success) {
            Write-Host ("  {0,-20} {1,8}s  PASS" -f $stage, [math]::Round($r.Elapsed, 1)) -ForegroundColor Green
        }
        else {
            Write-Host ("  {0,-20} {1,8}s  FAIL  {2}" -f $stage, [math]::Round($r.Elapsed, 1), $r.Detail) -ForegroundColor Red
        }
    }
    Write-Host ('-' * 72) -ForegroundColor DarkGray
    Write-Host ("  Total elapsed : $([math]::Round($total,1))s") -ForegroundColor Cyan
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-Build {
    param([string[]]$Tasks, [hashtable]$Env = @{})
    $prevEnv = @{}
    foreach ($k in $Env.Keys) {
        $prevEnv[$k] = [System.Environment]::GetEnvironmentVariable($k)
        [System.Environment]::SetEnvironmentVariable($k, $Env[$k])
    }
    try {
        & (Join-Path $PSScriptRoot 'build.ps1') -Tasks $Tasks
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "build.ps1 exited with code $LASTEXITCODE"
        }
    }
    finally {
        foreach ($k in $prevEnv.Keys) {
            [System.Environment]::SetEnvironmentVariable($k, $prevEnv[$k])
        }
    }
}

function Get-ModuleVersionSafe {
    # Try GitVersion first
    $gv = Get-Command 'gitversion' -ErrorAction SilentlyContinue
    if ($gv) {
        try {
            $json = & gitversion /output json 2>&1
            $obj  = $json | ConvertFrom-Json
            return $obj.NuGetVersionV2
        }
        catch { <# fall through #> }
    }

    # Fallback: read from module manifest
    $psd1 = Join-Path $PSScriptRoot 'source\PowerStig.psd1'
    $data = Import-PowerShellDataFile -Path $psd1
    return $data.ModuleVersion
}

#endregion

#region ── Stage Definitions ───────────────────────────────────────────────────

$totalStages = $Script:StageOrder.Count

Write-Banner "PowerStig Air-Gapped CI/CD Pipeline" 'Cyan'
Write-Host "  Root      : $PSScriptRoot"
Write-Host "  Feed      : $FeedName -> $LocalFeedPath"
Write-Host "  Stages    : $StartStage -> $EndStage"
Write-Host "  Skip intg : $SkipIntegrationTests"
Write-Host "  Started   : $(($Script:StartTime).ToString('yyyy-MM-dd HH:mm:ss')) UTC"

# ── Stage 1: Initialize ──────────────────────────────────────────────────────
Invoke-Stage -Name 'Initialize' -Index 1 -Total $totalStages -Action {

    # Ensure artifact directories exist
    Ensure-Directory (Join-Path $Script:ArtifactsRoot 'LocalFeed')
    Ensure-Directory (Join-Path $Script:ArtifactsRoot 'BuildOutput')
    Ensure-Directory $Script:TestResultsDir
    Ensure-Directory $PublishPath

    # Validate local feed
    if (-not (Test-Path $LocalFeedPath)) {
        throw "Local feed not found at '$LocalFeedPath'. Run Scripts\Bundle-Dependencies.ps1 first."
    }
    $pkgCount = (Get-ChildItem -Path $LocalFeedPath -Filter '*.nupkg').Count
    if ($pkgCount -eq 0) {
        throw "Local feed is empty. Run Scripts\Bundle-Dependencies.ps1 -IncludeBuildModules."
    }
    Write-Host "  Local feed: $pkgCount packages" -ForegroundColor Green

    # Register local PSRepository if not already done
    $repo = Get-PSRepository -Name $FeedName -ErrorAction SilentlyContinue
    if (-not $repo) {
        Write-Host "  Registering PSRepository '$FeedName'..." -ForegroundColor Yellow
        Register-PSRepository `
            -Name               $FeedName `
            -SourceLocation     $LocalFeedPath `
            -PublishLocation    $LocalFeedPath `
            -InstallationPolicy Trusted
        Write-Host "  Registered '$FeedName'." -ForegroundColor Green
    }
    else {
        Write-Host "  PSRepository '$FeedName' already registered." -ForegroundColor Green
    }

    # Ensure NuGet provider
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') {
        Write-Host "  Installing NuGet provider from local feed..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
            -Force -Scope CurrentUser | Out-Null
    }

    # Resolve module version
    if (-not $ModuleVersion) {
        $Script:ResolvedVersion = Get-ModuleVersionSafe
    }
    else {
        $Script:ResolvedVersion = $ModuleVersion
    }
    Write-Host "  Module version: $($Script:ResolvedVersion)" -ForegroundColor Cyan

    # Optionally clean output directory
    if ($Clean -and (Test-Path $Script:OutputDir)) {
        Write-Host "  Cleaning output directory..." -ForegroundColor Yellow
        Remove-Item -Path $Script:OutputDir -Recurse -Force
        Write-Host "  Output directory cleaned." -ForegroundColor Green
    }
}

# ── Stage 2: Resolve Dependencies ────────────────────────────────────────────
Invoke-Stage -Name 'Resolve' -Index 2 -Total $totalStages -Action {

    Write-Host "  Resolving dependencies from local feed '$FeedName'..." -ForegroundColor Gray

    # Temporarily set the gallery for Resolve-Dependency.ps1
    $env:PSModuleGallery = $FeedName

    & (Join-Path $PSScriptRoot 'build.ps1') `
        -ResolveDependency `
        -Tasks 'noop' `
        -Verbose:$false

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Dependency resolution failed with exit code $LASTEXITCODE"
    }

    $env:PSModuleGallery = $null
    Write-Host "  Dependencies resolved." -ForegroundColor Green
}

# ── Stage 3: Build ───────────────────────────────────────────────────────────
Invoke-Stage -Name 'Build' -Index 3 -Total $totalStages -Action {

    Write-Host "  Building module version $($Script:ResolvedVersion)..." -ForegroundColor Gray

    $env:ModuleVersion = $Script:ResolvedVersion
    Invoke-Build -Tasks @('build') -Env @{ ModuleVersion = $Script:ResolvedVersion }
    Remove-Item -Path Env:\ModuleVersion -ErrorAction SilentlyContinue

    # Verify output exists
    $builtModule = Get-ChildItem -Path $Script:OutputDir -Filter 'PowerStig' -Recurse -Directory -ErrorAction SilentlyContinue
    if (-not $builtModule) {
        throw "Build output not found in '$Script:OutputDir'. Check build.ps1 output."
    }
    Write-Host "  Build output: $($builtModule.FullName)" -ForegroundColor Green
}

# ── Stage 4: HQRM Tests ──────────────────────────────────────────────────────
Invoke-Stage -Name 'TestHQRM' -Index 4 -Total $totalStages -Action {

    Write-Host "  Running High Quality Resource Module tests..." -ForegroundColor Gray

    Ensure-Directory $Script:TestResultsDir

    Invoke-Build -Tasks @('hqrmtest')

    # Copy NUnit results to artifact directory
    $nunit = Get-ChildItem -Path (Join-Path $Script:OutputDir 'testResults') `
        -Filter 'NUnit*.xml' -ErrorAction SilentlyContinue
    if ($nunit) {
        Copy-Item -Path $nunit.FullName -Destination $Script:TestResultsDir -Force
        Write-Host "  HQRM results copied: $($nunit.Count) file(s)" -ForegroundColor Green
    }
}

# ── Stage 5: Unit Tests ──────────────────────────────────────────────────────
Invoke-Stage -Name 'TestUnit' -Index 5 -Total $totalStages -Action {

    Write-Host "  Running Pester unit tests..." -ForegroundColor Gray

    Ensure-Directory $Script:TestResultsDir

    & (Join-Path $PSScriptRoot 'build.ps1') `
        -Tasks 'test' `
        -PesterScript 'tests/Unit'

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Unit tests failed with exit code $LASTEXITCODE"
    }

    # Copy results
    $nunit = Get-ChildItem -Path (Join-Path $Script:OutputDir 'testResults') `
        -Filter 'NUnit*.xml' -ErrorAction SilentlyContinue
    if ($nunit) {
        Copy-Item -Path $nunit.FullName `
            -Destination (Join-Path $Script:TestResultsDir 'Unit_NUnit.xml') `
            -Force
    }

    # Check code coverage
    $coverage = Get-ChildItem -Path (Join-Path $Script:OutputDir 'testResults') `
        -Filter 'JaCoCo*.xml' -ErrorAction SilentlyContinue
    if ($coverage) {
        Copy-Item -Path $coverage.FullName -Destination $Script:TestResultsDir -Force
        Write-Host "  Code coverage report copied." -ForegroundColor Green
    }

    Write-Host "  Unit tests completed." -ForegroundColor Green
}

# ── Stage 6: Integration Tests ───────────────────────────────────────────────
Invoke-Stage -Name 'TestIntegration' -Index 6 -Total $totalStages -Action {

    Write-Host "  Configuring WinRM for integration tests..." -ForegroundColor Gray

    # WinRM is required for DSC integration tests
    $winrmResult = & winrm quickconfig -quiet 2>&1
    Write-Host "  WinRM: $winrmResult" -ForegroundColor Gray

    Write-Host "  Running integration tests..." -ForegroundColor Gray
    & (Join-Path $PSScriptRoot 'build.ps1') `
        -Tasks 'test' `
        -PesterScript 'tests/Integration' `
        -CodeCoverageThreshold 0

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Integration tests failed with exit code $LASTEXITCODE"
    }

    $nunit = Get-ChildItem -Path (Join-Path $Script:OutputDir 'testResults') `
        -Filter 'NUnit*.xml' -ErrorAction SilentlyContinue
    if ($nunit) {
        Copy-Item -Path $nunit.FullName `
            -Destination (Join-Path $Script:TestResultsDir 'Integration_NUnit.xml') `
            -Force
    }

    Write-Host "  Integration tests completed." -ForegroundColor Green
}

# ── Stage 7: Package ─────────────────────────────────────────────────────────
Invoke-Stage -Name 'Package' -Index 7 -Total $totalStages -Action {

    Write-Host "  Creating NuGet package..." -ForegroundColor Gray

    Invoke-Build -Tasks @('pack') -Env @{ ModuleVersion = $Script:ResolvedVersion }

    # Verify nupkg was created
    $nupkg = Get-ChildItem -Path $Script:OutputDir -Filter '*.nupkg' -Recurse
    if (-not $nupkg) {
        throw "No .nupkg file found in '$Script:OutputDir' after pack task."
    }

    # Copy to BuildOutput
    $buildOutput = Join-Path $Script:ArtifactsRoot 'BuildOutput'
    Ensure-Directory $buildOutput
    Copy-Item -Path $nupkg.FullName -Destination $buildOutput -Force
    Write-Host "  Package: $($nupkg.Name) -> $buildOutput" -ForegroundColor Green
}

# ── Stage 8: Publish ─────────────────────────────────────────────────────────
Invoke-Stage -Name 'Publish' -Index 8 -Total $totalStages -Action {

    Ensure-Directory $PublishPath

    # Determine version-stamped release folder
    $releaseFolder = Join-Path $PublishPath "PowerStig-$($Script:ResolvedVersion)"
    Ensure-Directory $releaseFolder

    Write-Host "  Publishing to: $releaseFolder" -ForegroundColor Gray

    # Copy built module folder
    $builtModule = Get-ChildItem -Path $Script:OutputDir -Filter 'PowerStig' `
        -Recurse -Directory | Select-Object -First 1
    if ($builtModule) {
        $dest = Join-Path $releaseFolder 'Module'
        Copy-Item -Path $builtModule.FullName -Destination $dest -Recurse -Force
        Write-Host "  Module folder -> $dest" -ForegroundColor Green
    }

    # Copy NuGet package
    $nupkg = Get-ChildItem -Path (Join-Path $Script:ArtifactsRoot 'BuildOutput') `
        -Filter '*.nupkg' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($nupkg) {
        Copy-Item -Path $nupkg.FullName -Destination $releaseFolder -Force
        Write-Host "  NuGet package -> $releaseFolder\$($nupkg.Name)" -ForegroundColor Green
    }

    # Copy test results
    $results = Get-ChildItem -Path $Script:TestResultsDir -Filter '*.xml' -ErrorAction SilentlyContinue
    if ($results) {
        $resultsFolder = Join-Path $releaseFolder 'TestResults'
        Ensure-Directory $resultsFolder
        Copy-Item -Path $results.FullName -Destination $resultsFolder -Force
        Write-Host "  Test results  -> $resultsFolder ($($results.Count) files)" -ForegroundColor Green
    }

    # Write release manifest
    $manifest = [ordered]@{
        ModuleName   = 'PowerStig'
        Version      = $Script:ResolvedVersion
        BuildDate    = ([datetime]::UtcNow).ToString('yyyy-MM-dd HH:mm:ss')
        BuildHost    = $env:COMPUTERNAME
        GitCommit    = (& git rev-parse HEAD 2>$null) -replace "`n",''
        GitBranch    = (& git rev-parse --abbrev-ref HEAD 2>$null) -replace "`n",''
        Stages       = $Script:StageResults.Keys | Where-Object { $Script:StageResults[$_].Detail -ne 'skipped' }
    }
    $manifest | ConvertTo-Json -Depth 5 |
        Set-Content -Path (Join-Path $releaseFolder 'release-manifest.json') -Encoding UTF8

    Write-Host "  Manifest      -> $releaseFolder\release-manifest.json" -ForegroundColor Green
    Write-Host "  Release ready : $releaseFolder" -ForegroundColor Cyan

    # Also publish to local feed so the module can be installed via Install-Module
    $feedFolder = Join-Path $LocalFeedPath '..'
    try {
        $publishedNupkg = Get-ChildItem $releaseFolder -Filter '*.nupkg' | Select-Object -First 1
        if ($publishedNupkg) {
            Copy-Item -Path $publishedNupkg.FullName -Destination $LocalFeedPath -Force
            Write-Host "  Copied nupkg to local feed for Install-Module availability." -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Could not copy nupkg to local feed: $_"
    }
}

#endregion

# ── Final Summary ─────────────────────────────────────────────────────────────
Write-PipelineSummary

$failed = $Script:StageResults.Values | Where-Object { -not $_.Success }
if ($failed) {
    Write-Host "`n  Pipeline FAILED." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "`n  Pipeline PASSED." -ForegroundColor Green
    exit 0
}

<#
.SYNOPSIS
    Validates that the machine is ready to run the PowerStig air-gapped pipeline.

.DESCRIPTION
    Checks PowerShell version, local feed presence, PSRepository registration,
    required module availability, build tooling, and network isolation.
    Returns $true when the environment passes all required checks.
    Exits with code 1 if any blocking issue is found.

.PARAMETER LocalFeedPath
    Path to the pre-bundled .nupkg directory.

.PARAMETER FeedName
    Expected PSRepository name for the local feed.

.PARAMETER SkipNetworkCheck
    Do not attempt to reach PSGallery to test isolation.

.EXAMPLE
    .\Scripts\Test-AirGapEnvironment.ps1

.EXAMPLE
    .\Scripts\Test-AirGapEnvironment.ps1 -SkipNetworkCheck
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]$LocalFeedPath = (Join-Path $PSScriptRoot '..\Artifacts\LocalFeed'),

    [Parameter()]
    [string]$FeedName = 'LocalPSStig',

    [Parameter()]
    [switch]$SkipNetworkCheck
)

$ErrorActionPreference = 'Stop'

$issues   = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$checks   = 0
$passed   = 0

function Write-Check {
    param([string]$Label, [string]$Status, [string]$Detail = '', [string]$Color = 'Green')
    $script:checks++
    $symbol = switch ($Status) {
        'PASS' { '[PASS]'; $script:passed++; break }
        'WARN' { '[WARN]'; break }
        'FAIL' { '[FAIL]'; break }
        'INFO' { '[INFO]'; break }
    }
    $line = "  $symbol  $Label"
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line -ForegroundColor $Color
}

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor Cyan
Write-Host '  PowerStig Air-Gap Environment Check' -ForegroundColor Cyan
Write-Host ('=' * 72) -ForegroundColor Cyan

# -----------------------------------------------------------------------
# 1. PowerShell version
# -----------------------------------------------------------------------
Write-Host "`n[1] PowerShell Runtime" -ForegroundColor Yellow
$psv = $PSVersionTable.PSVersion
if ($psv.Major -ge 5) {
    Write-Check 'PowerShell version' 'PASS' "$psv"
}
else {
    Write-Check 'PowerShell version' 'FAIL' "Found $psv - requires 5.1+" 'Red'
    $issues.Add("PowerShell 5.1 or later is required (found $psv)")
}

# Check for PowerShell 7+ (optional but recommended for cross-platform tasks)
if ($psv.Major -ge 7) {
    Write-Check 'PowerShell 7+ present' 'PASS' 'pwsh.exe available' 'Green'
}
else {
    Write-Check 'PowerShell 7+ present' 'WARN' 'Not found - some tasks use pwsh' 'Yellow'
    $warnings.Add('PowerShell 7+ (pwsh) not detected. Some build tasks prefer pwsh.')
}

# -----------------------------------------------------------------------
# 2. Local feed directory
# -----------------------------------------------------------------------
Write-Host "`n[2] Local Package Feed" -ForegroundColor Yellow
if (Test-Path $LocalFeedPath) {
    $pkgs = Get-ChildItem -Path $LocalFeedPath -Filter '*.nupkg'
    if ($pkgs.Count -gt 0) {
        Write-Check 'Feed directory' 'PASS' "$($pkgs.Count) packages at $LocalFeedPath"
    }
    else {
        Write-Check 'Feed directory' 'FAIL' "Exists but contains 0 .nupkg files" 'Red'
        $issues.Add("Local feed directory '$LocalFeedPath' is empty. Run Bundle-Dependencies.ps1.")
    }
}
else {
    Write-Check 'Feed directory' 'FAIL' "Not found: $LocalFeedPath" 'Red'
    $issues.Add("Local feed not found at '$LocalFeedPath'. Run Bundle-Dependencies.ps1 first.")
}

# -----------------------------------------------------------------------
# 3. PSRepository registration
# -----------------------------------------------------------------------
Write-Host "`n[3] PSRepository Registration" -ForegroundColor Yellow
$repo = Get-PSRepository -Name $FeedName -ErrorAction SilentlyContinue
if ($repo) {
    Write-Check 'Repository registered' 'PASS' "'$FeedName' -> $($repo.SourceLocation)"
    if ($repo.InstallationPolicy -ne 'Trusted') {
        Write-Check 'Repository trusted' 'WARN' "Policy is '$($repo.InstallationPolicy)' - may prompt during install" 'Yellow'
        $warnings.Add("Repository '$FeedName' is not Trusted. Re-run Initialize-LocalFeed.ps1.")
    }
    else {
        Write-Check 'Repository trusted' 'PASS'
    }
}
else {
    Write-Check 'Repository registered' 'WARN' "'$FeedName' not found - run Initialize-LocalFeed.ps1" 'Yellow'
    $warnings.Add("PSRepository '$FeedName' not registered. Run Scripts\Initialize-LocalFeed.ps1.")
}

# -----------------------------------------------------------------------
# 4. Required runtime modules
# -----------------------------------------------------------------------
Write-Host "`n[4] Required Runtime Modules" -ForegroundColor Yellow

$runtimeModules = @(
    @{ Name = 'AuditPolicyDsc';        MinVersion = '1.4.0.0'   }
    @{ Name = 'AuditSystemDsc';        MinVersion = '1.1.0'     }
    @{ Name = 'AccessControlDsc';      MinVersion = '1.4.3'     }
    @{ Name = 'ComputerManagementDsc'; MinVersion = '8.4.0'     }
    @{ Name = 'FileContentDsc';        MinVersion = '1.3.0.151' }
    @{ Name = 'GPRegistryPolicyDsc';   MinVersion = '1.3.1'     }
    @{ Name = 'PSDscResources';        MinVersion = '2.12.0.0'  }
    @{ Name = 'SecurityPolicyDsc';     MinVersion = '2.10.0.0'  }
    @{ Name = 'SqlServerDsc';          MinVersion = '15.1.1'    }
    @{ Name = 'WindowsDefenderDsc';    MinVersion = '2.2.0'     }
    @{ Name = 'xDnsServer';            MinVersion = '1.16.0.0'  }
    @{ Name = 'xWebAdministration';    MinVersion = '3.2.0'     }
    @{ Name = 'CertificateDsc';        MinVersion = '5.0.0'     }
)

foreach ($mod in $runtimeModules) {
    $installed = Get-Module -Name $mod.Name -ListAvailable |
        Where-Object { $_.Version -ge [version]$mod.MinVersion } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($installed) {
        Write-Check $mod.Name 'PASS' "v$($installed.Version) installed"
    }
    else {
        # Check if it's at least bundled
        $inFeed = Get-ChildItem -Path $LocalFeedPath -Filter "$($mod.Name)*.nupkg" -ErrorAction SilentlyContinue
        if ($inFeed) {
            Write-Check $mod.Name 'WARN' "Not installed - bundled in local feed (will install during pipeline)" 'Yellow'
        }
        else {
            Write-Check $mod.Name 'FAIL' "Not installed and not bundled" 'Red'
            $issues.Add("Module $($mod.Name) >= $($mod.MinVersion) is missing from both system and local feed.")
        }
    }
}

# -----------------------------------------------------------------------
# 5. Build tooling
# -----------------------------------------------------------------------
Write-Host "`n[5] Build Tooling" -ForegroundColor Yellow

$buildTools = @(
    @{ Name = 'InvokeBuild'; MinVersion = '5.0.0' }
    @{ Name = 'Sampler';     MinVersion = '0.100.0' }
    @{ Name = 'PSDepend';    MinVersion = '0.3.0' }
    @{ Name = 'Pester';      MinVersion = '5.0.0' }
)

foreach ($tool in $buildTools) {
    $installed = Get-Module -Name $tool.Name -ListAvailable |
        Where-Object { $_.Version -ge [version]$tool.MinVersion } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($installed) {
        Write-Check $tool.Name 'PASS' "v$($installed.Version)"
    }
    else {
        $inFeed = Get-ChildItem -Path $LocalFeedPath -Filter "$($tool.Name)*.nupkg" -ErrorAction SilentlyContinue
        if ($inFeed) {
            Write-Check $tool.Name 'WARN' "Not installed - bundled (will install via -ResolveDependency)" 'Yellow'
            $warnings.Add("$($tool.Name) not installed - will be resolved from local feed during build.")
        }
        else {
            Write-Check $tool.Name 'FAIL' "Missing - re-run Bundle-Dependencies.ps1 -IncludeBuildModules" 'Red'
            $issues.Add("Build tool $($tool.Name) >= $($tool.MinVersion) is missing. Re-bundle with -IncludeBuildModules.")
        }
    }
}

# Check GitVersion
$gv = Get-Command 'gitversion' -ErrorAction SilentlyContinue
if ($gv) {
    Write-Check 'GitVersion' 'PASS' $gv.Source
}
else {
    Write-Check 'GitVersion' 'WARN' 'Not on PATH - version will fall back to module manifest value' 'Yellow'
    $warnings.Add('gitversion.exe not found on PATH. Module version will use fallback from manifest.')
}

# -----------------------------------------------------------------------
# 6. Git
# -----------------------------------------------------------------------
Write-Host "`n[6] Git" -ForegroundColor Yellow
$git = Get-Command 'git' -ErrorAction SilentlyContinue
if ($git) {
    $gitVersion = & git --version 2>&1
    Write-Check 'git' 'PASS' $gitVersion
}
else {
    Write-Check 'git' 'FAIL' 'git.exe not found on PATH' 'Red'
    $issues.Add('git.exe not found on PATH. Git is required for version computation and changelog tasks.')
}

# -----------------------------------------------------------------------
# 7. Network isolation
# -----------------------------------------------------------------------
if (-not $SkipNetworkCheck) {
    Write-Host "`n[7] Network Isolation" -ForegroundColor Yellow
    $endpoints = @('powershellgallery.com', 'www.nuget.org', 'github.com')
    foreach ($endpoint in $endpoints) {
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $connected = $tcp.ConnectAsync($endpoint, 443).Wait(2000)
            $tcp.Close()
            if ($connected) {
                Write-Check "Reach $endpoint" 'WARN' "Reachable - machine may NOT be air-gapped" 'Yellow'
                $warnings.Add("$endpoint is reachable. Verify this machine is intended to be air-gapped.")
            }
        }
        catch {
            Write-Check "Block $endpoint" 'PASS' 'Unreachable - properly isolated'
        }
    }
}
else {
    Write-Host '  (network check skipped)' -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------
# 8. Output directory
# -----------------------------------------------------------------------
Write-Host "`n[8] Artifact Directories" -ForegroundColor Yellow
$dirs = @(
    (Join-Path $PSScriptRoot '..\Artifacts\LocalFeed')
    (Join-Path $PSScriptRoot '..\Artifacts\BuildOutput')
    (Join-Path $PSScriptRoot '..\Artifacts\TestResults')
    (Join-Path $PSScriptRoot '..\Artifacts\Releases')
)
foreach ($dir in $dirs) {
    $abs = [System.IO.Path]::GetFullPath($dir)
    if (Test-Path $abs) {
        Write-Check $abs 'PASS'
    }
    else {
        Write-Check $abs 'INFO' 'Will be created by pipeline' 'DarkGray'
    }
}

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 72) -ForegroundColor Cyan
Write-Host "  Results: $passed / $checks checks passed" -ForegroundColor $(if ($issues.Count -eq 0) { 'Green' } else { 'Red' })

if ($warnings.Count -gt 0) {
    Write-Host "`n  Warnings ($($warnings.Count)):" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "    * $_" -ForegroundColor Yellow }
}

if ($issues.Count -gt 0) {
    Write-Host "`n  Blocking issues ($($issues.Count)):" -ForegroundColor Red
    $issues | ForEach-Object { Write-Host "    * $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host '  Environment is NOT ready. Resolve the issues above before running the pipeline.' -ForegroundColor Red
    Write-Host ('=' * 72) -ForegroundColor Cyan
    exit 1
}

Write-Host "`n  Environment is ready for air-gapped pipeline execution." -ForegroundColor Green
Write-Host ('=' * 72) -ForegroundColor Cyan
return $true

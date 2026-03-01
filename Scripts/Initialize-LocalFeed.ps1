<#
.SYNOPSIS
    Registers the local NuGet package directory as a PowerShell repository.

.DESCRIPTION
    Configures the current machine to use Artifacts\LocalFeed as a trusted
    PSRepository named 'LocalPSStig'. Must be run (once per machine) before
    Invoke-Pipeline.ps1 or any build that needs to resolve dependencies
    without internet access.

    Requires the Artifacts\LocalFeed directory to be populated first by
    running Scripts\Bundle-Dependencies.ps1 on an internet-connected machine.

.PARAMETER LocalFeedPath
    Path to the directory containing the pre-bundled .nupkg files.

.PARAMETER FeedName
    Name to register the PSRepository under. Default: LocalPSStig.

.PARAMETER Force
    Re-register the repository even if it already exists.

.EXAMPLE
    .\Scripts\Initialize-LocalFeed.ps1

.EXAMPLE
    .\Scripts\Initialize-LocalFeed.ps1 -LocalFeedPath 'D:\OfflinePackages' -Force
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]$LocalFeedPath = (Join-Path $PSScriptRoot '..\Artifacts\LocalFeed'),

    [Parameter()]
    [string]$FeedName = 'LocalPSStig',

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Resolve to an absolute path
$LocalFeedPath = (Resolve-Path -Path $LocalFeedPath -ErrorAction Stop).Path

Write-Host "`n=== Initialize Local PSRepository ===" -ForegroundColor Cyan
Write-Host "  Feed name : $FeedName"
Write-Host "  Feed path : $LocalFeedPath"

# Validate the feed directory has packages
$packages = Get-ChildItem -Path $LocalFeedPath -Filter '*.nupkg' -ErrorAction SilentlyContinue
if ($packages.Count -eq 0) {
    throw "No .nupkg files found in '$LocalFeedPath'. Run Scripts\Bundle-Dependencies.ps1 first."
}
Write-Host "  Packages  : $($packages.Count) found" -ForegroundColor Green

# Ensure NuGet provider is available
Write-Host "`nChecking NuGet package provider..." -ForegroundColor Gray
$nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
if (-not $nuget -or $nuget.Version -lt [version]'2.8.5.201') {
    Write-Host "  Installing NuGet provider..." -ForegroundColor Yellow
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
}
Write-Host "  NuGet provider OK" -ForegroundColor Green

# Register the repository
$existing = Get-PSRepository -Name $FeedName -ErrorAction SilentlyContinue
if ($existing) {
    if ($Force) {
        Write-Host "`nRe-registering '$FeedName' (Force specified)..." -ForegroundColor Yellow
        Unregister-PSRepository -Name $FeedName
    }
    else {
        Write-Host "`nRepository '$FeedName' already registered at: $($existing.SourceLocation)" -ForegroundColor Green
        Write-Host "  Use -Force to re-register." -ForegroundColor Gray
        return
    }
}

Write-Host "`nRegistering PSRepository '$FeedName'..." -ForegroundColor Gray
Register-PSRepository `
    -Name               $FeedName `
    -SourceLocation     $LocalFeedPath `
    -PublishLocation    $LocalFeedPath `
    -InstallationPolicy Trusted

Write-Host "  Registered successfully." -ForegroundColor Green

# Verify
$repo = Get-PSRepository -Name $FeedName
Write-Host "`nRepository details:" -ForegroundColor Cyan
Write-Host "  Name              : $($repo.Name)"
Write-Host "  SourceLocation    : $($repo.SourceLocation)"
Write-Host "  InstallationPolicy: $($repo.InstallationPolicy)"
Write-Host "  Trusted           : $($repo.InstallationPolicy -eq 'Trusted')"

Write-Host "`n[OK] Local feed ready. Run .\Invoke-Pipeline.ps1 to start the pipeline." -ForegroundColor Green

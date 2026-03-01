<#
.SYNOPSIS
    Downloads all PowerStig dependencies to a local directory for air-gapped use.

.DESCRIPTION
    Run this script ONCE on an internet-connected machine. It downloads every
    required module (runtime and build tooling) from PSGallery as NuGet packages
    and saves them to Artifacts\LocalFeed.

    Transfer the entire Artifacts\LocalFeed directory to the air-gapped machine
    before running Initialize-LocalFeed.ps1 or Invoke-Pipeline.ps1.

.PARAMETER OutputPath
    Path to save downloaded packages. Defaults to ..\Artifacts\LocalFeed relative
    to this script.

.PARAMETER IncludeBuildModules
    Also download build/test tooling (Sampler, InvokeBuild, Pester, etc.).
    Recommended for full air-gap isolation.

.PARAMETER Force
    Re-download packages even if they already exist locally.

.EXAMPLE
    .\Bundle-Dependencies.ps1 -IncludeBuildModules

.EXAMPLE
    .\Bundle-Dependencies.ps1 -OutputPath 'D:\OfflinePackages' -IncludeBuildModules
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\Artifacts\LocalFeed'),

    [Parameter()]
    [switch]$IncludeBuildModules,

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

#region Helpers
function Write-Stage {
    param([string]$Message)
    Write-Host ("`n" + ('=' * 72)) -ForegroundColor DarkGray
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Save-ModuleSafe {
    param(
        [string]$Name,
        [string]$RequiredVersion,
        [string]$Path
    )
    $existing = Get-ChildItem -Path $Path -Filter "$Name.$RequiredVersion.nupkg" -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        Write-Host "  SKIP  $Name $RequiredVersion (already bundled)" -ForegroundColor DarkGray
        return
    }
    try {
        Save-Module -Name $Name -RequiredVersion $RequiredVersion `
            -Path $Path -Repository PSGallery -Force -ErrorAction Stop
        Write-Host "  OK    $Name $RequiredVersion" -ForegroundColor Green
    }
    catch {
        Write-Warning "  WARN  $Name $RequiredVersion - $_"
    }
}
#endregion

Write-Stage 'PowerStig Air-Gap Dependency Bundler'
Write-Host "  Output : $OutputPath"
Write-Host "  Include build modules : $IncludeBuildModules"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Host "`nCreated output directory: $OutputPath" -ForegroundColor Yellow
}

# -----------------------------------------------------------------------
# Runtime dependencies (from source\PowerStig.psd1 RequiredModules)
# -----------------------------------------------------------------------
Write-Stage 'Downloading Runtime Dependencies'

$runtimeDeps = @(
    @{ Name = 'AuditPolicyDsc';        RequiredVersion = '1.4.0.0'    }
    @{ Name = 'AuditSystemDsc';        RequiredVersion = '1.1.0'      }
    @{ Name = 'AccessControlDsc';      RequiredVersion = '1.4.3'      }
    @{ Name = 'ComputerManagementDsc'; RequiredVersion = '8.4.0'      }
    @{ Name = 'FileContentDsc';        RequiredVersion = '1.3.0.151'  }
    @{ Name = 'GPRegistryPolicyDsc';   RequiredVersion = '1.3.1'      }
    @{ Name = 'PSDscResources';        RequiredVersion = '2.12.0.0'   }
    @{ Name = 'SecurityPolicyDsc';     RequiredVersion = '2.10.0.0'   }
    @{ Name = 'SqlServerDsc';          RequiredVersion = '15.1.1'     }
    @{ Name = 'WindowsDefenderDsc';    RequiredVersion = '2.2.0'      }
    @{ Name = 'xDnsServer';            RequiredVersion = '1.16.0.0'   }
    @{ Name = 'xWebAdministration';    RequiredVersion = '3.2.0'      }
    @{ Name = 'CertificateDsc';        RequiredVersion = '5.0.0'      }
    @{ Name = 'nx';                    RequiredVersion = '1.0'        }
)

foreach ($dep in $runtimeDeps) {
    Save-ModuleSafe @dep -Path $OutputPath
}

# -----------------------------------------------------------------------
# Build / tooling dependencies
# -----------------------------------------------------------------------
if ($IncludeBuildModules) {
    Write-Stage 'Downloading Build & Tooling Dependencies'

    $buildDeps = @(
        @{ Name = 'Sampler';                RequiredVersion = '0.117.2'   }
        @{ Name = 'InvokeBuild';            RequiredVersion = '5.10.2'    }
        @{ Name = 'PSDepend';               RequiredVersion = '0.3.8'     }
        @{ Name = 'PowerShellGet';          RequiredVersion = '2.2.5'     }
        @{ Name = 'PackageManagement';      RequiredVersion = '1.4.8.1'   }
        @{ Name = 'Pester';                 RequiredVersion = '5.5.0'     }
        @{ Name = 'DscResource.Test';       RequiredVersion = '0.16.3'    }
        @{ Name = 'powershell-yaml';        RequiredVersion = '0.4.7'     }
        @{ Name = 'ModuleBuilder';          RequiredVersion = '2.0.0'     }
        @{ Name = 'ChangelogManagement';    RequiredVersion = '3.0.1'     }
        @{ Name = 'GitVersion.MsBuild';     RequiredVersion = '5.12.0'    }
    )

    foreach ($dep in $buildDeps) {
        Save-ModuleSafe @dep -Path $OutputPath
    }
}

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
Write-Stage 'Bundle Complete'
$packages = Get-ChildItem -Path $OutputPath -Filter '*.nupkg'
Write-Host "  Packages saved : $($packages.Count)"
Write-Host "  Location       : $OutputPath"
Write-Host ''
Write-Host '  Next steps:' -ForegroundColor Yellow
Write-Host '    1. Transfer the Artifacts\LocalFeed directory to the air-gapped machine.' -ForegroundColor Yellow
Write-Host '    2. Run Scripts\Initialize-LocalFeed.ps1 to register the local repository.' -ForegroundColor Yellow
Write-Host '    3. Run .\Invoke-Pipeline.ps1 to execute the full pipeline.' -ForegroundColor Yellow

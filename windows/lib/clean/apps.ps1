# Mole - Application-Specific Cleanup Module
# Cleans leftover data from uninstalled apps and app-specific caches

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_CLEAN_APPS_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_CLEAN_APPS_LOADED) { return }
$script:MOLE_CLEAN_APPS_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\core\base.ps1"
. "$scriptDir\..\core\log.ps1"
. "$scriptDir\..\core\file_ops.ps1"

# ============================================================================
# Orphaned App Data Detection
# ============================================================================

function Get-InstalledPrograms {
    <#
    .SYNOPSIS
        Get list of installed programs from registry
    #>
    
    $programs = @()
    
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    foreach ($path in $registryPaths) {
        $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName } |
                 Select-Object DisplayName, InstallLocation, Publisher
        if ($items) {
            $programs += $items
        }
    }
    
    # Also check UWP apps
    try {
        $uwpApps = Get-AppxPackage -ErrorAction SilentlyContinue | 
                   Select-Object @{N='DisplayName';E={$_.Name}}, @{N='InstallLocation';E={$_.InstallLocation}}, Publisher
        if ($uwpApps) {
            $programs += $uwpApps
        }
    }
    catch {
        Write-Debug "Could not enumerate UWP apps: $_"
    }
    
    return $programs
}

function Find-OrphanedAppData {
    <#
    .SYNOPSIS
        Find app data folders for apps that are no longer installed
    #>
    param([int]$DaysOld = 60)
    
    $installedPrograms = Get-InstalledPrograms
    $installedNames = $installedPrograms | ForEach-Object { $_.DisplayName.ToLower() }
    
    $orphanedPaths = @()
    $cutoffDate = (Get-Date).AddDays(-$DaysOld)
    
    # Check common app data locations
    $appDataPaths = @(
        @{ Path = $env:APPDATA; Type = "Roaming" }
        @{ Path = $env:LOCALAPPDATA; Type = "Local" }
    )
    
    foreach ($location in $appDataPaths) {
        if (-not (Test-Path $location.Path)) { continue }
        
        $folders = Get-ChildItem -Path $location.Path -Directory -ErrorAction SilentlyContinue
        
        foreach ($folder in $folders) {
            # Skip system folders
            $skipFolders = @('Microsoft', 'Windows', 'Packages', 'Programs', 'Temp', 'Roaming')
            if ($folder.Name -in $skipFolders) { continue }
            
            # Skip if recently modified
            if ($folder.LastWriteTime -gt $cutoffDate) { continue }
            
            # Check if app is installed
            $isInstalled = $false
            foreach ($name in $installedNames) {
                if ($name -like "*$($folder.Name.ToLower())*" -or $folder.Name.ToLower() -like "*$name*") {
                    $isInstalled = $true
                    break
                }
            }
            
            if (-not $isInstalled) {
                $orphanedPaths += @{
                    Path = $folder.FullName
                    Name = $folder.Name
                    Type = $location.Type
                    Size = (Get-PathSize -Path $folder.FullName)
                    LastModified = $folder.LastWriteTime
                }
            }
        }
    }
    
    return $orphanedPaths
}

function Clear-OrphanedAppData {
    <#
    .SYNOPSIS
        Clean orphaned application data
    #>
    param([int]$DaysOld = 60)
    
    Start-Section "Orphaned app data"
    
    $orphaned = Find-OrphanedAppData -DaysOld $DaysOld
    
    if ($orphaned.Count -eq 0) {
        Write-Info "No orphaned app data found"
        Stop-Section
        return
    }
    
    # Filter by size (only clean if > 10MB to avoid noise)
    $significantOrphans = $orphaned | Where-Object { $_.Size -gt 10MB }
    
    if ($significantOrphans.Count -gt 0) {
        $totalSize = ($significantOrphans | Measure-Object -Property Size -Sum).Sum
        $sizeHuman = Format-ByteSize -Bytes $totalSize
        
        Write-Info "Found $($significantOrphans.Count) orphaned folders ($sizeHuman)"
        
        foreach ($orphan in $significantOrphans) {
            $orphanSize = Format-ByteSize -Bytes $orphan.Size
            Remove-SafeItem -Path $orphan.Path -Description "$($orphan.Name) ($orphanSize)" -Recurse
        }
    }
    
    Stop-Section
}

# ============================================================================
# Specific Application Cleanup
# ============================================================================

function Clear-OfficeCache {
    <#
    .SYNOPSIS
        Clean Microsoft Office caches and temp files
    #>
    
    $officeCachePaths = @(
        # Office 365 / 2019 / 2021
        "$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache"
        "$env:LOCALAPPDATA\Microsoft\Office\16.0\Wef"
        "$env:LOCALAPPDATA\Microsoft\Outlook\RoamCache"
        "$env:LOCALAPPDATA\Microsoft\Outlook\Offline Address Books"
        # Older Office versions
        "$env:LOCALAPPDATA\Microsoft\Office\15.0\OfficeFileCache"
        # Office temp files
        "$env:APPDATA\Microsoft\Templates\*.tmp"
        "$env:APPDATA\Microsoft\Word\*.tmp"
        "$env:APPDATA\Microsoft\Excel\*.tmp"
        "$env:APPDATA\Microsoft\PowerPoint\*.tmp"
    )
    
    foreach ($path in $officeCachePaths) {
        if ($path -like "*.tmp") {
            $parent = Split-Path -Parent $path
            if (Test-Path $parent) {
                $tmpFiles = Get-ChildItem -Path $parent -Filter "*.tmp" -File -ErrorAction SilentlyContinue
                if ($tmpFiles) {
                    $paths = $tmpFiles | ForEach-Object { $_.FullName }
                    Remove-SafeItems -Paths $paths -Description "Office temp files"
                }
            }
        }
        elseif (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Office $(Split-Path -Leaf $path)"
        }
    }
}

function Clear-OneDriveCache {
    <#
    .SYNOPSIS
        Clean OneDrive cache
    #>
    
    $oneDriveCachePaths = @(
        "$env:LOCALAPPDATA\Microsoft\OneDrive\logs"
        "$env:LOCALAPPDATA\Microsoft\OneDrive\setup\logs"
    )
    
    foreach ($path in $oneDriveCachePaths) {
        if (Test-Path $path) {
            Remove-OldFiles -Path $path -DaysOld 7 -Description "OneDrive logs"
        }
    }
}

function Clear-DroplboxCache {
    <#
    .SYNOPSIS
        Clean Dropbox cache
    #>
    
    # Dropbox cache is typically in the Dropbox folder itself
    $dropboxInfoPath = "$env:LOCALAPPDATA\Dropbox\info.json"
    
    if (Test-Path $dropboxInfoPath) {
        try {
            $dropboxInfo = Get-Content $dropboxInfoPath | ConvertFrom-Json
            $dropboxPath = $dropboxInfo.personal.path
            
            if ($dropboxPath) {
                $dropboxCachePath = "$dropboxPath\.dropbox.cache"
                if (Test-Path $dropboxCachePath) {
                    Clear-DirectoryContents -Path $dropboxCachePath -Description "Dropbox cache"
                }
            }
        }
        catch {
            Write-Debug "Could not read Dropbox config: $_"
        }
    }
}

function Clear-GoogleDriveCache {
    <#
    .SYNOPSIS
        Clean Google Drive cache
    #>
    
    $googleDriveCachePaths = @(
        "$env:LOCALAPPDATA\Google\DriveFS\Logs"
        "$env:LOCALAPPDATA\Google\DriveFS\*.tmp"
    )
    
    foreach ($path in $googleDriveCachePaths) {
        if ($path -like "*.tmp") {
            $parent = Split-Path -Parent $path
            if (Test-Path $parent) {
                $tmpFiles = Get-ChildItem -Path $parent -Filter "*.tmp" -ErrorAction SilentlyContinue
                if ($tmpFiles) {
                    $paths = $tmpFiles | ForEach-Object { $_.FullName }
                    Remove-SafeItems -Paths $paths -Description "Google Drive temp"
                }
            }
        }
        elseif (Test-Path $path) {
            Remove-OldFiles -Path $path -DaysOld 7 -Description "Google Drive logs"
        }
    }
}

function Clear-AdobeData {
    <#
    .SYNOPSIS
        Clean Adobe application caches and temp files
    #>
    
    $adobeCachePaths = @(
        "$env:APPDATA\Adobe\Common\Media Cache Files"
        "$env:APPDATA\Adobe\Common\Peak Files"
        "$env:APPDATA\Adobe\Common\Team Projects Cache"
        "$env:LOCALAPPDATA\Adobe\*\Cache"
        "$env:LOCALAPPDATA\Adobe\*\CameraRaw\Cache"
        "$env:LOCALAPPDATA\Temp\Adobe"
    )
    
    foreach ($pattern in $adobeCachePaths) {
        $paths = Resolve-Path $pattern -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            if (Test-Path $path.Path) {
                Clear-DirectoryContents -Path $path.Path -Description "Adobe cache"
            }
        }
    }
}

function Clear-AutodeskData {
    <#
    .SYNOPSIS
        Clean Autodesk application caches
    #>
    
    $autodeskCachePaths = @(
        "$env:LOCALAPPDATA\Autodesk\*\Cache"
        "$env:APPDATA\Autodesk\*\cache"
    )
    
    foreach ($pattern in $autodeskCachePaths) {
        $paths = Resolve-Path $pattern -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            if (Test-Path $path.Path) {
                Clear-DirectoryContents -Path $path.Path -Description "Autodesk cache"
            }
        }
    }
}

# ============================================================================
# Gaming Platform Cleanup
# ============================================================================

function Clear-GamingPlatformCaches {
    <#
    .SYNOPSIS
        Clean gaming platform caches (Steam, Epic, Origin, etc.)
    #>
    
    # Steam
    $steamPaths = @(
        "${env:ProgramFiles(x86)}\Steam\appcache\httpcache"
        "${env:ProgramFiles(x86)}\Steam\appcache\librarycache"
        "${env:ProgramFiles(x86)}\Steam\logs"
    )
    foreach ($path in $steamPaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Steam $(Split-Path -Leaf $path)"
        }
    }
    
    # Epic Games Launcher
    $epicPaths = @(
        "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\webcache"
        "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\Logs"
    )
    foreach ($path in $epicPaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Epic Games $(Split-Path -Leaf $path)"
        }
    }
    
    # EA App (Origin replacement)
    $eaPaths = @(
        "$env:LOCALAPPDATA\Electronic Arts\EA Desktop\cache"
        "$env:APPDATA\Origin\*\cache"
    )
    foreach ($pattern in $eaPaths) {
        $paths = Resolve-Path $pattern -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            if (Test-Path $path.Path) {
                Clear-DirectoryContents -Path $path.Path -Description "EA/Origin cache"
            }
        }
    }
    
    # GOG Galaxy
    $gogPaths = @(
        "$env:LOCALAPPDATA\GOG.com\Galaxy\webcache"
        "$env:PROGRAMDATA\GOG.com\Galaxy\logs"
    )
    foreach ($path in $gogPaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "GOG Galaxy $(Split-Path -Leaf $path)"
        }
    }
    
    # Ubisoft Connect
    $ubiPaths = @(
        "$env:LOCALAPPDATA\Ubisoft Game Launcher\cache"
        "$env:LOCALAPPDATA\Ubisoft Game Launcher\logs"
    )
    foreach ($path in $ubiPaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Ubisoft $(Split-Path -Leaf $path)"
        }
    }
    
    # Battle.net
    $battlenetPaths = @(
        "$env:APPDATA\Battle.net\Cache"
        "$env:APPDATA\Battle.net\Logs"
    )
    foreach ($path in $battlenetPaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Battle.net $(Split-Path -Leaf $path)"
        }
    }
}

# ============================================================================
# Main Application Cleanup Function
# ============================================================================

function Invoke-AppCleanup {
    <#
    .SYNOPSIS
        Run all application-specific cleanup tasks
    #>
    param([switch]$IncludeOrphaned)
    
    Start-Section "Applications"
    
    # Productivity apps
    Clear-OfficeCache
    Clear-OneDriveCache
    Clear-DroplboxCache
    Clear-GoogleDriveCache
    
    # Creative apps
    Clear-AdobeData
    Clear-AutodeskData
    
    # Gaming platforms
    Clear-GamingPlatformCaches
    
    Stop-Section
    
    # Orphaned app data (separate section)
    if ($IncludeOrphaned) {
        Clear-OrphanedAppData -DaysOld 60
    }
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Get-InstalledPrograms, Find-OrphanedAppData, Clear-OfficeCache, etc.

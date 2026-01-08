# Mole - Uninstall Command
# Interactive application uninstaller for Windows

#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$DebugMode,
    [switch]$Rescan,
    [switch]$ShowHelp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) "lib"

# Import core modules
. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\ui.ps1"
. "$libDir\core\file_ops.ps1"

# ============================================================================
# Configuration
# ============================================================================

$script:CacheDir = "$env:USERPROFILE\.cache\mole"
$script:AppCacheFile = "$script:CacheDir\app_scan_cache.json"
$script:CacheTTLHours = 24

# ============================================================================
# Help
# ============================================================================

function Show-UninstallHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mMole Uninstall$esc[0m - Interactive application uninstaller"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mole uninstall [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  -Rescan      Force rescan of installed applications"
    Write-Host "  -DebugMode   Enable debug logging"
    Write-Host "  -ShowHelp    Show this help message"
    Write-Host ""
    Write-Host "$esc[33mFeatures:$esc[0m"
    Write-Host "  - Scans installed programs from registry and Windows Apps"
    Write-Host "  - Shows program size and last used date"
    Write-Host "  - Interactive selection with arrow keys"
    Write-Host "  - Cleans leftover files after uninstall"
    Write-Host ""
}

# ============================================================================
# Protected Applications
# ============================================================================

$script:ProtectedApps = @(
    "Microsoft Windows"
    "Windows Feature Experience Pack"
    "Microsoft Edge"
    "Microsoft Edge WebView2"
    "Windows Security"
    "Microsoft Visual C++ *"
    "Microsoft .NET *"
    ".NET Desktop Runtime*"
    "Microsoft Update Health Tools"
    "NVIDIA Graphics Driver*"
    "AMD Software*"
    "Intel*Driver*"
)

function Test-ProtectedApp {
    param([string]$AppName)
    
    foreach ($pattern in $script:ProtectedApps) {
        if ($AppName -like $pattern) {
            return $true
        }
    }
    return $false
}

# ============================================================================
# Application Discovery
# ============================================================================

function Get-InstalledApplications {
    <#
    .SYNOPSIS
        Scan and return all installed applications
    #>
    param([switch]$ForceRescan)
    
    # Check cache
    if (-not $ForceRescan -and (Test-Path $script:AppCacheFile)) {
        $cacheInfo = Get-Item $script:AppCacheFile
        $cacheAge = (Get-Date) - $cacheInfo.LastWriteTime
        
        if ($cacheAge.TotalHours -lt $script:CacheTTLHours) {
            Write-Debug "Loading from cache..."
            try {
                $cached = Get-Content $script:AppCacheFile | ConvertFrom-Json
                return $cached
            }
            catch {
                Write-Debug "Cache read failed, rescanning..."
            }
        }
    }
    
    Write-Info "Scanning installed applications..."
    
    $apps = @()
    
    # Registry paths for installed programs
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    $count = 0
    $total = $registryPaths.Count
    
    foreach ($path in $registryPaths) {
        $count++
        Write-Progress -Activity "Scanning applications" -Status "Registry path $count of $total" -PercentComplete (($count / $total) * 50)
        
        $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                 Where-Object { 
                     $_.DisplayName -and 
                     $_.UninstallString -and
                     -not (Test-ProtectedApp $_.DisplayName)
                 }
        
        foreach ($item in $items) {
            # Calculate size
            $sizeKB = 0
            if ($item.EstimatedSize) {
                $sizeKB = [long]$item.EstimatedSize
            }
            elseif ($item.InstallLocation -and (Test-Path $item.InstallLocation)) {
                $sizeKB = Get-PathSizeKB -Path $item.InstallLocation
            }
            
            # Get install date
            $installDate = $null
            if ($item.InstallDate) {
                try {
                    $installDate = [DateTime]::ParseExact($item.InstallDate, "yyyyMMdd", $null)
                }
                catch { }
            }
            
            $apps += [PSCustomObject]@{
                Name = $item.DisplayName
                Publisher = $item.Publisher
                Version = $item.DisplayVersion
                SizeKB = $sizeKB
                SizeHuman = Format-ByteSize -Bytes ($sizeKB * 1024)
                InstallLocation = $item.InstallLocation
                UninstallString = $item.UninstallString
                InstallDate = $installDate
                Source = "Registry"
            }
        }
    }
    
    # UWP / Store Apps
    Write-Progress -Activity "Scanning applications" -Status "Scanning Windows Apps" -PercentComplete 75
    
    try {
        $uwpApps = Get-AppxPackage -ErrorAction SilentlyContinue |
                   Where-Object { 
                       $_.IsFramework -eq $false -and
                       $_.SignatureKind -ne 'System' -and
                       -not (Test-ProtectedApp $_.Name)
                   }
        
        foreach ($uwp in $uwpApps) {
            # Get friendly name
            $name = $uwp.Name
            try {
                $manifest = Get-AppxPackageManifest -Package $uwp.PackageFullName -ErrorAction SilentlyContinue
                if ($manifest.Package.Properties.DisplayName -and 
                    -not $manifest.Package.Properties.DisplayName.StartsWith("ms-resource:")) {
                    $name = $manifest.Package.Properties.DisplayName
                }
            }
            catch { }
            
            # Calculate size
            $sizeKB = 0
            if ($uwp.InstallLocation -and (Test-Path $uwp.InstallLocation)) {
                $sizeKB = Get-PathSizeKB -Path $uwp.InstallLocation
            }
            
            $apps += [PSCustomObject]@{
                Name = $name
                Publisher = $uwp.Publisher
                Version = $uwp.Version
                SizeKB = $sizeKB
                SizeHuman = Format-ByteSize -Bytes ($sizeKB * 1024)
                InstallLocation = $uwp.InstallLocation
                UninstallString = $null
                PackageFullName = $uwp.PackageFullName
                InstallDate = $null
                Source = "WindowsStore"
            }
        }
    }
    catch {
        Write-Debug "Could not enumerate UWP apps: $_"
    }
    
    Write-Progress -Activity "Scanning applications" -Completed
    
    # Sort by size (largest first)
    $apps = $apps | Sort-Object -Property SizeKB -Descending
    
    # Cache results
    if (-not (Test-Path $script:CacheDir)) {
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
    }
    $apps | ConvertTo-Json -Depth 5 | Set-Content $script:AppCacheFile
    
    return $apps
}

# ============================================================================
# Application Selection UI
# ============================================================================

function Show-AppSelectionMenu {
    <#
    .SYNOPSIS
        Interactive menu for selecting applications to uninstall
    #>
    param([array]$Apps)
    
    if ($Apps.Count -eq 0) {
        Write-Warning "No applications found to uninstall"
        return @()
    }
    
    $esc = [char]27
    $selectedIndices = @{}
    $currentIndex = 0
    $pageSize = 15
    $pageStart = 0
    $searchTerm = ""
    $filteredApps = $Apps
    
    # Hide cursor
    [Console]::CursorVisible = $false
    
    try {
        while ($true) {
            Clear-Host
            
            # Header
            Write-Host ""
            Write-Host "$esc[1;35mSelect Applications to Uninstall$esc[0m"
            Write-Host ""
            Write-Host "$esc[90mUse: $($script:Icons.NavUp)$($script:Icons.NavDown) navigate | Space select | Enter confirm | Q quit | / search$esc[0m"
            Write-Host ""
            
            # Search indicator
            if ($searchTerm) {
                Write-Host "$esc[33mSearch:$esc[0m $searchTerm ($($filteredApps.Count) matches)"
                Write-Host ""
            }
            
            # Display apps
            $pageEnd = [Math]::Min($pageStart + $pageSize, $filteredApps.Count)
            
            for ($i = $pageStart; $i -lt $pageEnd; $i++) {
                $app = $filteredApps[$i]
                $isSelected = $selectedIndices.ContainsKey($app.Name)
                $isCurrent = ($i -eq $currentIndex)
                
                # Selection indicator
                $checkbox = if ($isSelected) { "$esc[32m[$($script:Icons.Success)]$esc[0m" } else { "[ ]" }
                
                # Highlight current
                if ($isCurrent) {
                    Write-Host "$esc[7m" -NoNewline  # Reverse video
                }
                
                # App info
                $name = $app.Name
                if ($name.Length -gt 40) {
                    $name = $name.Substring(0, 37) + "..."
                }
                
                $size = $app.SizeHuman
                if (-not $size -or $size -eq "0B") {
                    $size = "N/A"
                }
                
                Write-Host ("  {0} {1,-42} {2,10}" -f $checkbox, $name, $size) -NoNewline
                
                if ($isCurrent) {
                    Write-Host "$esc[0m"  # Reset
                }
                else {
                    Write-Host ""
                }
            }
            
            # Footer
            Write-Host ""
            $selectedCount = $selectedIndices.Count
            if ($selectedCount -gt 0) {
                $totalSize = 0
                foreach ($key in $selectedIndices.Keys) {
                    $app = $Apps | Where-Object { $_.Name -eq $key }
                    if ($app.SizeKB) {
                        $totalSize += $app.SizeKB
                    }
                }
                $totalSizeHuman = Format-ByteSize -Bytes ($totalSize * 1024)
                Write-Host "$esc[33mSelected:$esc[0m $selectedCount apps ($totalSizeHuman)"
            }
            
            # Page indicator
            $totalPages = [Math]::Ceiling($filteredApps.Count / $pageSize)
            $currentPage = [Math]::Floor($pageStart / $pageSize) + 1
            Write-Host "$esc[90mPage $currentPage of $totalPages$esc[0m"
            
            # Handle input
            $key = [Console]::ReadKey($true)
            
            switch ($key.Key) {
                'UpArrow' {
                    if ($currentIndex -gt 0) {
                        $currentIndex--
                        if ($currentIndex -lt $pageStart) {
                            $pageStart = [Math]::Max(0, $pageStart - $pageSize)
                        }
                    }
                }
                'DownArrow' {
                    if ($currentIndex -lt $filteredApps.Count - 1) {
                        $currentIndex++
                        if ($currentIndex -ge $pageStart + $pageSize) {
                            $pageStart += $pageSize
                        }
                    }
                }
                'PageUp' {
                    $pageStart = [Math]::Max(0, $pageStart - $pageSize)
                    $currentIndex = $pageStart
                }
                'PageDown' {
                    $pageStart = [Math]::Min($filteredApps.Count - $pageSize, $pageStart + $pageSize)
                    if ($pageStart -lt 0) { $pageStart = 0 }
                    $currentIndex = $pageStart
                }
                'Spacebar' {
                    $app = $filteredApps[$currentIndex]
                    if ($selectedIndices.ContainsKey($app.Name)) {
                        $selectedIndices.Remove($app.Name)
                    }
                    else {
                        $selectedIndices[$app.Name] = $true
                    }
                }
                'Enter' {
                    if ($selectedIndices.Count -gt 0) {
                        # Return selected apps
                        $selected = $Apps | Where-Object { $selectedIndices.ContainsKey($_.Name) }
                        return $selected
                    }
                }
                'Escape' {
                    return @()
                }
                'Q' {
                    return @()
                }
                'Oem2' {  # Forward slash
                    # Search mode
                    Write-Host ""
                    Write-Host "Search: " -NoNewline
                    [Console]::CursorVisible = $true
                    $searchTerm = Read-Host
                    [Console]::CursorVisible = $false
                    
                    if ($searchTerm) {
                        $filteredApps = $Apps | Where-Object { $_.Name -like "*$searchTerm*" }
                    }
                    else {
                        $filteredApps = $Apps
                    }
                    $currentIndex = 0
                    $pageStart = 0
                }
                'Backspace' {
                    if ($searchTerm) {
                        $searchTerm = ""
                        $filteredApps = $Apps
                        $currentIndex = 0
                        $pageStart = 0
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

# ============================================================================
# Uninstallation
# ============================================================================

function Uninstall-SelectedApps {
    <#
    .SYNOPSIS
        Uninstall the selected applications
    #>
    param([array]$Apps)
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[1;35mUninstalling Applications$esc[0m"
    Write-Host ""
    
    $successCount = 0
    $failCount = 0
    
    foreach ($app in $Apps) {
        Write-Host "$esc[34m$($script:Icons.Arrow)$esc[0m Uninstalling: $($app.Name)" -NoNewline
        
        try {
            if ($app.Source -eq "WindowsStore") {
                # UWP app
                if ($app.PackageFullName) {
                    Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
                    Write-Host " $esc[32m$($script:Icons.Success)$esc[0m"
                    $successCount++
                }
            }
            else {
                # Registry app with uninstall string
                $uninstallString = $app.UninstallString
                
                # Handle different uninstall types
                if ($uninstallString -like "MsiExec.exe*") {
                    # MSI uninstall
                    $productCode = [regex]::Match($uninstallString, '\{[0-9A-F-]+\}').Value
                    if ($productCode) {
                        $process = Start-Process -FilePath "msiexec.exe" `
                            -ArgumentList "/x", $productCode, "/qn", "/norestart" `
                            -Wait -PassThru -NoNewWindow
                        
                        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                            Write-Host " $esc[32m$($script:Icons.Success)$esc[0m"
                            $successCount++
                        }
                        else {
                            Write-Host " $esc[33m(requires interaction)$esc[0m"
                            # Fallback to interactive uninstall
                            Start-Process -FilePath "msiexec.exe" -ArgumentList "/x", $productCode -Wait
                            $successCount++
                        }
                    }
                }
                else {
                    # Direct executable uninstall
                    # Try silent uninstall first
                    $silentArgs = @("/S", "/silent", "/quiet", "-s", "-silent", "-quiet", "/VERYSILENT")
                    $uninstalled = $false
                    
                    foreach ($arg in $silentArgs) {
                        try {
                            $process = Start-Process -FilePath "cmd.exe" `
                                -ArgumentList "/c", "`"$uninstallString`"", $arg `
                                -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
                            
                            if ($process.ExitCode -eq 0) {
                                Write-Host " $esc[32m$($script:Icons.Success)$esc[0m"
                                $successCount++
                                $uninstalled = $true
                                break
                            }
                        }
                        catch { }
                    }
                    
                    if (-not $uninstalled) {
                        # Fallback to interactive
                        Write-Host " $esc[33m(launching uninstaller)$esc[0m"
                        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$uninstallString`"" -Wait
                        $successCount++
                    }
                }
            }
            
            # Clean leftover files
            if ($app.InstallLocation -and (Test-Path $app.InstallLocation)) {
                Write-Host "  $esc[90mCleaning leftover files...$esc[0m"
                Remove-SafeItem -Path $app.InstallLocation -Description "Leftover files" -Recurse
            }
        }
        catch {
            Write-Host " $esc[31m$($script:Icons.Error)$esc[0m"
            Write-Debug "Uninstall failed: $_"
            $failCount++
        }
    }
    
    # Summary
    Write-Host ""
    Write-Host "$esc[1;35mUninstall Complete$esc[0m"
    Write-Host "  Successfully uninstalled: $esc[32m$successCount$esc[0m"
    if ($failCount -gt 0) {
        Write-Host "  Failed: $esc[31m$failCount$esc[0m"
    }
    Write-Host ""
    
    # Clear cache
    if (Test-Path $script:AppCacheFile) {
        Remove-Item $script:AppCacheFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# Main Entry Point
# ============================================================================

function Main {
    # Enable debug if requested
    if ($DebugMode) {
        $env:MOLE_DEBUG = "1"
        $DebugPreference = "Continue"
    }
    
    # Show help
    if ($ShowHelp) {
        Show-UninstallHelp
        return
    }
    
    # Clear screen
    Clear-Host
    
    # Get installed apps
    $apps = Get-InstalledApplications -ForceRescan:$Rescan
    
    if ($apps.Count -eq 0) {
        Write-Warning "No applications found"
        return
    }
    
    Write-Info "Found $($apps.Count) applications"
    
    # Show selection menu
    $selected = Show-AppSelectionMenu -Apps $apps
    
    if ($selected.Count -eq 0) {
        Write-Info "No applications selected"
        return
    }
    
    # Confirm uninstall
    $esc = [char]27
    Clear-Host
    Write-Host ""
    Write-Host "$esc[33mThe following applications will be uninstalled:$esc[0m"
    Write-Host ""
    
    foreach ($app in $selected) {
        Write-Host "  $($script:Icons.List) $($app.Name) ($($app.SizeHuman))"
    }
    
    Write-Host ""
    $confirm = Read-Host "Continue? (y/N)"
    
    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
        Uninstall-SelectedApps -Apps $selected
    }
    else {
        Write-Info "Cancelled"
    }
}

# Run main
Main

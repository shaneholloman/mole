# Mole - Optimize Command
# System optimization and health checks for Windows

#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$DebugMode,
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

$script:OptimizationsApplied = 0
$script:IssuesFound = 0
$script:IssuesFixed = 0

# ============================================================================
# Help
# ============================================================================

function Show-OptimizeHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mMole Optimize$esc[0m - System optimization and health checks"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mole optimize [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  -DryRun      Preview optimizations without applying"
    Write-Host "  -DebugMode   Enable debug logging"
    Write-Host "  -ShowHelp    Show this help message"
    Write-Host ""
    Write-Host "$esc[33mOptimizations:$esc[0m"
    Write-Host "  - Disk defragmentation/TRIM (SSD optimization)"
    Write-Host "  - Windows Search index optimization"
    Write-Host "  - DNS cache flush"
    Write-Host "  - Network optimization"
    Write-Host "  - Startup program analysis"
    Write-Host "  - System file verification"
    Write-Host ""
}

# ============================================================================
# System Health Information
# ============================================================================

function Get-SystemHealth {
    <#
    .SYNOPSIS
        Collect system health metrics
    #>
    
    $health = @{}
    
    # Memory info
    $os = Get-WmiObject Win32_OperatingSystem
    $health.MemoryTotalGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $health.MemoryUsedGB = [Math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
    $health.MemoryUsedPercent = [Math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)
    
    # Disk info
    $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $health.DiskTotalGB = [Math]::Round($disk.Size / 1GB, 0)
    $health.DiskUsedGB = [Math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 0)
    $health.DiskUsedPercent = [Math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 0)
    
    # Uptime
    $uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $health.UptimeDays = [Math]::Round($uptime.TotalDays, 1)
    
    # CPU info
    $cpu = Get-WmiObject Win32_Processor
    $health.CPUName = $cpu.Name
    $health.CPUCores = $cpu.NumberOfLogicalProcessors
    
    return $health
}

function Show-SystemHealth {
    param([hashtable]$Health)
    
    $esc = [char]27
    
    Write-Host "$esc[34m$($script:Icons.Admin)$esc[0m System  " -NoNewline
    Write-Host "$($Health.MemoryUsedGB)/$($Health.MemoryTotalGB)GB RAM | " -NoNewline
    Write-Host "$($Health.DiskUsedGB)/$($Health.DiskTotalGB)GB Disk | " -NoNewline
    Write-Host "Uptime $($Health.UptimeDays)d"
}

# ============================================================================
# Optimization Tasks
# ============================================================================

function Optimize-DiskDrive {
    <#
    .SYNOPSIS
        Optimize disk (defrag for HDD, TRIM for SSD)
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Disk Optimization$esc[0m"
    
    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }
    
    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would optimize $env:SystemDrive"
        $script:OptimizationsApplied++
        return
    }
    
    try {
        # Check if SSD or HDD
        $diskNumber = (Get-Partition -DriveLetter $env:SystemDrive[0]).DiskNumber
        $mediaType = (Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $diskNumber }).MediaType
        
        if ($mediaType -eq "SSD") {
            Write-Host "  Running TRIM on SSD..."
            $null = Optimize-Volume -DriveLetter $env:SystemDrive[0] -ReTrim -ErrorAction Stop
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m SSD TRIM completed"
        }
        else {
            Write-Host "  Running defragmentation on HDD..."
            $null = Optimize-Volume -DriveLetter $env:SystemDrive[0] -Defrag -ErrorAction Stop
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Defragmentation completed"
        }
        $script:OptimizationsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Disk optimization failed: $_"
    }
}

function Optimize-SearchIndex {
    <#
    .SYNOPSIS
        Rebuild Windows Search index if needed
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Windows Search$esc[0m"
    
    $searchService = Get-Service -Name WSearch -ErrorAction SilentlyContinue
    
    if (-not $searchService) {
        Write-Host "  $esc[90mWindows Search service not found$esc[0m"
        return
    }
    
    if ($searchService.Status -ne 'Running') {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Windows Search service is not running"
        
        if ($script:DryRun) {
            Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would start search service"
            return
        }
        
        try {
            Start-Service -Name WSearch -ErrorAction Stop
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Started Windows Search service"
            $script:OptimizationsApplied++
        }
        catch {
            Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not start search service"
        }
    }
    else {
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Search service running"
    }
}

function Clear-DnsCache {
    <#
    .SYNOPSIS
        Clear DNS resolver cache
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) DNS Cache$esc[0m"
    
    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would flush DNS cache"
        $script:OptimizationsApplied++
        return
    }
    
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m DNS cache flushed"
        $script:OptimizationsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Could not flush DNS cache: $_"
    }
}

function Optimize-Network {
    <#
    .SYNOPSIS
        Network stack optimization
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Network Optimization$esc[0m"
    
    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }
    
    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would reset Winsock catalog"
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would reset TCP/IP stack"
        $script:OptimizationsApplied += 2
        return
    }
    
    try {
        # Reset Winsock
        $null = netsh winsock reset 2>&1
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Winsock catalog reset"
        $script:OptimizationsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Winsock reset failed"
    }
    
    try {
        # Flush ARP cache
        $null = netsh interface ip delete arpcache 2>&1
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m ARP cache cleared"
        $script:OptimizationsApplied++
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m ARP cache clear failed"
    }
}

function Get-StartupPrograms {
    <#
    .SYNOPSIS
        Analyze startup programs
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Startup Programs$esc[0m"
    
    $startupPaths = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    )
    
    $startupCount = 0
    
    foreach ($path in $startupPaths) {
        if (Test-Path $path) {
            $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            $props = @($items.PSObject.Properties | Where-Object { 
                $_.Name -notin @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
            })
            $startupCount += $props.Count
        }
    }
    
    # Also check startup folder
    $startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    if (Test-Path $startupFolder) {
        $startupFiles = @(Get-ChildItem -Path $startupFolder -File -ErrorAction SilentlyContinue)
        $startupCount += $startupFiles.Count
    }
    
    if ($startupCount -gt 10) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m $startupCount startup programs (high)"
        Write-Host "  $esc[90mConsider disabling unnecessary startup items in Task Manager$esc[0m"
        $script:IssuesFound++
    }
    elseif ($startupCount -gt 5) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m $startupCount startup programs (moderate)"
        $script:IssuesFound++
    }
    else {
        Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m $startupCount startup programs"
    }
}

function Test-SystemFiles {
    <#
    .SYNOPSIS
        Run System File Checker (SFC)
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) System File Verification$esc[0m"
    
    if (-not (Test-IsAdmin)) {
        Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m Requires administrator privileges"
        return
    }
    
    if ($script:DryRun) {
        Write-Host "  $esc[33m$($script:Icons.DryRun)$esc[0m Would run System File Checker"
        return
    }
    
    Write-Host "  Running System File Checker (this may take several minutes)..."
    
    try {
        $sfcResult = Start-Process -FilePath "sfc.exe" -ArgumentList "/scannow" `
            -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\sfc_output.txt" -ErrorAction Stop
        
        $output = Get-Content "$env:TEMP\sfc_output.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\sfc_output.txt" -Force -ErrorAction SilentlyContinue
        
        if ($output -match "did not find any integrity violations") {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m No integrity violations found"
        }
        elseif ($output -match "found corrupt files and successfully repaired") {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Corrupt files were repaired"
            $script:IssuesFixed++
        }
        elseif ($output -match "found corrupt files but was unable to fix") {
            Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m Found corrupt files that could not be repaired"
            Write-Host "  $esc[90mRun 'DISM /Online /Cleanup-Image /RestoreHealth' then retry SFC$esc[0m"
            $script:IssuesFound++
        }
        else {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m Scan completed"
        }
    }
    catch {
        Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m System File Checker failed: $_"
    }
}

function Test-DiskHealth {
    <#
    .SYNOPSIS
        Check disk health status
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Disk Health$esc[0m"
    
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop
        
        foreach ($disk in $disks) {
            $status = $disk.HealthStatus
            $name = $disk.FriendlyName
            
            if ($status -eq "Healthy") {
                Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m $name - Healthy"
            }
            elseif ($status -eq "Warning") {
                Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m $name - Warning"
                Write-Host "  $esc[90mDisk may have issues, consider backing up data$esc[0m"
                $script:IssuesFound++
            }
            else {
                Write-Host "  $esc[31m$($script:Icons.Error)$esc[0m $name - $status"
                Write-Host "  $esc[31mDisk has critical issues, back up data immediately!$esc[0m"
                $script:IssuesFound++
            }
        }
    }
    catch {
        Write-Host "  $esc[90mCould not check disk health$esc[0m"
    }
}

function Test-WindowsUpdate {
    <#
    .SYNOPSIS
        Check Windows Update status
    #>
    
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[34m$($script:Icons.Arrow) Windows Update$esc[0m"
    
    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $updateSearcher = $updateSession.CreateUpdateSearcher()
        
        Write-Host "  Checking for updates..."
        $searchResult = $updateSearcher.Search("IsInstalled=0")
        
        $importantUpdates = $searchResult.Updates | Where-Object { 
            $_.MsrcSeverity -in @('Critical', 'Important') 
        }
        
        if ($importantUpdates.Count -gt 0) {
            Write-Host "  $esc[33m$($script:Icons.Warning)$esc[0m $($importantUpdates.Count) important updates available"
            Write-Host "  $esc[90mRun Windows Update to install$esc[0m"
            $script:IssuesFound++
        }
        elseif ($searchResult.Updates.Count -gt 0) {
            Write-Host "  $esc[90m$($script:Icons.List)$esc[0m $($searchResult.Updates.Count) optional updates available"
        }
        else {
            Write-Host "  $esc[32m$($script:Icons.Success)$esc[0m System is up to date"
        }
    }
    catch {
        Write-Host "  $esc[90mCould not check Windows Update status$esc[0m"
    }
}

# ============================================================================
# Summary
# ============================================================================

function Show-OptimizeSummary {
    $esc = [char]27
    
    Write-Host ""
    Write-Host "$esc[1;35m" -NoNewline
    if ($script:DryRun) {
        Write-Host "Dry Run Complete - No Changes Made" -NoNewline
    }
    else {
        Write-Host "Optimization Complete" -NoNewline
    }
    Write-Host "$esc[0m"
    Write-Host ""
    
    if ($script:DryRun) {
        Write-Host "  Would apply $esc[33m$($script:OptimizationsApplied)$esc[0m optimizations"
        Write-Host "  Run without -DryRun to apply changes"
    }
    else {
        Write-Host "  Optimizations applied: $esc[32m$($script:OptimizationsApplied)$esc[0m"
        
        if ($script:IssuesFixed -gt 0) {
            Write-Host "  Issues fixed: $esc[32m$($script:IssuesFixed)$esc[0m"
        }
        
        if ($script:IssuesFound -gt 0) {
            Write-Host "  Issues found: $esc[33m$($script:IssuesFound)$esc[0m"
        }
        else {
            Write-Host "  System health: $esc[32mGood$esc[0m"
        }
    }
    
    Write-Host ""
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
        Show-OptimizeHelp
        return
    }
    
    # Set dry-run mode
    $script:DryRun = $DryRun
    
    # Clear screen
    Clear-Host
    
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mOptimize and Check$esc[0m"
    Write-Host ""
    
    if ($script:DryRun) {
        Write-Host "$esc[33m$($script:Icons.DryRun) DRY RUN MODE$esc[0m - No changes will be made"
        Write-Host ""
    }
    
    # Show system health
    $health = Get-SystemHealth
    Show-SystemHealth -Health $health
    
    # Run optimizations
    Optimize-DiskDrive
    Optimize-SearchIndex
    Clear-DnsCache
    Optimize-Network
    
    # Run health checks
    Get-StartupPrograms
    Test-DiskHealth
    Test-WindowsUpdate
    
    # System file check is slow, ask first
    if (-not $script:DryRun -and (Test-IsAdmin)) {
        Write-Host ""
        $runSfc = Read-Host "Run System File Checker? This may take several minutes (y/N)"
        if ($runSfc -eq 'y' -or $runSfc -eq 'Y') {
            Test-SystemFiles
        }
    }
    
    # Summary
    Show-OptimizeSummary
}

# Run main
Main

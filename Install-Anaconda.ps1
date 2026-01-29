#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Anaconda on a remote Windows machine via PowerShell remoting.

.PARAMETER ComputerName
    The hostname or IP address of the target machine.

.PARAMETER Help
    Displays the help menu.

.NOTES
    Exit Codes:
        0   = Success
        1   = Not run as Administrator
        10  = Target unreachable (ping failed)
        11  = DNS resolution failed
        12  = WinRM unavailable
        13  = Remote session failed
        20  = Failed to create temp directory
        21  = Source file not found
        22  = File copy failed
        23  = File copy verification failed
        99  = Unexpected error
        101 = NSIS: Installation cancelled by user
        102 = NSIS: Installation aborted (disk space, permissions, path issues)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [switch]$Help
)

#region Administrator Check
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "ERROR: This script requires Administrator privileges." -ForegroundColor Red
    exit 1
}
#endregion

#region Configuration
$Script:NetworkSharePath = "\\SMB\Shared\"
$Script:InstallerFilename = "Anaconda3-2025.12-1-Windows-x86_64.exe"
$Script:RemoteTempPath = "C:\Temp"
$Script:AnacondaInstallPath = "C:\ProgramData\Anaconda3"
$Script:AddToPath = $true
$Script:RegisterAsSystemPython = $false
#endregion

#region Exit Codes
$Script:EXIT_SUCCESS = 0
$Script:EXIT_NOT_ADMIN = 1
$Script:EXIT_PING_FAILURE = 10
$Script:EXIT_DNS_FAILURE = 11
$Script:EXIT_WINRM_FAILURE = 12
$Script:EXIT_REMOTE_SESSION_FAILURE = 13
$Script:EXIT_DIRECTORY_FAILURE = 20
$Script:EXIT_SOURCE_NOT_FOUND = 21
$Script:EXIT_COPY_FAILURE = 22
$Script:EXIT_COPY_VERIFY_FAILURE = 23
$Script:EXIT_UNEXPECTED = 99
$Script:NSIS_EXIT_CODE_OFFSET = 100
#endregion

#region Help
function Show-Help {
    Write-Host ""
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "  Anaconda Remote Installer" -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "DESCRIPTION:" -ForegroundColor Yellow
    Write-Host "  Installs Anaconda on a remote Windows machine via PowerShell remoting (WinRM)."
    Write-Host "  Requires administrative privileges to execute."
    Write-Host ""

    Write-Host "PARAMETERS:" -ForegroundColor Yellow
    Write-Host "  -ComputerName <string>" -ForegroundColor Green
    Write-Host "      The hostname or IP address of the target computer."
    Write-Host "      Required. If not provided, this help menu is displayed."
    Write-Host ""
    Write-Host "  -Help" -ForegroundColor Green
    Write-Host "      Displays this help message."
    Write-Host ""

    Write-Host "CONFIGURATION:" -ForegroundColor Yellow
    Write-Host "  Edit these variables in the script (lines 50-55):" -ForegroundColor Gray
    Write-Host "    NetworkSharePath      UNC path to installer       \\SMB\Shared\" -ForegroundColor Gray
    Write-Host "    InstallerFilename     Installer .exe filename     Anaconda3-2025.12-1-Windows-x86_64.exe" -ForegroundColor Gray
    Write-Host "    RemoteTempPath        Temp folder on remote       C:\Temp" -ForegroundColor Gray
    Write-Host "    AnacondaInstallPath   Install location            C:\ProgramData\Anaconda3" -ForegroundColor Gray
    Write-Host "    AddToPath             Add to system PATH          `$true" -ForegroundColor Gray
    Write-Host "    RegisterAsSystemPython Register as default Python `$false" -ForegroundColor Gray
    Write-Host ""

    Write-Host "EXAMPLES:" -ForegroundColor Yellow
    Write-Host "  Example 1: Display help" -ForegroundColor Cyan
    Write-Host "    .\Install-Anaconda.ps1"
    Write-Host "    .\Install-Anaconda.ps1 -Help"
    Write-Host ""
    Write-Host "  Example 2: Install using hostname" -ForegroundColor Cyan
    Write-Host "    .\Install-Anaconda.ps1 -ComputerName ""SERVER01"""
    Write-Host ""
    Write-Host "  Example 3: Install using IP address" -ForegroundColor Cyan
    Write-Host "    .\Install-Anaconda.ps1 -ComputerName ""10.0.0.100"""
    Write-Host ""

    Write-Host "PRE-FLIGHT CHECKS:" -ForegroundColor Yellow
    Write-Host "  The script performs the following checks before installation:"
    Write-Host "    1. Administrator privileges (local)"
    Write-Host "    2. DNS resolution (hostname lookup)"
    Write-Host "    3. Network connectivity (ICMP ping)"
    Write-Host "    4. PowerShell remoting (WinRM)"
    Write-Host ""

    Write-Host "EXIT CODES:" -ForegroundColor Yellow
    Write-Host "    0   = Success" -ForegroundColor Green
    Write-Host "    1   = Not run as Administrator" -ForegroundColor Red
    Write-Host "   10   = Target unreachable (ping failed)" -ForegroundColor Red
    Write-Host "   11   = DNS resolution failed" -ForegroundColor Red
    Write-Host "   12   = WinRM unavailable" -ForegroundColor Red
    Write-Host "   13   = Remote session failed" -ForegroundColor Red
    Write-Host "   20   = Failed to create temp directory" -ForegroundColor Red
    Write-Host "   21   = Source file not found" -ForegroundColor Red
    Write-Host "   22   = File copy failed" -ForegroundColor Red
    Write-Host "   23   = File copy verification failed" -ForegroundColor Red
    Write-Host "   99   = Unexpected error" -ForegroundColor Red
    Write-Host "  101   = NSIS: Installation cancelled by user" -ForegroundColor Red
    Write-Host "  102   = NSIS: Installation aborted (disk/permissions/path)" -ForegroundColor Red
    Write-Host ""

    Write-Host "NOTES:" -ForegroundColor Yellow
    Write-Host "  - Requires PowerShell 5.1 or higher"
    Write-Host "  - Must be run with administrator privileges"
    Write-Host "  - Remote computer must have WinRM enabled (Enable-PSRemoting -Force)"
    Write-Host "  - Network share must be accessible from the local machine"
    Write-Host ""
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host ""
}
#endregion

#region Pre-flight Checks
function Test-TargetConnectivity {
    param([string]$HostName)

    Write-Host "Testing connectivity to '$HostName'..." -ForegroundColor Cyan

    # DNS resolution test (first - if we can't resolve, no point continuing)
    try {
        $null = [System.Net.Dns]::GetHostEntry($HostName)
        Write-Host "  DNS: OK" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Cannot resolve '$HostName' in DNS." -ForegroundColor Red
        return $Script:EXIT_DNS_FAILURE
    }

    # Ping test (second - verify network reachability)
    if (-not (Test-Connection -ComputerName $HostName -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: Cannot reach '$HostName' via ICMP ping." -ForegroundColor Red
        return $Script:EXIT_PING_FAILURE
    }
    Write-Host "  Ping: OK" -ForegroundColor Green

    # WinRM test (third - verify PowerShell remoting)
    try {
        $null = Test-WSMan -ComputerName $HostName -ErrorAction Stop
        Write-Host "  WinRM: OK" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: WinRM unavailable on '$HostName': $($_.Exception.Message)" -ForegroundColor Red
        return $Script:EXIT_WINRM_FAILURE
    }

    return $Script:EXIT_SUCCESS
}
#endregion

#region Remote ScriptBlock (install only - file copy handled locally)
$Script:RemoteInstallScriptBlock = {
    param(
        [string]$InstallerPath,
        [string]$InstallPath,
        [bool]$AddToPath,
        [bool]$RegisterAsSystemPython
    )

    $result = @{ ExitCode = 0; Messages = @() }

    try {
        # Verify installer exists
        if (-not (Test-Path $InstallerPath)) {
            $result.Messages += "ERROR: Installer not found at: $InstallerPath"
            $result.ExitCode = 21
            return $result
        }
        $result.Messages += "Using installer: $InstallerPath"

        # Run installer
        $addToPathValue = if ($AddToPath) { 1 } else { 0 }
        $registerPythonValue = if ($RegisterAsSystemPython) { 1 } else { 0 }
        $installerArgs = "/S /AddToPath=$addToPathValue /RegisterPython=$registerPythonValue /D=$InstallPath"

        $result.Messages += "Running installer..."
        $result.Messages += "Args: $installerArgs"

        $process = Start-Process -FilePath $InstallerPath -ArgumentList $installerArgs -Wait -PassThru -NoNewWindow
        $nsisExitCode = $process.ExitCode

        $result.Messages += "NSIS exit code: $nsisExitCode"

        if ($nsisExitCode -eq 0) {
            $result.Messages += "Installation successful"

            $condaPath = Join-Path $InstallPath "Scripts\conda.exe"
            if (Test-Path $condaPath) {
                $result.Messages += "Verified: conda.exe exists"
            }
            else {
                $result.Messages += "WARNING: conda.exe not found"
            }
        }
        else {
            $result.Messages += "ERROR: Installation failed with NSIS code $nsisExitCode"
            $result.ExitCode = 100 + $nsisExitCode
            return $result
        }

        # Cleanup
        try {
            Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue
            $result.Messages += "Cleaned up installer"
        }
        catch {
            $result.Messages += "WARNING: Cleanup failed"
        }

        return $result
    }
    catch {
        $result.Messages += "ERROR: $($_.Exception.Message)"
        $result.ExitCode = 99
        return $result
    }
}
#endregion

#region File Copy
function Copy-InstallerToRemote {
    param([string]$TargetHost)

    $source = Join-Path $Script:NetworkSharePath $Script:InstallerFilename
    $destination = "\\$TargetHost\C$\Temp"
    $destinationFile = Join-Path $destination $Script:InstallerFilename

    Write-Host "Preparing file copy..." -ForegroundColor Cyan

    # Check if destination directory exists, create if not
    Write-Host "  Checking destination directory..." -ForegroundColor Gray
    try {
        if (-not (Test-Path $destination)) {
            Write-Host "  Creating $destination" -ForegroundColor Gray
            New-Item -Path $destination -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        Write-Host "  Destination directory: OK" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Failed to create directory: $($_.Exception.Message)" -ForegroundColor Red
        return $Script:EXIT_DIRECTORY_FAILURE
    }

    # Check if source file exists
    Write-Host "  Checking source file..." -ForegroundColor Gray
    if (-not (Test-Path $source)) {
        Write-Host "ERROR: Source file not found: $source" -ForegroundColor Red
        return $Script:EXIT_SOURCE_NOT_FOUND
    }
    Write-Host "  Source file: OK" -ForegroundColor Green

    # Copy file to destination
    Write-Host "  Copying file..." -ForegroundColor Gray
    Write-Host "    From: $source" -ForegroundColor Gray
    Write-Host "    To:   $destination" -ForegroundColor Gray
    try {
        Copy-Item -Path $source -Destination $destination -Force -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Copy failed: $($_.Exception.Message)" -ForegroundColor Red
        return $Script:EXIT_COPY_FAILURE
    }

    # Verify file was copied
    Write-Host "  Verifying copy..." -ForegroundColor Gray
    if (-not (Test-Path $destinationFile)) {
        Write-Host "ERROR: File copy verification failed. File not found at: $destinationFile" -ForegroundColor Red
        return $Script:EXIT_COPY_VERIFY_FAILURE
    }
    Write-Host "  Copy verified: OK" -ForegroundColor Green

    return $Script:EXIT_SUCCESS
}
#endregion

#region Main
function Invoke-RemoteInstall {
    param([string]$TargetHost)

    $remoteInstallerPath = Join-Path $Script:RemoteTempPath $Script:InstallerFilename
    Write-Host "Executing installation..." -ForegroundColor Cyan

    try {
        $remoteResult = Invoke-Command -ComputerName $TargetHost -ScriptBlock $Script:RemoteInstallScriptBlock -ArgumentList @(
            $remoteInstallerPath,
            $Script:AnacondaInstallPath,
            $Script:AddToPath,
            $Script:RegisterAsSystemPython
        ) -ErrorAction Stop

        # Display remote messages
        foreach ($msg in $remoteResult.Messages) {
            if ($msg -match "^ERROR:") {
                Write-Host "  $msg" -ForegroundColor Red
            }
            elseif ($msg -match "^WARNING:") {
                Write-Host "  $msg" -ForegroundColor Yellow
            }
            else {
                Write-Host "  $msg" -ForegroundColor Gray
            }
        }

        return $remoteResult.ExitCode
    }
    catch {
        Write-Host "ERROR: Remote session failed: $($_.Exception.Message)" -ForegroundColor Red
        return $Script:EXIT_REMOTE_SESSION_FAILURE
    }
}
#endregion

#region Execution
if ($Help -or [string]::IsNullOrWhiteSpace($ComputerName)) {
    Show-Help
    exit 0
}

Write-Host ""
Write-Host "ANACONDA REMOTE INSTALLER" -ForegroundColor Cyan
Write-Host "Target: $ComputerName" -ForegroundColor Cyan
Write-Host ""

# Step 1: Pre-flight
$exitCode = Test-TargetConnectivity -HostName $ComputerName
if ($exitCode -ne 0) { exit $exitCode }

# Step 2: Copy installer via admin share
$exitCode = Copy-InstallerToRemote -TargetHost $ComputerName
if ($exitCode -ne 0) { exit $exitCode }

# Step 3: Run installation remotely
$exitCode = Invoke-RemoteInstall -TargetHost $ComputerName

# Summary
Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "SUCCESS" -ForegroundColor Green
}
else {
    Write-Host "FAILED (Exit code: $exitCode)" -ForegroundColor Red
}

exit $exitCode
#endregion
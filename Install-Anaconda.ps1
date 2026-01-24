#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Anaconda on a remote Windows machine via PowerShell remoting.

.PARAMETER ComputerName
    The hostname or IP address of the target machine. Prompts if not provided.

.NOTES
    Exit Codes:
        0   = Success
        1   = Not run as Administrator
        2   = No hostname provided
        10  = Target unreachable (ping failed)
        12  = WinRM unavailable
        13  = Remote session failed
        20  = Failed to create temp directory
        21  = File copy failed
        99  = Unexpected error
        101 = NSIS: Installation cancelled by user
        102 = NSIS: Installation aborted (disk space, permissions, path issues)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ComputerName
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
$Script:EXIT_NO_HOSTNAME = 2
$Script:EXIT_PING_FAILURE = 10
$Script:EXIT_WINRM_FAILURE = 12
$Script:EXIT_REMOTE_SESSION_FAILURE = 13
$Script:EXIT_DIRECTORY_FAILURE = 20
$Script:EXIT_COPY_FAILURE = 21
$Script:EXIT_UNEXPECTED = 99
$Script:NSIS_EXIT_CODE_OFFSET = 100
#endregion

#region Pre-flight Checks
function Test-TargetConnectivity {
    param([string]$HostName)

    Write-Host "Testing connectivity to '$HostName'..." -ForegroundColor Cyan

    # Ping test
    if (-not (Test-Connection -ComputerName $HostName -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: Cannot reach '$HostName' via ICMP ping." -ForegroundColor Red
        return $Script:EXIT_PING_FAILURE
    }
    Write-Host "  Ping: OK" -ForegroundColor Green

    # WinRM test
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

#region Remote ScriptBlock
$Script:RemoteInstallScriptBlock = {
    param(
        [string]$NetworkSharePath,
        [string]$InstallerFilename,
        [string]$TempPath,
        [string]$InstallPath,
        [bool]$AddToPath,
        [bool]$RegisterAsSystemPython
    )

    $result = @{ ExitCode = 0; Messages = @() }

    try {
        # Create temp directory
        if (-not (Test-Path $TempPath)) {
            try {
                New-Item -Path $TempPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                $result.Messages += "Created directory: $TempPath"
            }
            catch {
                $result.Messages += "ERROR: Failed to create directory: $($_.Exception.Message)"
                $result.ExitCode = 20
                return $result
            }
        }

        # Copy installer (commented out for testing - assumes file already in C:\Temp)
        # $sourcePath = Join-Path $NetworkSharePath $InstallerFilename
        $destinationPath = Join-Path $TempPath $InstallerFilename

        # $result.Messages += "Copying from: $sourcePath"
        # if (-not (Test-Path $sourcePath)) {
        #     $result.Messages += "ERROR: Source file not found: $sourcePath"
        #     $result.ExitCode = 21
        #     return $result
        # }
        # try {
        #     Copy-Item -Path $sourcePath -Destination $destinationPath -Force -ErrorAction Stop
        #     $result.Messages += "Copy complete"
        # }
        # catch {
        #     $result.Messages += "ERROR: Copy failed: $($_.Exception.Message)"
        #     $result.ExitCode = 21
        #     return $result
        # }

        # Verify installer exists in C:\Temp
        if (-not (Test-Path $destinationPath)) {
            $result.Messages += "ERROR: Installer not found at: $destinationPath"
            $result.ExitCode = 21
            return $result
        }
        $result.Messages += "Using installer: $destinationPath"

        # Run installer
        $addToPathValue = if ($AddToPath) { 1 } else { 0 }
        $registerPythonValue = if ($RegisterAsSystemPython) { 1 } else { 0 }
        $installerArgs = "/S /AddToPath=$addToPathValue /RegisterPython=$registerPythonValue /D=$InstallPath"

        $result.Messages += "Running installer..."
        $result.Messages += "Args: $installerArgs"

        $process = Start-Process -FilePath $destinationPath -ArgumentList $installerArgs -Wait -PassThru -NoNewWindow
        $nsisExitCode = $process.ExitCode

        $result.Messages += "NSIS exit code: $nsisExitCode"

        if ($nsisExitCode -eq 0) {
            $result.Messages += "Installation successful"

            # Verify
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

        # Cleanup (commented out for testing)
        # try {
        #     Remove-Item $destinationPath -Force -ErrorAction SilentlyContinue
        #     $result.Messages += "Cleaned up installer"
        # }
        # catch {
        #     $result.Messages += "WARNING: Cleanup failed"
        # }

        return $result
    }
    catch {
        $result.Messages += "ERROR: $($_.Exception.Message)"
        $result.ExitCode = 99
        return $result
    }
}
#endregion

#region Main
function Invoke-RemoteInstall {
    param([string]$TargetHost)

    Write-Host ""
    Write-Host "ANACONDA REMOTE INSTALLER" -ForegroundColor Cyan
    Write-Host "Target: $TargetHost" -ForegroundColor Cyan
    Write-Host ""

    # Pre-flight
    $exitCode = Test-TargetConnectivity -HostName $TargetHost
    if ($exitCode -ne 0) { return $exitCode }

    # Remote install
    Write-Host "Executing remote installation..." -ForegroundColor Cyan

    try {
        $remoteResult = Invoke-Command -ComputerName $TargetHost -ScriptBlock $Script:RemoteInstallScriptBlock -ArgumentList @(
            $Script:NetworkSharePath,
            $Script:InstallerFilename,
            $Script:RemoteTempPath,
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

        $exitCode = $remoteResult.ExitCode
    }
    catch {
        Write-Host "ERROR: Remote session failed: $($_.Exception.Message)" -ForegroundColor Red
        $exitCode = $Script:EXIT_REMOTE_SESSION_FAILURE
    }

    # Summary
    Write-Host ""
    if ($exitCode -eq 0) {
        Write-Host "SUCCESS" -ForegroundColor Green
    }
    else {
        Write-Host "FAILED (Exit code: $exitCode)" -ForegroundColor Red
    }

    return $exitCode
}
#endregion

#region Execution
if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    Write-Host ""
    Write-Host "ANACONDA REMOTE INSTALLER" -ForegroundColor Cyan
    Write-Host ""
    $ComputerName = Read-Host "Enter target hostname"

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        Write-Host "ERROR: No hostname provided." -ForegroundColor Red
        exit $Script:EXIT_NO_HOSTNAME
    }
}

exit (Invoke-RemoteInstall -TargetHost $ComputerName)
#endregion
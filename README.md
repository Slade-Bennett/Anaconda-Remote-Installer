# Anaconda Remote Installer

A PowerShell script that installs Anaconda on remote Windows machines via PowerShell remoting (WinRM).

## Requirements

- **Local machine**: PowerShell 5.1+, Administrator privileges
- **Remote machine**: WinRM enabled, network access to the installer location
- **Network**: ICMP (ping) allowed between machines

## Usage

### Interactive Mode
```powershell
.\Install-Anaconda.ps1
```
Prompts for the target hostname.

### Direct Mode
```powershell
.\Install-Anaconda.ps1 -ComputerName "SERVER01"
.\Install-Anaconda.ps1 -ComputerName "10.0.0.100"
```

## Configuration

Edit these variables at the top of the script (lines 42-47):

| Variable | Description | Default |
|----------|-------------|---------|
| `NetworkSharePath` | UNC path to installer location | `\\SMB\Shared\` |
| `InstallerFilename` | Anaconda installer filename | `Anaconda3-2025.12-1-Windows-x86_64.exe` |
| `RemoteTempPath` | Temp directory on remote machine | `C:\Temp` |
| `AnacondaInstallPath` | Anaconda install location | `C:\ProgramData\Anaconda3` |
| `AddToPath` | Add Anaconda to system PATH | `$true` |
| `RegisterAsSystemPython` | Register as default Python | `$false` |

## How It Works

### Execution Flow

```
LOCAL MACHINE
─────────────────────────────────────────────────────
1. Administrator Check
   - Verifies script is running elevated
   - Exits with code 1 if not admin

2. Hostname Input
   - Uses -ComputerName parameter if provided
   - Otherwise prompts via Read-Host

3. Pre-flight Connectivity Checks
   - ICMP ping test (2 packets)
   - WinRM availability test (Test-WSMan)

4. Invoke-Command to Remote Machine
         │
         ▼
REMOTE MACHINE (via PowerShell Remoting)
─────────────────────────────────────────────────────
5. Create Temp Directory
   - Creates C:\Temp if it doesn't exist

6. Copy Installer*
   - Copies from network share to C:\Temp
   - Remote machine needs access to the share

7. Run Silent Installation
   - Executes: installer.exe /S /AddToPath=1 /D=<path>
   - Waits for process to complete
   - Captures NSIS exit code

8. Verify Installation
   - Checks if conda.exe exists in Scripts folder

9. Cleanup*
   - Removes installer from C:\Temp

10. Return result object to local machine
         │
         ▼
LOCAL MACHINE
─────────────────────────────────────────────────────
11. Display Remote Messages
    - Color-coded: Red=ERROR, Yellow=WARNING, Gray=INFO

12. Exit with Appropriate Code
```

*Currently commented out for testing

### Key Components

#### Pre-flight Checks (`Test-TargetConnectivity`)
Validates connectivity before attempting installation:
- **Ping Test**: `Test-Connection` with 2 ICMP packets
- **WinRM Test**: `Test-WSMan` verifies PowerShell remoting is available

#### Remote ScriptBlock (`$Script:RemoteInstallScriptBlock`)
Executes entirely on the remote machine via `Invoke-Command`:
1. Creates temp directory if needed
2. Copies installer from network share (currently disabled)
3. Builds installer arguments from configuration
4. Runs installer silently with `Start-Process -Wait`
5. Verifies `conda.exe` exists after installation
6. Returns result object with exit code and messages

#### Main Function (`Invoke-RemoteInstall`)
Orchestrates the installation:
1. Displays banner with target hostname
2. Runs connectivity checks
3. Executes remote scriptblock via `Invoke-Command`
4. Displays color-coded messages from remote execution
5. Returns final exit code

### Anaconda Silent Install Arguments

| Switch | Description |
|--------|-------------|
| `/S` | Silent mode (no GUI) |
| `/AddToPath=1` | Add to system PATH (0=no, 1=yes) |
| `/RegisterPython=0` | Register as system Python (0=no, 1=yes) |
| `/D=<path>` | Installation directory (must be last, no quotes) |

## Exit Codes

| Code | Description |
|------|-------------|
| 0 | Success |
| 1 | Not run as Administrator |
| 2 | No hostname provided |
| 10 | Target unreachable (ping failed) |
| 12 | WinRM unavailable on target |
| 13 | Remote session failed |
| 20 | Failed to create temp directory |
| 21 | File copy failed / installer not found |
| 99 | Unexpected error |
| 101 | NSIS: Installation cancelled by user |
| 102 | NSIS: Installation aborted (disk space, permissions, path) |

### NSIS Exit Codes

Anaconda uses NSIS (Nullsoft Scriptable Install System). NSIS codes are passed through as `100 + code`:
- **0**: Success
- **1**: User cancelled
- **2**: Script aborted (error during install)

## Troubleshooting

### "WinRM unavailable"
Enable WinRM on the remote machine:
```powershell
Enable-PSRemoting -Force
```

### "Access denied" on network share
The remote session runs under the machine's computer account, not your user account. Grant the remote machine's computer account read access to the share.

### "Installer not found"
Verify the filename matches exactly, including `.exe` extension.

### Installation succeeds but conda.exe not found
NSIS may report success when installation fails silently. Check:
- Sufficient disk space
- Write permissions to install path
- Path length under 260 characters
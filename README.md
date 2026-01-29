# Anaconda Remote Installer

A PowerShell script that installs Anaconda on remote Windows machines via PowerShell remoting (WinRM).

## Requirements

- **Local machine**: PowerShell 5.1+, Administrator privileges
- **Remote machine**: WinRM enabled, admin share accessible (`\\hostname\C$`)
- **Network**: DNS resolution, ICMP (ping), and WinRM (TCP 5985/5986) allowed

## Usage

```powershell
# Display help
.\Install-Anaconda.ps1
.\Install-Anaconda.ps1 -Help

# Install using hostname
.\Install-Anaconda.ps1 -ComputerName "SERVER01"

# Install using IP address
.\Install-Anaconda.ps1 -ComputerName "10.0.0.100"
```

## Configuration

Edit these variables at the top of the script (lines 50-55):

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
   - Exits with code 1 if not admin (red text)

2. Input Check
   - If no -ComputerName provided, displays help menu
   - If -Help flag used, displays help menu

3. Pre-flight Connectivity Checks (Test-TargetConnectivity)
   - DNS resolution ([System.Net.Dns]::GetHostEntry)
   - ICMP ping test (Test-Connection, 2 packets)
   - WinRM availability test (Test-WSMan)

4. File Copy via Admin Share (Copy-InstallerToRemote)
   - Checks/creates \\hostname\C$\Temp directory
   - Verifies source installer exists on network share
   - Copies installer via admin share (avoids double-hop)
   - Verifies file exists at destination

5. Remote Installation (Invoke-RemoteInstall)
         │
         ▼
REMOTE MACHINE (via Invoke-Command)
─────────────────────────────────────────────────────
6. Run Silent Installation
   - Executes: installer.exe /S /AddToPath=1 /D=<path>
   - Waits for process to complete
   - Captures NSIS exit code

7. Verify Installation
   - Checks if conda.exe exists in Scripts folder

8. Cleanup
   - Removes installer from C:\Temp

9. Return result object to local machine
         │
         ▼
LOCAL MACHINE
─────────────────────────────────────────────────────
10. Display Remote Messages
    - Color-coded: Red=ERROR, Yellow=WARNING, Gray=INFO

11. Exit with Appropriate Code
```

### Key Components

#### Pre-flight Checks (`Test-TargetConnectivity`)
Validates connectivity before attempting installation:
- **DNS Test**: Resolves hostname via `[System.Net.Dns]::GetHostEntry`
- **Ping Test**: `Test-Connection` with 2 ICMP packets
- **WinRM Test**: `Test-WSMan` verifies PowerShell remoting is available

#### File Copy (`Copy-InstallerToRemote`)
Copies installer to remote machine via admin share:
- Uses `\\hostname\C$\Temp` path (avoids WinRM double-hop issue)
- Creates destination directory if it doesn't exist
- Verifies source file exists before copying
- Confirms file arrived at destination after copy

#### Remote ScriptBlock (`$Script:RemoteInstallScriptBlock`)
Executes on the remote machine via `Invoke-Command`:
1. Verifies installer exists at `C:\Temp`
2. Builds installer arguments from configuration
3. Runs installer silently with `Start-Process -Wait`
4. Verifies `conda.exe` exists after installation
5. Cleans up installer file
6. Returns result object with exit code and messages

#### Main Function (`Invoke-RemoteInstall`)
Executes the remote scriptblock and handles results:
1. Calls `Invoke-Command` with the scriptblock
2. Displays color-coded messages from remote execution
3. Returns final exit code

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
| 10 | Target unreachable (ping failed) |
| 11 | DNS resolution failed |
| 12 | WinRM unavailable on target |
| 13 | Remote session failed |
| 20 | Failed to create temp directory |
| 21 | Source file not found |
| 22 | File copy failed |
| 23 | File copy verification failed |
| 99 | Unexpected error |
| 101 | NSIS: Installation cancelled by user |
| 102 | NSIS: Installation aborted (disk space, permissions, path) |

### NSIS Exit Codes

Anaconda uses NSIS (Nullsoft Scriptable Install System). NSIS codes are passed through as `100 + code`:
- **0**: Success
- **1**: User cancelled
- **2**: Script aborted (error during install)

## Troubleshooting

### "Cannot resolve hostname in DNS"
The hostname could not be resolved. Verify:
- Hostname is spelled correctly
- DNS server is reachable
- Host has a DNS record (try `nslookup hostname`)

### "WinRM unavailable"
Enable WinRM on the remote machine:
```powershell
Enable-PSRemoting -Force
```

### "Failed to create temp directory" or "Access denied"
The admin share (`\\hostname\C$`) is not accessible. Verify:
- You have administrative rights on the remote machine
- File and Printer Sharing is enabled
- Admin shares are not disabled via Group Policy

### "Source file not found"
Verify the installer path and filename:
- Check `NetworkSharePath` points to correct location
- Check `InstallerFilename` matches exactly, including `.exe` extension
- Verify you have read access to the network share

### Installation succeeds but conda.exe not found
NSIS may report success when installation fails silently. Check:
- Sufficient disk space on remote machine
- Write permissions to install path
- Path length under 260 characters
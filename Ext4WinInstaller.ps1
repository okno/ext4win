#requires -Version 5.1
<#
Ext4Win Network Installer / Updater / Uninstaller (single file)

Key goals (Dev/Sec/Op):
- NO git required (downloads ZIP from GitHub)
- Uses wget if present (or PowerShell alias), else curl.exe, else Invoke-WebRequest
- Creates scheduled tasks with "HighestAvailable" + InteractiveToken (no password prompts)
- Supports: Install, Update, Uninstall
- Tray + Agent start automatically at logon (and can be started immediately)

Repo: https://github.com/okno/ext4win
#>

[CmdletBinding(DefaultParameterSetName='Install')]
param(
    [Parameter()] [string] $InstallDir = 'C:\ext4win',
    [Parameter()] [string] $Repo = 'okno/ext4win',
    [Parameter()] [string] $Branch = 'main',
    [Parameter()] [string] $ZipUrl,
    [Parameter()] [string] $Distro = 'Debian',
    [Parameter()] [ValidateSet('auto','it','en')] [string] $Language = 'auto',

    [Parameter(ParameterSetName='Uninstall')] [switch] $Uninstall,
    [Parameter(ParameterSetName='Update')]    [switch] $Update,

    [Parameter()] [switch] $NoTray,
    [Parameter()] [switch] $NoAgent,
    [Parameter()] [switch] $Force
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

function Write-HostInfo([string]$msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-HostWarn([string]$msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-HostErr([string]$msg)  { Write-Host $msg -ForegroundColor Red }

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Ensure-Admin {
    if (-not (Test-IsAdmin)) {
        throw "Esegui questo installer come Amministratore (PowerShell 'Esegui come amministratore')."
    }
}

function Ensure-Dir([string]$p) {
    New-Item -ItemType Directory -Force -Path $p | Out-Null
}

function Escape-Xml([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'","&apos;")
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory=$true)] [string] $Url,
        [Parameter(Mandatory=$true)] [string] $OutFile
    )

    # Prefer: real wget.exe if installed, else PowerShell alias wget, else curl.exe, else Invoke-WebRequest
    $cmd = Get-Command wget -ErrorAction SilentlyContinue

    if ($cmd -and $cmd.CommandType -eq 'Application') {
        Write-HostInfo "Download (wget.exe): $Url"
        & $cmd.Source -O $OutFile $Url | Out-Null
        return
    }

    if ($cmd -and $cmd.CommandType -eq 'Alias') {
        Write-HostInfo "Download (wget alias -> Invoke-WebRequest): $Url"
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            wget -Uri $Url -OutFile $OutFile -UseBasicParsing | Out-Null
        } else {
            wget -Uri $Url -OutFile $OutFile | Out-Null
        }
        return
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        Write-HostInfo "Download (curl.exe): $Url"
        & $curl.Source -L -o $OutFile $Url | Out-Null
        return
    }

    Write-HostInfo "Download (Invoke-WebRequest): $Url"
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing | Out-Null
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile | Out-Null
    }
}

function Get-DefaultZipUrl {
    if (-not [string]::IsNullOrWhiteSpace($ZipUrl)) { return $ZipUrl }
    # NOTE: no Git required. This is the official GitHub ZIP for the branch.
    return ("https://github.com/{0}/archive/refs/heads/{1}.zip" -f $Repo, $Branch)
}

function Stop-TaskSafe([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    try { & $schtasks /End /TN $name 2>$null | Out-Null } catch { }
}

function Delete-TaskSafe([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    try { & $schtasks /Delete /TN $name /F 2>$null | Out-Null } catch { }
}

function Run-TaskSafe([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    try { & $schtasks /Run /TN $name 2>$null | Out-Null } catch { }
}

function New-TaskXml {
    param(
        [Parameter(Mandatory=$true)] [string] $UserSid,
        [Parameter(Mandatory=$true)] [string] $Command,
        [Parameter(Mandatory=$true)] [string] $Arguments,
        [Parameter(Mandatory=$true)] [string] $WorkingDirectory,
        [Parameter(Mandatory=$true)] [bool]   $OnLogon,
        [Parameter()] [bool] $Hidden = $true
    )

    $cmdEsc = Escape-Xml $Command
    $argEsc = Escape-Xml $Arguments
    $wdEsc  = Escape-Xml $WorkingDirectory
    $hid    = if ($Hidden) { 'true' } else { 'false' }

    $triggers = if ($OnLogon) {
@"
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$UserSid</UserId>
    </LogonTrigger>
  </Triggers>
"@
    } else {
@"
  <Triggers />
"@
    }

@"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>Ext4Win</Author>
    <Description>Ext4Win task</Description>
  </RegistrationInfo>
$triggers
  <Principals>
    <Principal id="Author">
      <UserId>$UserSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>$hid</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$cmdEsc</Command>
      <Arguments>$argEsc</Arguments>
      <WorkingDirectory>$wdEsc</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Ensure-TaskXml {
    param(
        [Parameter(Mandatory=$true)] [string] $Name,
        [Parameter(Mandatory=$true)] [string] $Xml
    )
    $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $tmp = Join-Path $env:TEMP ("ext4win_task_{0}.xml" -f ([Guid]::NewGuid().ToString('N')))
    Set-Content -Path $tmp -Value $Xml -Encoding Unicode
    try {
        & $schtasks /Create /TN $Name /XML $tmp /F | Out-Null
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $tmp | Out-Null
    }
}

function Merge-Config {
    param([string]$CfgPath)

    $obj = $null
    if (Test-Path $CfgPath) {
        try { $obj = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $obj = $null }
    }
    if ($null -eq $obj) { $obj = [pscustomobject]@{} }

    # Keep user's values when present; set defaults when missing
    if (-not ($obj.PSObject.Properties.Name -contains 'install_dir')) { $obj | Add-Member -NotePropertyName install_dir -NotePropertyValue $InstallDir -Force }
    if (-not ($obj.PSObject.Properties.Name -contains 'distro')) { $obj | Add-Member -NotePropertyName distro -NotePropertyValue $Distro -Force } else { $obj.distro = $Distro }
    if (-not ($obj.PSObject.Properties.Name -contains 'language')) { $obj | Add-Member -NotePropertyName language -NotePropertyValue $Language -Force } else { $obj.language = $Language }

    if (-not ($obj.PSObject.Properties.Name -contains 'task_tray'))    { $obj | Add-Member -NotePropertyName task_tray -NotePropertyValue 'Ext4Win_Tray' -Force }
    if (-not ($obj.PSObject.Properties.Name -contains 'task_agent'))   { $obj | Add-Member -NotePropertyName task_agent -NotePropertyValue 'Ext4Win_Agent' -Force }
    if (-not ($obj.PSObject.Properties.Name -contains 'task_mount'))   { $obj | Add-Member -NotePropertyName task_mount -NotePropertyValue 'Ext4Win_MountAll' -Force }
    if (-not ($obj.PSObject.Properties.Name -contains 'task_unmount')) { $obj | Add-Member -NotePropertyName task_unmount -NotePropertyValue 'Ext4Win_UnmountAll' -Force }
    if (-not ($obj.PSObject.Properties.Name -contains 'task_update'))  { $obj | Add-Member -NotePropertyName task_update -NotePropertyValue 'Ext4Win_Update' -Force }

    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $CfgPath -Encoding UTF8
}

function Copy-Payload {
    param(
        [Parameter(Mandatory=$true)] [string] $SrcRoot,
        [Parameter(Mandatory=$true)] [string] $DstRoot
    )

    # Copy everything except .git / .github (if present)
    $exclude = @('.git','.github')

    Get-ChildItem -LiteralPath $SrcRoot -Force | ForEach-Object {
        if ($exclude -contains $_.Name) { return }
        $dst = Join-Path $DstRoot $_.Name
        if ($_.PSIsContainer) {
            Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse -Force
        } else {
            # Preserve existing config.json unless -Force
            if ($_.Name -ieq 'config.json' -and (Test-Path $dst) -and (-not $Force)) {
                return
            }
            Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
        }
    }
}

function Install-OrUpdate {
    Ensure-Admin

    $zip = Get-DefaultZipUrl
    Write-HostInfo "Ext4Win => InstallDir: $InstallDir"
    Write-HostInfo "Source ZIP : $zip"
    Write-HostInfo "Distro     : $Distro"
    Write-HostInfo "Language   : $Language"
    Write-HostInfo "Mode       : " + ($(if ($Update) { 'UPDATE' } else { 'INSTALL' }))

    # stop running tasks (update-safe)
    Stop-TaskSafe 'Ext4Win_Tray'
    Stop-TaskSafe 'Ext4Win_Agent'
    Start-Sleep -Seconds 1

    $tmpZip = Join-Path $env:TEMP ("ext4win_{0}.zip" -f ([Guid]::NewGuid().ToString('N')))
    $tmpDir = Join-Path $env:TEMP ("ext4win_{0}" -f ([Guid]::NewGuid().ToString('N')))

    try {
        Invoke-DownloadFile -Url $zip -OutFile $tmpZip

        Ensure-Dir $tmpDir
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force

        $root = Get-ChildItem -LiteralPath $tmpDir -Directory | Select-Object -First 1
        if ($null -eq $root) { throw "ZIP estratto ma cartella root non trovata." }

        Ensure-Dir $InstallDir
        Copy-Payload -SrcRoot $root.FullName -DstRoot $InstallDir

        # Ensure logs/run dirs exist
        Ensure-Dir (Join-Path $InstallDir 'logs')
        Ensure-Dir (Join-Path $InstallDir 'run')

        # Write/merge config
        $cfgPath = Join-Path $InstallDir 'config.json'
        Merge-Config -CfgPath $cfgPath

        # Copy this installer into install dir (so tray can call -Update)
        Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $InstallDir 'Ext4WinInstaller.ps1') -Force

        # Create scheduled tasks (XML import)
        $userSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $ps = (Get-Command powershell.exe -ErrorAction Stop).Source

        $trayArgs   = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$InstallDir\Ext4WinTray.ps1`""
        $agentArgs  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\Ext4WinAgent.ps1`""
        $mountArgs  = "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\Ext4WinCtl.ps1`" -Action MountAll"
        $umountArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\Ext4WinCtl.ps1`" -Action UnmountAll"
        $updArgs    = "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\Ext4WinInstaller.ps1`" -Update -InstallDir `"$InstallDir`" -Repo `"$Repo`" -Branch `"$Branch`" -Distro `"$Distro`" -Language `"$Language`""

        Ensure-TaskXml -Name 'Ext4Win_Tray'     -Xml (New-TaskXml -UserSid $userSid -Command $ps -Arguments $trayArgs   -WorkingDirectory $InstallDir -OnLogon $true  -Hidden $true)
        Ensure-TaskXml -Name 'Ext4Win_Agent'    -Xml (New-TaskXml -UserSid $userSid -Command $ps -Arguments $agentArgs  -WorkingDirectory $InstallDir -OnLogon $true  -Hidden $true)
        Ensure-TaskXml -Name 'Ext4Win_MountAll' -Xml (New-TaskXml -UserSid $userSid -Command $ps -Arguments $mountArgs  -WorkingDirectory $InstallDir -OnLogon $false -Hidden $true)
        Ensure-TaskXml -Name 'Ext4Win_UnmountAll' -Xml (New-TaskXml -UserSid $userSid -Command $ps -Arguments $umountArgs -WorkingDirectory $InstallDir -OnLogon $false -Hidden $true)
        Ensure-TaskXml -Name 'Ext4Win_Update'   -Xml (New-TaskXml -UserSid $userSid -Command $ps -Arguments $updArgs    -WorkingDirectory $InstallDir -OnLogon $false -Hidden $true)

        if (-not $NoTray)  { Run-TaskSafe 'Ext4Win_Tray' }
        if (-not $NoAgent) { Run-TaskSafe 'Ext4Win_Agent' }

        Write-HostInfo "OK: Ext4Win install/update completato."
        Write-HostInfo "Test (Admin):"
        Write-Host "  $InstallDir\Ext4WinCtl.ps1 -Action Prereqs"
        Write-Host "  $InstallDir\Ext4WinCtl.ps1 -Action ListExt4"
        Write-Host "  $InstallDir\Ext4WinCtl.ps1 -Action MountAll"
        Write-Host "  $InstallDir\Ext4WinCtl.ps1 -Action ListMounts"
        Write-Host ""
        Write-HostInfo "Tray task: Ext4Win_Tray  | Update task: Ext4Win_Update"
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $tmpZip | Out-Null
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmpDir | Out-Null
    }
}

function Do-Uninstall {
    Ensure-Admin

    Write-HostWarn "UNINSTALL: rimozione Ext4Win da $InstallDir"

    # stop tasks
    Stop-TaskSafe 'Ext4Win_Tray'
    Stop-TaskSafe 'Ext4Win_Agent'
    Stop-TaskSafe 'Ext4Win_MountAll'
    Stop-TaskSafe 'Ext4Win_UnmountAll'
    Stop-TaskSafe 'Ext4Win_Update'
    Start-Sleep -Seconds 1

    # delete tasks
    Delete-TaskSafe 'Ext4Win_Tray'
    Delete-TaskSafe 'Ext4Win_Agent'
    Delete-TaskSafe 'Ext4Win_MountAll'
    Delete-TaskSafe 'Ext4Win_UnmountAll'
    Delete-TaskSafe 'Ext4Win_Update'

    # best-effort: unmount and shutdown
    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    try { & $wsl --shutdown | Out-Null } catch { }

    # remove install dir (keep logs? you can manually backup)
    try {
        if (Test-Path $InstallDir) {
            Remove-Item -Recurse -Force -LiteralPath $InstallDir
        }
    } catch {
        Write-HostWarn ("Impossibile eliminare completamente la cartella. Rimuovi manualmente: {0}" -f $InstallDir)
    }

    Write-HostInfo "OK: uninstall completato."
}

# ---------------------------
# Main
# ---------------------------
try {
    if ($Uninstall) { Do-Uninstall; return }
    Install-OrUpdate
} catch {
    Write-HostErr $_.Exception.Message
    exit 1
}

<#
Ext4WinInstaller.ps1
Version: 4.4
Single-file installer / updater / uninstaller for Ext4Win.
- Downloads from GitHub as ZIP (no git required).
- Uses wget (PowerShell alias) if available; fallback to wget.exe, then Invoke-WebRequest; last resort curl.exe.
- Supports repos that ship installable files in repo root (docs/, icons/) OR in dist/.
- Can repair tasks without downloading (RepairTasks).

Examples:
  Install:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1

  Update from GitHub:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1 -Update

  Repair tasks only:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1 -RepairTasks

  Uninstall:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1 -Uninstall
#>

[CmdletBinding()]
param(
  [string]$InstallDir = 'C:\ext4win',
  [string]$Distro = 'Debian',
  [ValidateSet('auto','it','en')][string]$Language = 'auto',
  [string]$Repo = 'okno/ext4win',
  [string]$Ref = 'main',
  [switch]$Update,
  [switch]$Uninstall,
  [switch]$RepairTasks,
  [switch]$Force
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

function Write-Log([string]$m) { Write-Host $m }

function Ensure-Dir([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

function Download-File([string]$url, [string]$out) {
  Write-Log ("Download: {0}" -f $url)

  $wgetCmd = Get-Command wget -ErrorAction SilentlyContinue
  if ($wgetCmd -and $wgetCmd.CommandType -eq 'Alias') {
    wget -Uri $url -OutFile $out -UseBasicParsing | Out-Null
  } else {
    $wgetExe = Get-Command wget.exe -ErrorAction SilentlyContinue
    if ($wgetExe) {
      & $wgetExe.Source -O $out $url | Out-Null
    } else {
      Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    }
  }

  if (-not (Test-Path -LiteralPath $out)) { throw "Download failed: $out not created" }
  $len = (Get-Item -LiteralPath $out).Length
  if ($len -lt 50000) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
      & $curl.Source -L $url -o $out | Out-Null
      $len = (Get-Item -LiteralPath $out).Length
    }
    if ($len -lt 50000) { throw "Download too small ($len bytes). Possibly blocked." }
  }
}

function Expand-Zip([string]$zip, [string]$to) {
  if (Test-Path -LiteralPath $to) { Remove-Item -Recurse -Force -LiteralPath $to }
  Expand-Archive -LiteralPath $zip -DestinationPath $to -Force
}

function Get-ExtractRoot([string]$dir) {
  $sub = Get-ChildItem -LiteralPath $dir -Directory | Select-Object -First 1
  if (-not $sub) { throw "Unexpected ZIP layout: no root dir in $dir" }
  return $sub.FullName
}

function Copy-Payload([string]$root, [string]$dest) {
  $dist = Join-Path $root 'dist'
  $src = $null
  $mode = ''
  if (Test-Path -LiteralPath $dist) {
    $src = $dist
    $mode = 'dist'
  } else {
    $src = $root
    $mode = 'root'
  }
  Write-Log ("Payload mode: {0}" -f $mode)

  Ensure-Dir $dest

  $cfg = Join-Path $dest 'config.json'
  $ico = Join-Path $dest 'file.ico'
  $tmpCfg = $null
  $tmpIco = $null
  if ((Test-Path -LiteralPath $cfg) -and (-not $Force)) {
    $tmpCfg = Join-Path $env:TEMP ("ext4win_cfg_{0}.json" -f ([guid]::NewGuid().ToString('n')))
    Copy-Item -LiteralPath $cfg -Destination $tmpCfg -Force
  }
  if ((Test-Path -LiteralPath $ico) -and (-not $Force)) {
    $tmpIco = Join-Path $env:TEMP ("ext4win_ico_{0}.ico" -f ([guid]::NewGuid().ToString('n')))
    Copy-Item -LiteralPath $ico -Destination $tmpIco -Force
  }

  if ($mode -eq 'dist') {
    Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
  } else {
    $allowFiles = @(
      'Ext4WinTray.ps1','Ext4WinInstaller.ps1','Ext4WinInstallerStandaloneDeprecated.ps1',
      'Ext4WinCtl.ps1','Ext4WinCore.ps1','Ext4WinAgent.ps1','Ext4WinLib.psm1','Ext4WinSvc.exe',
      'file.ico','README.md','README.txt','LICENSE.txt','banner.png','logo.png'
    )
    foreach ($f in $allowFiles) {
      $p = Join-Path $src $f
      if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $dest $f) -Force }
    }
    foreach ($d in @('docs','icons')) {
      $dp = Join-Path $src $d
      if (Test-Path -LiteralPath $dp) { Copy-Item -LiteralPath $dp -Destination (Join-Path $dest $d) -Recurse -Force }
    }
  }

  if ($tmpCfg) { Copy-Item -LiteralPath $tmpCfg -Destination $cfg -Force; Remove-Item $tmpCfg -Force -ErrorAction SilentlyContinue }
  if ($tmpIco) { Copy-Item -LiteralPath $tmpIco -Destination $ico -Force; Remove-Item $tmpIco -Force -ErrorAction SilentlyContinue }
}

function Write-Config([string]$dest) {
  $cfgPath = Join-Path $dest 'config.json'
  if ((Test-Path -LiteralPath $cfgPath) -and (-not $Force)) { return }
  $cfg = @{
    distro = $Distro
    language = $Language
    task_tray = 'Ext4Win_Tray'
    task_agent = 'Ext4Win_Agent'
    task_mount = 'Ext4Win_MountAll'
    task_unmount = 'Ext4Win_UnmountAll'
    task_update = 'Ext4Win_Update'
  }
  ($cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
}

function Write-RunCmd([string]$dest, [string]$name, [string]$ps1, [string]$outlog) {
  $cmdPath = Join-Path $dest $name
  $logDir = Join-Path $dest 'logs'
  Ensure-Dir $logDir
  $content = @"
@echo off
setlocal
if not exist "$logDir" mkdir "$logDir" >nul 2>nul
echo ---- %date% %time% ---->> "$outlog"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "$ps1" 1>> "$outlog" 2>>&1
endlocal
"@
  Set-Content -LiteralPath $cmdPath -Value $content -Encoding ASCII
}

function New-TaskXml([string]$taskName, [string]$command, [string]$arguments, [string]$workDir, [bool]$onLogon=$true, [bool]$highest=$true) {
  $user = "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME
  $rl = if ($highest) { 'HighestAvailable' } else { 'LeastPrivilege' }
  $trigger = if ($onLogon) {
@"
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
"@
  } else {
@"
    <RegistrationTrigger>
      <Enabled>true</Enabled>
      <Delay>PT0S</Delay>
    </RegistrationTrigger>
"@
  }
  return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>Ext4Win</Author>
    <Description>$taskName</Description>
  </RegistrationInfo>
  <Triggers>
$trigger
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>$rl</RunLevel>
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
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$command</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$workDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Install-TaskXml([string]$name, [string]$xml) {
  $tmp = Join-Path $env:TEMP ("{0}.xml" -f ([guid]::NewGuid().ToString('n')))
  Set-Content -LiteralPath $tmp -Value $xml -Encoding Unicode
  & schtasks.exe /Create /TN $name /XML $tmp /F | Out-Null
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

function Create-Tasks([string]$dest) {
  $runTray = Join-Path $dest 'RunTray.cmd'
  $runAgent = Join-Path $dest 'RunAgent.cmd'
  $trayPs1 = Join-Path $dest 'Ext4WinTray.ps1'
  $agentPs1 = Join-Path $dest 'Ext4WinAgent.ps1'
  $ctl = Join-Path $dest 'Ext4WinCtl.ps1'
  $installer = Join-Path $dest 'Ext4WinInstaller.ps1'

  Write-RunCmd $dest 'RunTray.cmd' $trayPs1 (Join-Path $dest 'logs\Ext4WinTray.out.log')
  if (Test-Path -LiteralPath $agentPs1) {
    Write-RunCmd $dest 'RunAgent.cmd' $agentPs1 (Join-Path $dest 'logs\Ext4WinAgent.out.log')
  }

  $xmlTray = New-TaskXml 'Ext4Win Tray' 'cmd.exe' ("/c `"$runTray`"") $dest $true $true
  Install-TaskXml 'Ext4Win_Tray' $xmlTray

  if (Test-Path -LiteralPath $agentPs1) {
    $xmlAgent = New-TaskXml 'Ext4Win Agent' 'cmd.exe' ("/c `"$runAgent`"") $dest $true $true
    Install-TaskXml 'Ext4Win_Agent' $xmlAgent
  }

  if (Test-Path -LiteralPath $ctl) {
    $xmlMount = New-TaskXml 'Ext4Win MountAll' 'powershell.exe' ("-NoProfile -ExecutionPolicy Bypass -File `"$ctl`" -Action MountAll") $dest $false $true
    Install-TaskXml 'Ext4Win_MountAll' $xmlMount

    $xmlUm = New-TaskXml 'Ext4Win UnmountAll' 'powershell.exe' ("-NoProfile -ExecutionPolicy Bypass -File `"$ctl`" -Action UnmountAll") $dest $false $true
    Install-TaskXml 'Ext4Win_UnmountAll' $xmlUm
  }

  $xmlUp = New-TaskXml 'Ext4Win Update' 'powershell.exe' ("-NoProfile -ExecutionPolicy Bypass -File `"$installer`" -Update") $dest $false $true
  Install-TaskXml 'Ext4Win_Update' $xmlUp
}

function Create-DesktopShortcut([string]$name, [string]$target, [string]$args) {
  try {
    $wsh = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop ($name + '.lnk')
    $s = $wsh.CreateShortcut($lnk)
    $s.TargetPath = $target
    $s.Arguments = $args
    $s.WorkingDirectory = $InstallDir
    $ico = Join-Path $InstallDir 'file.ico'
    if (Test-Path -LiteralPath $ico) { $s.IconLocation = $ico }
    $s.Save()
  } catch {}
}

function Remove-Tasks {
  foreach ($t in @('Ext4Win_Tray','Ext4Win_Agent','Ext4Win_MountAll','Ext4Win_UnmountAll','Ext4Win_Update')) {
    & schtasks.exe /Delete /TN $t /F 2>$null | Out-Null
  }
}

function Remove-Shortcuts {
  try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($n in @('MONTA','SMONTA')) {
      $p = Join-Path $desktop ($n + '.lnk')
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
  } catch {}
}

function Do-DownloadInstallOrUpdate {
  Ensure-Dir $InstallDir
  Ensure-Dir (Join-Path $InstallDir 'logs')

  $url = "https://codeload.github.com/{0}/zip/refs/heads/{1}" -f $Repo, $Ref
  $zip = Join-Path $env:TEMP ("ext4win_{0}_{1}.zip" -f ($Ref), (Get-Date -Format 'yyyyMMdd_HHmmss'))
  $tmp = Join-Path $env:TEMP ("ext4win_extract_{0}" -f ([guid]::NewGuid().ToString('n')))

  Download-File $url $zip
  Expand-Zip $zip $tmp
  $root = Get-ExtractRoot $tmp

  Copy-Payload $root $InstallDir
  Write-Config $InstallDir

  Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $InstallDir 'Ext4WinInstaller.ps1') -Force

  Create-Tasks $InstallDir

  Create-DesktopShortcut 'MONTA' "$env:WINDIR\System32\schtasks.exe" "/Run /TN Ext4Win_MountAll"
  Create-DesktopShortcut 'SMONTA' "$env:WINDIR\System32\schtasks.exe" "/Run /TN Ext4Win_UnmountAll"

  & schtasks.exe /Run /TN Ext4Win_Tray | Out-Null

  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

  Write-Log "OK: install/update completed in $InstallDir"
  Write-Log "Tray logs:"
  Write-Log " - $InstallDir\logs\Ext4WinTray.runtime.log"
  Write-Log " - $InstallDir\logs\Ext4WinTray.out.log"
}

function Do-RepairTasksOnly {
  Ensure-Dir $InstallDir
  Ensure-Dir (Join-Path $InstallDir 'logs')
  Create-Tasks $InstallDir
  & schtasks.exe /Run /TN Ext4Win_Tray | Out-Null
  Write-Log "OK: tasks repaired."
}

function Do-Uninstall {
  Remove-Tasks
  Remove-Shortcuts
  try { if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force } } catch {}
  Write-Log "OK: uninstalled."
}

if ($Uninstall) { Do-Uninstall; exit 0 }
if ($RepairTasks) { Do-RepairTasksOnly; exit 0 }
if ($Update) { Do-DownloadInstallOrUpdate; exit 0 }

Do-DownloadInstallOrUpdate

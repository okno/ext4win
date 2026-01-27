<# 
Ext4WinTray.ps1 - v4.0
Systray UI with bilingual IT/EN, service/agent monitoring, and colored status icon.
States:
 - Mounted  => GREEN
 - Error    => RED
 - Normal   => WHITE

Logs:
 - logs\Ext4WinTray.runtime.log (internal)
 - stdout/stderr can be redirected by scheduled task to logs\Ext4WinTray.out.log
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$installDir = $PSScriptRoot
$logDir = Join-Path $installDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$runtimeLog = Join-Path $logDir 'Ext4WinTray.runtime.log'

function TLog([string]$msg) {
  try { Add-Content -LiteralPath $runtimeLog -Value ("{0} {1}" -f (Get-Date -Format s), $msg) } catch { }
}

TLog "[info] Tray starting (PID=$PID)."

try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  Add-Type -AssemblyName System.Drawing.Drawing2D
} catch {
  TLog ("[error] Add-Type failed: {0}" -f $_.Exception.Message)
  exit 1
}

# user32 DestroyIcon to avoid icon handle leaks
Add-Type -Namespace Ext4WinNative -Name User32 -MemberDefinition @"
using System;
using System.Runtime.InteropServices;
public static class User32 {
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool DestroyIcon(IntPtr hIcon);
}
"@

. "$installDir\Ext4WinCore.ps1"

# ---------------- i18n ----------------
$I18N = @{
  it = @{
    Title = 'Ext4Win'
    Status = 'Stato'
    Mounted = 'Montato'
    Normal = 'Normale'
    Error = 'Errore'
    NoExt4 = 'Nessuna partizione ext4 rilevata'
    Ext4Found = 'Partizioni ext4 rilevate'
    MountedCount = 'Montate'
    Disks = 'Dischi'
    MountAll = 'Monta tutte'
    UnmountAll = 'Smonta tutte'
    OpenWSL = 'Apri cartella WSL'
    OpenDocs = 'Documentazione'
    OpenLogs = 'Apri logs'
    About = 'Info'
    Exit = 'Esci'
    Agent = 'Servizio (Agent)'
    AgentRunning = 'In esecuzione'
    AgentStopped = 'Fermo'
    Start = 'Avvia'
    Stop = 'Ferma'
    Restart = 'Riavvia'
    Refresh = 'Aggiorna'
    Language = 'Lingua'
    Auto = 'Auto'
    Italian = 'Italiano'
    English = 'Inglese'
    Open = 'Apri'
    Mount = 'Monta'
    Unmount = 'Smonta'
    ErrorPrereq = 'Prerequisiti non OK'
  }
  en = @{
    Title = 'Ext4Win'
    Status = 'Status'
    Mounted = 'Mounted'
    Normal = 'Normal'
    Error = 'Error'
    NoExt4 = 'No ext4 partitions detected'
    Ext4Found = 'ext4 partitions detected'
    MountedCount = 'Mounted'
    Disks = 'Disks'
    MountAll = 'Mount all'
    UnmountAll = 'Unmount all'
    OpenWSL = 'Open WSL folder'
    OpenDocs = 'Documentation'
    OpenLogs = 'Open logs'
    About = 'About'
    Exit = 'Exit'
    Agent = 'Service (Agent)'
    AgentRunning = 'Running'
    AgentStopped = 'Stopped'
    Start = 'Start'
    Stop = 'Stop'
    Restart = 'Restart'
    Refresh = 'Refresh'
    Language = 'Language'
    Auto = 'Auto'
    Italian = 'Italian'
    English = 'English'
    Open = 'Open'
    Mount = 'Mount'
    Unmount = 'Unmount'
    ErrorPrereq = 'Prerequisites not OK'
  }
}

function Get-Lang {
  $cfg = Get-Ext4WinConfig
  $lang = 'auto'
  try { if ($cfg.language) { $lang = [string]$cfg.language } } catch { $lang = 'auto' }
  $lang = $lang.ToLowerInvariant()

  if ($lang -eq 'it' -or $lang -eq 'en') { return $lang }

  # auto: follow Windows UI
  try {
    $ui = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
    if ($ui -eq 'it') { return 'it' }
  } catch { }
  return 'en'
}

$global:Lang = Get-Lang

function L([string]$Key) {
  try {
    if ($I18N.ContainsKey($global:Lang) -and $I18N[$global:Lang].ContainsKey($Key)) { return $I18N[$global:Lang][$Key] }
  } catch { }
  return $Key
}

# ---------------- icon state ----------------
$iconPath = Join-Path $installDir 'file.ico'
$global:CurrentIconHandle = [IntPtr]::Zero

function New-Ext4WinStatusIcon {
  param(
    [ValidateSet('normal','mounted','error')]
    [string]$State
  )

  $baseIcon = $null
  try {
    if (Test-Path -LiteralPath $iconPath) { $baseIcon = New-Object System.Drawing.Icon($iconPath) }
  } catch { $baseIcon = $null }

  if (-not $baseIcon) { $baseIcon = [System.Drawing.SystemIcons]::Application }

  $bmp = $baseIcon.ToBitmap()
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

  $w = $bmp.Width
  $h = $bmp.Height

    # Tint overlay (whole icon) to match state color
  switch ($State) {
    'mounted' { $overlayColor = [System.Drawing.Color]::FromArgb(90, 0, 255, 0) }  # green
    'error'   { $overlayColor = [System.Drawing.Color]::FromArgb(90, 255, 0, 0) }  # red
    default   { $overlayColor = [System.Drawing.Color]::FromArgb(0, 255, 255, 255) } # transparent
  }

  if ($overlayColor.A -gt 0) {
    $overlayBrush = New-Object System.Drawing.SolidBrush($overlayColor)
    $g.FillRectangle($overlayBrush, 0, 0, $w, $h)
    $overlayBrush.Dispose()
  }

  $g.Dispose()

  $hIcon = $bmp.GetHicon()
  $icon = [System.Drawing.Icon]::FromHandle($hIcon)

  return [pscustomobject]@{ Icon = $icon; Handle = $hIcon; Bitmap = $bmp }
}

function Set-NotifyIconState {
  param(
    [Parameter(Mandatory=$true)][System.Windows.Forms.NotifyIcon]$Notify,
    [Parameter(Mandatory=$true)][string]$State
  )

  $obj = New-Ext4WinStatusIcon -State $State
  if (-not $obj) { return }

  if ($global:CurrentIconHandle -ne [IntPtr]::Zero) {
    [Ext4WinNative.User32]::DestroyIcon($global:CurrentIconHandle) | Out-Null
    $global:CurrentIconHandle = [IntPtr]::Zero
  }

  $Notify.Icon = $obj.Icon
  $global:CurrentIconHandle = $obj.Handle
}

# ---------------- Agent (Scheduled Task) helpers ----------------
$global:AgentTaskName = 'Ext4Win_Agent'
$global:TrayTaskName  = 'Ext4Win_Tray'

function Get-AgentStatus {
  $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
  if (-not (Test-Path -LiteralPath $schtasks)) { $schtasks = 'schtasks.exe' }

  $res = Invoke-Ext4WinExternal -FilePath $schtasks -Arguments @('/Query','/TN',$global:AgentTaskName,'/FO','LIST','/V')
  if ($res.ExitCode -ne 0) {
    return [pscustomobject]@{ exists=$false; running=$false; status='missing'; lastResult=$null }
  }

  $status = $null
  $lastResult = $null

  foreach ($line in ($res.Output -split "`r?`n")) {
    if (-not $line) { continue }
    if ($line -match '^\s*(Stato|Status)\s*:\s*(.+)\s*$') { $status = $Matches[2].Trim(); continue }
    if ($line -match '^\s*(Ultimo\s+esito|Last\s+Result)\s*:\s*(.+)\s*$') { $lastResult = $Matches[2].Trim(); continue }
  }

  $running = $false
  if ($status) {
    if ($status -match 'In\s+esecuzione' -or $status -match 'Running') { $running = $true }
  }

  return [pscustomobject]@{ exists=$true; running=$running; status=$status; lastResult=$lastResult }
}

function Start-Agent {
  $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
  if (-not (Test-Path -LiteralPath $schtasks)) { $schtasks = 'schtasks.exe' }
  [void](Invoke-Ext4WinExternal -FilePath $schtasks -Arguments @('/Run','/TN',$global:AgentTaskName))
}

function Stop-Agent {
  $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
  if (-not (Test-Path -LiteralPath $schtasks)) { $schtasks = 'schtasks.exe' }
  [void](Invoke-Ext4WinExternal -FilePath $schtasks -Arguments @('/End','/TN',$global:AgentTaskName))
}

function Restart-Agent {
  Stop-Agent
  Start-Sleep -Milliseconds 700
  Start-Agent
}

# ---------------- UI state refresh ----------------
function Get-StateSummary {
  $pr = Get-Ext4WinPrereqs
  if (-not $pr.ok) {
    return [pscustomobject]@{
      ok = $false
      state = 'error'
      tooltip = ("Ext4Win - {0}: {1}" -f (L 'ErrorPrereq'), $pr.reason)
      parts = @()
      mounts = @()
      agent = (Get-AgentStatus)
      error = $pr.reason
    }
  }

  $parts = @(Get-Ext4WinExt4Partitions)
  $mounts = @(Get-Ext4WinMounts)
  $agent = Get-AgentStatus

  # Agent last error (heartbeat file) - optional
  $agentErr = $null
  try {
    $stateFile = Join-Path $global:Ext4WinRunDir 'agent.status.json'
    if (Test-Path -LiteralPath $stateFile) {
      $s = (Get-Content -LiteralPath $stateFile -Raw) | ConvertFrom-Json
      if ($s -and $s.lastError -and $s.lastError -ne 'stopped') { $agentErr = [string]$s.lastError }
    }
  } catch { }

  if ($agentErr) {
    return [pscustomobject]@{
      ok = $true
      state = 'error'
      tooltip = ("Ext4Win - {0}: {1}" -f (L 'Error'), $agentErr)
      parts = $parts
      mounts = $mounts
      agent = $agent
      error = $agentErr
    }
  }

  if ($mounts.Count -gt 0) {
    return [pscustomobject]@{
      ok = $true
      state = 'mounted'
      tooltip = ("Ext4Win - {0}: {1}" -f (L 'Mounted'), $mounts.Count)
      parts = $parts
      mounts = $mounts
      agent = $agent
      error = $null
    }
  }

  return [pscustomobject]@{
    ok = $true
    state = 'normal'
    tooltip = ("Ext4Win - {0} ({1}: {2})" -f (L 'Normal'), (L 'Disks'), $parts.Count)
    parts = $parts
    mounts = $mounts
    agent = $agent
    error = $null
  }
}

# ---------------- Context menu builder ----------------
function Build-ContextMenu {
  param(
    [Parameter(Mandatory=$true)][System.Windows.Forms.ContextMenuStrip]$Menu,
    [Parameter(Mandatory=$true)][System.Windows.Forms.NotifyIcon]$Notify
  )

  $Menu.Items.Clear() | Out-Null

  $sum = $null
  try { $sum = Get-StateSummary } catch { $sum = $null }

  if ($sum) {
    try {
      $Notify.Text = ($sum.tooltip.Substring(0, [Math]::Min(60, $sum.tooltip.Length)))
    } catch {
      $Notify.Text = 'Ext4Win'
    }
    Set-NotifyIconState -Notify $Notify -State $sum.state
  } else {
    $Notify.Text = 'Ext4Win'
    Set-NotifyIconState -Notify $Notify -State 'error'
  }

  $hdr = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Title'))
  $hdr.Enabled = $false
  [void]$Menu.Items.Add($hdr)

  if ($sum) {
    $agentText = (L 'Agent') + ': '
    if (-not $sum.agent.exists) { $agentText += 'missing' }
    elseif ($sum.agent.running) { $agentText += (L 'AgentRunning') }
    else { $agentText += (L 'AgentStopped') }

    $iStatus = New-Object System.Windows.Forms.ToolStripMenuItem(("{0}: {1} | {2}: {3} | {4}" -f (L 'Disks'), $sum.parts.Count, (L 'MountedCount'), $sum.mounts.Count, $agentText))
    $iStatus.Enabled = $false
    [void]$Menu.Items.Add($iStatus)

    if ($sum.state -eq 'error' -and $sum.error) {
      $iErr = New-Object System.Windows.Forms.ToolStripMenuItem(($sum.error))
      $iErr.Enabled = $false
      [void]$Menu.Items.Add($iErr)
    }
  }

  [void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  # Mount/Unmount all
  $miMountAll = New-Object System.Windows.Forms.ToolStripMenuItem((L 'MountAll'))
  $miMountAll.add_Click({
    try { MountAll-Ext4Win } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ext4Win') | Out-Null }
  })
  [void]$Menu.Items.Add($miMountAll)

  $miUnmountAll = New-Object System.Windows.Forms.ToolStripMenuItem((L 'UnmountAll'))
  $miUnmountAll.add_Click({
    try { UnmountAll-Ext4Win } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ext4Win') | Out-Null }
  })
  [void]$Menu.Items.Add($miUnmountAll)

  # Per-disk dropdown
  $parts = @()
  try { $parts = @(Get-Ext4WinExt4Partitions) } catch { $parts = @() }

  if ($parts.Count -gt 0) {
    $miDisks = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Disks'))
    foreach ($p in $parts) {
      $dn = [int]$p.DiskNumber
      $pn = [int]$p.PartitionNumber
      $label = ("Disk {0} p{1} - {2}" -f $dn, $pn, $p.DiskFriendlyName)

      $miPart = New-Object System.Windows.Forms.ToolStripMenuItem($label)

      $miOpen = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Open'))
      $miOpen.add_Click(({
      try { Open-Ext4WinExplorer -DiskNumber $dn -PartitionNumber $pn } catch { }
    }).GetNewClosure())

      $miM = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Mount'))
      $miM.add_Click(({
      try { Mount-Ext4WinPartition -DiskNumber $dn -PartitionNumber $pn } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ext4Win') | Out-Null }
    }).GetNewClosure())

      $miU = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Unmount'))
      $miU.add_Click(({
      try { UnmountDisk-Ext4Win -DiskNumber $dn } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ext4Win') | Out-Null }
    }).GetNewClosure())

      [void]$miPart.DropDownItems.Add($miOpen)
      [void]$miPart.DropDownItems.Add($miM)
      [void]$miPart.DropDownItems.Add($miU)

      [void]$miDisks.DropDownItems.Add($miPart)
    }
    [void]$Menu.Items.Add($miDisks)
  }

  [void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  # Open WSL folder
  $miOpenWSL = New-Object System.Windows.Forms.ToolStripMenuItem((L 'OpenWSL'))
  $miOpenWSL.add_Click({
    try {
      $pr = Get-Ext4WinPrereqs
      if ($pr.ok) {
        $path = ("\\wsl.localhost\{0}\mnt\wsl" -f $pr.distro)
        Start-Process explorer.exe $path | Out-Null
      }
    } catch { }
  })
  [void]$Menu.Items.Add($miOpenWSL)

  # Agent menu
  $miAgent = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Agent'))

  $st = Get-AgentStatus
  $sline = (L 'Status') + ': '
  if (-not $st.exists) { $sline += 'missing' }
  elseif ($st.running) { $sline += (L 'AgentRunning') }
  else { $sline += (L 'AgentStopped') }

  $miAgentStatus = New-Object System.Windows.Forms.ToolStripMenuItem($sline)
  $miAgentStatus.Enabled = $false
  [void]$miAgent.DropDownItems.Add($miAgentStatus)

  $miAgentStart = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Start'))
  $miAgentStart.add_Click({ try { Start-Agent } catch { } })
  [void]$miAgent.DropDownItems.Add($miAgentStart)

  $miAgentStop = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Stop'))
  $miAgentStop.add_Click({ try { Stop-Agent } catch { } })
  [void]$miAgent.DropDownItems.Add($miAgentStop)

  $miAgentRestart = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Restart'))
  $miAgentRestart.add_Click({ try { Restart-Agent } catch { } })
  [void]$miAgent.DropDownItems.Add($miAgentRestart)

  [void]$Menu.Items.Add($miAgent)

  [void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  # Docs / Logs
  $miDocs = New-Object System.Windows.Forms.ToolStripMenuItem((L 'OpenDocs'))
  $miDocs.add_Click({
    try {
      $readmeIt = Join-Path $global:Ext4WinDocsDir 'README.md'
      $readmeEn = Join-Path $global:Ext4WinDocsDir 'README.en.md'
      $file = $readmeEn
      if ($global:Lang -eq 'it' -and (Test-Path -LiteralPath $readmeIt)) { $file = $readmeIt }
      if (Test-Path -LiteralPath $file) { Start-Process notepad.exe $file | Out-Null }
    } catch { }
  })
  [void]$Menu.Items.Add($miDocs)

  $miLogs = New-Object System.Windows.Forms.ToolStripMenuItem((L 'OpenLogs'))
  $miLogs.add_Click({ try { Start-Process explorer.exe $global:Ext4WinLogsDir | Out-Null } catch { } })
  [void]$Menu.Items.Add($miLogs)

  # Language switch
  $miLang = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Language'))

  $cfg = Get-Ext4WinConfig
  $cur = 'auto'
  try { if ($cfg.language) { $cur = [string]$cfg.language } } catch { $cur = 'auto' }
  $cur = $cur.ToLowerInvariant()

  function Add-LangItem([string]$code, [string]$labelKey) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem((L $labelKey))
    $item.Checked = ($cur -eq $code)
    $item.add_Click(({
      try {
        Set-Ext4WinConfigValue -Key 'language' -Value $code | Out-Null
        $global:Lang = Get-Lang
      } catch { }
    }).GetNewClosure())
    [void]$miLang.DropDownItems.Add($item)
  }

  Add-LangItem -code 'auto' -labelKey 'Auto'
  Add-LangItem -code 'it' -labelKey 'Italian'
  Add-LangItem -code 'en' -labelKey 'English'

  [void]$Menu.Items.Add($miLang)

  # About
  $miAbout = New-Object System.Windows.Forms.ToolStripMenuItem((L 'About'))
  $miAbout.add_Click({
    try {
      $msg = "Ext4Win v4.0`n`nWSL ext4 mount helper for Windows 10/11."
      [System.Windows.Forms.MessageBox]::Show($msg, 'Ext4Win') | Out-Null
    } catch { }
  })
  [void]$Menu.Items.Add($miAbout)

  [void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  $miExit = New-Object System.Windows.Forms.ToolStripMenuItem((L 'Exit'))
  $miExit.add_Click({
    try {
      $Notify.Visible = $false
      $Notify.Dispose()
    } catch { }
    [System.Windows.Forms.Application]::Exit()
  })
  [void]$Menu.Items.Add($miExit)
}

# ---------------- App init ----------------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text = 'Ext4Win'
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.add_Opening({
  try { Build-ContextMenu -Menu $menu -Notify $notify } catch { }
})
$notify.ContextMenuStrip = $menu

# Initial state
try {
  $s = Get-StateSummary
  Set-NotifyIconState -Notify $notify -State $s.state
} catch {
  Set-NotifyIconState -Notify $notify -State 'error'
}

# Periodic refresh (icon + tooltip)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.add_Tick({
  try {
    $global:Lang = Get-Lang
    $s = Get-StateSummary
    try { $notify.Text = ($s.tooltip.Substring(0, [Math]::Min(60, $s.tooltip.Length))) } catch { }
    Set-NotifyIconState -Notify $notify -State $s.state
  } catch {
    TLog ("[warn] refresh error: {0}" -f $_.Exception.Message)
    Set-NotifyIconState -Notify $notify -State 'error'
  }
})
$timer.Start()

TLog "[info] Tray running."
[System.Windows.Forms.Application]::Run()

#requires -Version 5.1
<#
Ext4Win Tray UI (PowerShell + WinForms)

Fixes:
- DO NOT load a non-existent assembly "System.Drawing.Drawing2D" (it's a namespace, not an assembly).
- Load System.Drawing (or System.Drawing.Common) + System.Windows.Forms correctly.

Features:
- Bilingual UI (IT/EN) with config.json -> language: auto|it|en
- Icon badge: green=mounted, red=error, white=idle (overlay dot)
- Mount/Unmount (via scheduled tasks) + list detected ext4 partitions
- "Shutdown WSL" (wsl --shutdown) + optional unmount-all before shutdown
- Disk space mini-bar (df inside WSL) for mounted ext4 paths
- Agent control (start/stop/restart/status) from tray
- Manual update trigger (via scheduled task Ext4Win_Update, if present)
#>

[CmdletBinding()]
param()

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ---------------------------
# Paths / logging
# ---------------------------
$InstallDir = $PSScriptRoot
$LogDir     = Join-Path $InstallDir 'logs'
$RunDir     = Join-Path $InstallDir 'run'

New-Item -ItemType Directory -Force -Path $LogDir, $RunDir | Out-Null

$RuntimeLog = Join-Path $LogDir 'Ext4WinTray.runtime.log'
$OutLog     = Join-Path $LogDir 'Ext4WinTray.out.log'

function Write-TrayLog {
    param(
        [ValidateSet('info','warn','error')] [string] $Level,
        [string] $Message
    )
    try {
        $ts = (Get-Date).ToString('s')
        Add-Content -Path $RuntimeLog -Encoding UTF8 -Value ("{0} [{1}] {2}" -f $ts, $Level, $Message)
    } catch { }
}

Write-TrayLog -Level info -Message ("Tray starting (PID={0})." -f $PID)

# ---------------------------
# Single instance (mutex)
# ---------------------------
$mutexName = 'Global\Ext4WinTray'
$created = $false
try {
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$created)
    if (-not $created) {
        Write-TrayLog -Level warn -Message 'Another instance is already running. Exiting.'
        return
    }
} catch {
    # If mutex fails, we still try to continue (best effort)
    Write-TrayLog -Level warn -Message ("Mutex error: {0}" -f $_.Exception.Message)
}

# ---------------------------
# Config
# ---------------------------
$CfgPath = Join-Path $InstallDir 'config.json'
$cfg = $null
if (Test-Path $CfgPath) {
    try { $cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        Write-TrayLog -Level error -Message ("Config parse error: {0}" -f $_.Exception.Message)
        $cfg = $null
    }
}

function Get-Cfg {
    param([string]$Name, $Default)
    try {
        if ($null -ne $cfg -and $cfg.PSObject.Properties.Name -contains $Name) { return $cfg.$Name }
    } catch { }
    return $Default
}

$distro     = Get-Cfg -Name 'distro'     -Default 'Debian'
$langCfg    = (Get-Cfg -Name 'language'  -Default 'auto')
$taskTray   = Get-Cfg -Name 'task_tray'  -Default 'Ext4Win_Tray'
$taskAgent  = Get-Cfg -Name 'task_agent' -Default 'Ext4Win_Agent'
$taskMount  = Get-Cfg -Name 'task_mount' -Default 'Ext4Win_MountAll'
$taskUmount = Get-Cfg -Name 'task_unmount' -Default 'Ext4Win_UnmountAll'
$taskUpdate = Get-Cfg -Name 'task_update' -Default 'Ext4Win_Update'

$CtlPath    = Join-Path $InstallDir 'Ext4WinCtl.ps1'

# ---------------------------
# i18n
# ---------------------------
$UI = @{
  it = @{
    title='Ext4Win'
    status='Stato'
    mounted='Montato'
    unmounted='Smontato'
    idle='Pronto'
    error='Errore'
    mountAll='MONTA (tutte)'
    unmountAll='SMONTA (tutte)'
    partitions='Partizioni ext4'
    openWsl='Apri cartella WSL'
    shutdownWsl='Spegni WSL'
    diskSpace='Spazio disco'
    agent='Agent'
    agentStart='Avvia Agent'
    agentStop='Ferma Agent'
    agentRestart='Riavvia Agent'
    update='Aggiorna Ext4Win'
    logs='Apri logs'
    docs='Apri documentazione'
    language='Lingua'
    auto='Auto'
    italian='Italiano'
    english='Inglese'
    exit='Esci'
    notAvailable='(non disponibile)'
  }
  en = @{
    title='Ext4Win'
    status='Status'
    mounted='Mounted'
    unmounted='Unmounted'
    idle='Ready'
    error='Error'
    mountAll='MOUNT (all)'
    unmountAll='UNMOUNT (all)'
    partitions='ext4 partitions'
    openWsl='Open WSL folder'
    shutdownWsl='Shutdown WSL'
    diskSpace='Disk space'
    agent='Agent'
    agentStart='Start Agent'
    agentStop='Stop Agent'
    agentRestart='Restart Agent'
    update='Update Ext4Win'
    logs='Open logs'
    docs='Open documentation'
    language='Language'
    auto='Auto'
    italian='Italian'
    english='English'
    exit='Exit'
    notAvailable='(not available)'
  }
}

function Resolve-Lang {
    $lc = ''
    try { $lc = ($langCfg + '').ToLowerInvariant() } catch { $lc = 'auto' }
    if ($lc -in @('it','ita','italian','italiano')) { return 'it' }
    if ($lc -in @('en','eng','english')) { return 'en' }
    try {
        $sys = [System.Globalization.CultureInfo]::InstalledUICulture.TwoLetterISOLanguageName
        if ($sys -eq 'it') { return 'it' }
    } catch { }
    return 'en'
}
$lang = Resolve-Lang

function T([string]$Key) {
    try { return $UI[$lang][$Key] } catch { return $Key }
}

function Set-LanguageConfig([string]$val) {
    try {
        $obj = $null
        if (Test-Path $CfgPath) {
            $obj = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if ($null -eq $obj) { $obj = [pscustomobject]@{} }
        $obj | Add-Member -NotePropertyName 'language' -NotePropertyValue $val -Force
        $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $CfgPath -Encoding UTF8
    } catch {
        Write-TrayLog -Level error -Message ("Failed to write config language: {0}" -f $_.Exception.Message)
    }

    # Restart tray to reload language
    try {
        $ps = (Get-Command powershell.exe -ErrorAction Stop).Source
        Start-Process -FilePath $ps -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',"$PSCommandPath") -WorkingDirectory $InstallDir -WindowStyle Hidden | Out-Null
    } catch { }
    try {
        $notify.Visible = $false
    } catch { }
    [System.Windows.Forms.Application]::Exit()
}

# ---------------------------
# Assemblies (WinForms + Drawing)
# ---------------------------
$haveDrawing = $false
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
} catch {
    Write-TrayLog -Level error -Message ("Add-Type failed (System.Windows.Forms): {0}" -f $_.Exception.Message)
    return
}

try {
    # Correct assembly is System.Drawing (Drawing2D is a namespace!)
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $haveDrawing = $true
} catch {
    try {
        Add-Type -AssemblyName System.Drawing.Common -ErrorAction Stop
        $haveDrawing = $true
    } catch {
        Write-TrayLog -Level error -Message ("Add-Type failed (System.Drawing): {0}" -f $_.Exception.Message)
        $haveDrawing = $false
    }
}

# Native DestroyIcon to avoid handle leaks (only if Drawing is available)
if ($haveDrawing) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Ext4WinNative {
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern bool DestroyIcon(IntPtr handle);
}
"@ -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

# ---------------------------
# Helper: JSON extraction (robust against extra lines)
# ---------------------------
function Try-ParseJsonFromText([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $t = $text.Trim()

    # find first { or [
    $i1 = $t.IndexOf('{')
    $i2 = $t.IndexOf('[')
    $i = -1
    if ($i1 -ge 0 -and $i2 -ge 0) { $i = [Math]::Min($i1,$i2) }
    elseif ($i1 -ge 0) { $i = $i1 }
    elseif ($i2 -ge 0) { $i = $i2 }

    if ($i -lt 0) { return $null }
    $json = $t.Substring($i)
    try { return $json | ConvertFrom-Json } catch { return $null }
}

function Invoke-Ctl([string]$action) {
    if (-not (Test-Path $CtlPath)) { return $null }
    try {
        $out = & $CtlPath -Action $action 2>$null | Out-String
        return (Try-ParseJsonFromText $out)
    } catch {
        Write-TrayLog -Level error -Message ("Invoke-Ctl {0} failed: {1}" -f $action, $_.Exception.Message)
        return $null
    }
}

# ---------------------------
# Scheduled tasks helpers
# ---------------------------
$schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
$wsl      = Join-Path $env:SystemRoot 'System32\wsl.exe'

function Run-Task([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    try { & $schtasks /Run /TN $name | Out-Null } catch {
        Write-TrayLog -Level error -Message ("Run-Task {0} failed: {1}" -f $name, $_.Exception.Message)
    }
}

function Stop-Task([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    try { & $schtasks /End /TN $name | Out-Null } catch {
        Write-TrayLog -Level error -Message ("Stop-Task {0} failed: {1}" -f $name, $_.Exception.Message)
    }
}

function Get-TaskState([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    try {
        $q = & $schtasks /Query /TN $name /FO LIST /V 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) { return $null }
        $line = ($q -split "`r?`n" | Where-Object { $_ -match '^(Stato|Status)\s*:' } | Select-Object -First 1)
        if ($null -eq $line) { return $null }
        return ($line.Split(':',2)[1]).Trim()
    } catch {
        return $null
    }
}

# ---------------------------
# Icon generation (badge)
# ---------------------------
$baseIconPath = Join-Path $InstallDir 'file.ico'
$baseIcon = $null
try {
    if (Test-Path $baseIconPath) { $baseIcon = New-Object System.Drawing.Icon($baseIconPath) }
} catch { $baseIcon = $null }
if ($null -eq $baseIcon) {
    try { $baseIcon = [System.Drawing.SystemIcons]::Application } catch { }
}

$iconIdle   = $baseIcon
$iconMount  = $baseIcon
$iconError  = $baseIcon

function New-BadgedIcon([System.Drawing.Icon]$src, [System.Drawing.Color]$badgeColor) {
    if (-not $haveDrawing -or $null -eq $src) { return $src }
    try {
        $bmp = $src.ToBitmap()
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $r = 6
        $x = $bmp.Width - $r - 1
        $y = $bmp.Height - $r - 1

        $brush = New-Object System.Drawing.SolidBrush($badgeColor)
        $pen   = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1)

        $g.FillEllipse($brush, $x, $y, $r, $r)
        $g.DrawEllipse($pen, $x, $y, $r, $r)

        $g.Dispose(); $brush.Dispose(); $pen.Dispose()

        $hicon = $bmp.GetHicon()
        $tmp = [System.Drawing.Icon]::FromHandle($hicon)
        $clone = $tmp.Clone()
        $tmp.Dispose()
        try { [Ext4WinNative]::DestroyIcon($hicon) | Out-Null } catch { }
        $bmp.Dispose()
        return $clone
    } catch {
        return $src
    }
}

if ($haveDrawing) {
    $iconIdle  = New-BadgedIcon -src $baseIcon -badgeColor ([System.Drawing.Color]::White)
    $iconMount = New-BadgedIcon -src $baseIcon -badgeColor ([System.Drawing.Color]::Lime)
    $iconError = New-BadgedIcon -src $baseIcon -badgeColor ([System.Drawing.Color]::Red)
}

# ---------------------------
# Status getters
# ---------------------------
function Get-Mounts() {
    $m = Invoke-Ctl -action 'ListMounts'
    if ($null -eq $m) { return @() }
    return @($m)
}

function Get-Ext4List() {
    $e = Invoke-Ctl -action 'ListExt4'
    if ($null -eq $e) { return @() }
    return @($e)
}

function Get-DiskSpaceLines {
    $mounts = Get-Mounts
    if ($null -eq $mounts -or $mounts.Count -eq 0) { return @() }

    $lines = @()
    foreach ($mp in $mounts) {
        try {
            $cmd = "df -B1 --output=size,used,avail,pcent '$mp' 2>/dev/null | tail -n 1"
            $out = & $wsl -d $distro --exec /bin/sh -lc $cmd 2>$null | Out-String
            $out = $out.Trim()
            if ($out -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%') {
                $avail = [double]$matches[3]
                $pct   = [int]$matches[4]

                function Human([double]$b) {
                    if ($b -ge 1099511627776) { return ("{0:N1} TB" -f ($b/1099511627776)) }
                    if ($b -ge 1073741824)    { return ("{0:N1} GB" -f ($b/1073741824)) }
                    if ($b -ge 1048576)       { return ("{0:N1} MB" -f ($b/1048576)) }
                    return ("{0:N0} B" -f $b)
                }

                $seg = 10
                $usedSeg = [Math]::Min($seg, [Math]::Max(0, [Math]::Round($pct/10)))
                $bar = ('█' * $usedSeg) + ('░' * ($seg - $usedSeg))
                $leaf = Split-Path -Leaf $mp
                $lines += ("{0}  [{1}]  {2}% used | {3} free" -f $leaf, $bar, $pct, (Human $avail))
            }
        } catch { }
    }
    return $lines
}

function Open-WslFolder {
    try {
        $p = "\\\\wsl.localhost\\$distro\\mnt\\wsl"
        Start-Process explorer.exe $p | Out-Null
    } catch {
        Write-TrayLog -Level warn -Message ("Open wsl folder failed: {0}" -f $_.Exception.Message)
    }
}

function Shutdown-Wsl {
    try {
        # best effort: ask Ext4Win to unmount, then shutdown WSL VM
        Run-Task $taskUmount
        Start-Sleep -Seconds 2
        & $wsl --shutdown | Out-Null
    } catch {
        Write-TrayLog -Level warn -Message ("Shutdown WSL failed: {0}" -f $_.Exception.Message)
    }
}

# ---------------------------
# Build Tray UI
# ---------------------------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text = (T 'title')
$notify.Icon = $iconIdle
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu

# Header/status
$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$statusItem.Enabled = $false
$null = $menu.Items.Add($statusItem)
$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Mount all / unmount all
$miMountAll = New-Object System.Windows.Forms.ToolStripMenuItem (T 'mountAll')
$miMountAll.Add_Click({ try { Run-Task $taskMount } catch {} }) | Out-Null
$null = $menu.Items.Add($miMountAll)

$miUnmountAll = New-Object System.Windows.Forms.ToolStripMenuItem (T 'unmountAll')
$miUnmountAll.Add_Click({ try { Run-Task $taskUmount } catch {} }) | Out-Null
$null = $menu.Items.Add($miUnmountAll)

# Partitions submenu (dynamic)
$miParts = New-Object System.Windows.Forms.ToolStripMenuItem (T 'partitions')
$null = $menu.Items.Add($miParts)

# Disk space submenu (dynamic)
$miSpace = New-Object System.Windows.Forms.ToolStripMenuItem (T 'diskSpace')
$null = $menu.Items.Add($miSpace)

$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Open WSL folder
$miOpenWsl = New-Object System.Windows.Forms.ToolStripMenuItem (T 'openWsl')
$miOpenWsl.Add_Click({ Open-WslFolder }) | Out-Null
$null = $menu.Items.Add($miOpenWsl)

# Shutdown WSL
$miShutdown = New-Object System.Windows.Forms.ToolStripMenuItem (T 'shutdownWsl')
$miShutdown.Add_Click({ Shutdown-Wsl }) | Out-Null
$null = $menu.Items.Add($miShutdown)

$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Agent submenu
$miAgent = New-Object System.Windows.Forms.ToolStripMenuItem (T 'agent')
$miAgentStart = New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentStart')
$miAgentStart.Add_Click({ try { Run-Task $taskAgent } catch {} }) | Out-Null
$miAgentStop = New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentStop')
$miAgentStop.Add_Click({ try { Stop-Task $taskAgent } catch {} }) | Out-Null
$miAgentRestart = New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentRestart')
$miAgentRestart.Add_Click({ try { Stop-Task $taskAgent; Start-Sleep -Seconds 1; Run-Task $taskAgent } catch {} }) | Out-Null

$null = $miAgent.DropDownItems.Add($miAgentStart)
$null = $miAgent.DropDownItems.Add($miAgentStop)
$null = $miAgent.DropDownItems.Add($miAgentRestart)
$null = $menu.Items.Add($miAgent)

# Update
$miUpdate = New-Object System.Windows.Forms.ToolStripMenuItem (T 'update')
$miUpdate.Add_Click({
    try {
        if (-not [string]::IsNullOrWhiteSpace($taskUpdate)) {
            Run-Task $taskUpdate
        } else {
            Write-TrayLog -Level warn -Message 'Update task not configured.'
        }
    } catch { }
}) | Out-Null
$null = $menu.Items.Add($miUpdate)

# Logs
$miLogs = New-Object System.Windows.Forms.ToolStripMenuItem (T 'logs')
$miLogs.Add_Click({ try { Start-Process explorer.exe $LogDir | Out-Null } catch {} }) | Out-Null
$null = $menu.Items.Add($miLogs)

# Language submenu
$miLang = New-Object System.Windows.Forms.ToolStripMenuItem (T 'language')
$miLangAuto = New-Object System.Windows.Forms.ToolStripMenuItem (T 'auto')
$miLangIt   = New-Object System.Windows.Forms.ToolStripMenuItem (T 'italian')
$miLangEn   = New-Object System.Windows.Forms.ToolStripMenuItem (T 'english')

$miLangAuto.Add_Click({ Set-LanguageConfig 'auto' }) | Out-Null
$miLangIt.Add_Click({ Set-LanguageConfig 'it' }) | Out-Null
$miLangEn.Add_Click({ Set-LanguageConfig 'en' }) | Out-Null

$null = $miLang.DropDownItems.Add($miLangAuto)
$null = $miLang.DropDownItems.Add($miLangIt)
$null = $miLang.DropDownItems.Add($miLangEn)
$null = $menu.Items.Add($miLang)

$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Exit
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem (T 'exit')
$miExit.Add_Click({
    try { $notify.Visible = $false } catch { }
    try { [System.Windows.Forms.Application]::Exit() } catch { }
}) | Out-Null
$null = $menu.Items.Add($miExit)

# ---------------------------
# Dynamic refresh
# ---------------------------
$lastError = $null

function Refresh-DynamicMenus {
    try {
        $ext4 = @(Get-Ext4List)
        $mounts = @(Get-Mounts)

        # Status text
        $agentState = Get-TaskState $taskAgent
        $agentTxt = if ($agentState) { $agentState } else { (T 'notAvailable') }

        $mCount = if ($mounts) { $mounts.Count } else { 0 }
        if ($lastError) {
            $statusItem.Text = "{0}: {1} | Agent: {2}" -f (T 'status'), (T 'error'), $agentTxt
            $notify.Icon = $iconError
        } elseif ($mCount -gt 0) {
            $statusItem.Text = "{0}: {1} ({2}) | Agent: {3}" -f (T 'status'), (T 'mounted'), $mCount, $agentTxt
            $notify.Icon = $iconMount
        } else {
            $statusItem.Text = "{0}: {1} | Agent: {2}" -f (T 'status'), (T 'idle'), $agentTxt
            $notify.Icon = $iconIdle
        }

        # Partitions submenu
        $miParts.DropDownItems.Clear()
        if ($ext4.Count -eq 0) {
            $it = New-Object System.Windows.Forms.ToolStripMenuItem (T 'notAvailable')
            $it.Enabled = $false
            $null = $miParts.DropDownItems.Add($it)
        } else {
            foreach ($p in $ext4) {
                $dn = $p.DiskNumber
                $pn = $p.PartitionNumber
                $name = $p.DiskFriendlyName
                $label = "Disk {0} p{1} - {2}" -f $dn, $pn, $name
                $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
                # show check if mounted path exists
                $mp = "/mnt/wsl/PHYSICALDRIVE{0}p{1}" -f $dn, $pn
                if ($mounts -contains $mp) { $item.Checked = $true }
                $item.Add_Click({
                    param($sender, $e)
                    try {
                        # We don't do per-partition mount/unmount here (keeps compatibility). MountAll/UnmountAll is deterministic.
                        if ($sender.Checked) { Run-Task $taskUmount } else { Run-Task $taskMount }
                    } catch { }
                }) | Out-Null
                $null = $miParts.DropDownItems.Add($item)
            }
        }

        # Disk space submenu
        $miSpace.DropDownItems.Clear()
        $lines = @(Get-DiskSpaceLines)
        if ($lines.Count -eq 0) {
            $it2 = New-Object System.Windows.Forms.ToolStripMenuItem (T 'notAvailable')
            $it2.Enabled = $false
            $null = $miSpace.DropDownItems.Add($it2)
        } else {
            foreach ($ln in $lines) {
                $it3 = New-Object System.Windows.Forms.ToolStripMenuItem $ln
                $it3.Enabled = $false
                $null = $miSpace.DropDownItems.Add($it3)
            }
        }
    } catch {
        $lastError = $_.Exception.Message
        Write-TrayLog -Level error -Message ("Refresh error: {0}" -f $lastError)
        try {
            $notify.Icon = $iconError
            $statusItem.Text = "{0}: {1}" -f (T 'status'), (T 'error')
        } catch { }
    }
}

# refresh on menu opening (so you see live status)
$menu.Add_Opening({ $lastError = $null; Refresh-DynamicMenus }) | Out-Null

# periodic refresh (icon + tooltip)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ $lastError = $null; Refresh-DynamicMenus }) | Out-Null
$timer.Start()

# initial refresh
$lastError = $null
Refresh-DynamicMenus

Write-TrayLog -Level info -Message 'Tray running.'

# Message loop
$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)

# Cleanup
try { $timer.Stop() } catch { }
try { $notify.Visible = $false; $notify.Dispose() } catch { }

Write-TrayLog -Level info -Message 'Tray stopped.'

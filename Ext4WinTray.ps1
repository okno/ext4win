<#
Ext4WinTray.ps1
Version: 4.2
Purpose: Windows tray UI for Ext4Win (WSL2 ext4 mount helper)
- Bilingual IT/EN (auto/it/en)
- Status icon: Green=Mounted, Red=Error, White=Idle
- Menu: Mount/Unmount, Partitions list, Disk space bars, Open WSL folder, Shutdown WSL, Agent/Service controls, Update, Exit
Notes:
- Uses \\wsl.localhost\<Distro>\... (avoids $ parsing issues with \\wsl$)
- No references to non-existent assembly "System.Drawing.Drawing2D"
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# -----------------------------
# Paths / config / logging
# -----------------------------
$InstallDir = Split-Path -Parent $PSCommandPath
$LogDir = Join-Path $InstallDir 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$RuntimeLog = Join-Path $LogDir 'Ext4WinTray.runtime.log'

function Write-TrayLog {
    param(
        [ValidateSet('info','warn','error','debug')][string]$Level = 'info',
        [string]$Message = ''
    )
    try {
        $ts = (Get-Date).ToString('s')
        Add-Content -LiteralPath $RuntimeLog -Value ("{0} [{1}] {2}" -f $ts, $Level, $Message) -Encoding UTF8
    } catch {}
}

Write-TrayLog -Level info -Message ("Tray starting (PID={0})." -f $PID)

$CfgPath = Join-Path $InstallDir 'config.json'
$Cfg = @{}
if (Test-Path -LiteralPath $CfgPath) {
    try { $Cfg = (Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $Cfg = @{} }
}
function CfgGet([string]$k, $default) {
    try {
        if ($null -ne $Cfg.$k -and ($Cfg.$k.ToString().Length -gt 0)) { return $Cfg.$k }
    } catch {}
    return $default
}

$Distro = CfgGet 'distro' 'Debian'
$Lang = (CfgGet 'language' 'auto').ToString().ToLowerInvariant()

$TaskTray    = CfgGet 'task_tray'    'Ext4Win_Tray'
$TaskMount   = CfgGet 'task_mount'   'Ext4Win_MountAll'
$TaskUmount  = CfgGet 'task_unmount' 'Ext4Win_UnmountAll'
$TaskAgent   = CfgGet 'task_agent'   'Ext4Win_Agent'
$TaskUpdate  = CfgGet 'task_update'  'Ext4Win_Update'

$CtlPath = Join-Path $InstallDir 'Ext4WinCtl.ps1'
$IconPath = Join-Path $InstallDir 'file.ico'

# -----------------------------
# i18n strings
# -----------------------------
$Strings = @{
    it = @{
        title      = 'Ext4Win'
        status     = 'Stato'
        mounted    = 'Montato'
        idle       = 'Inattivo'
        error      = 'Errore'
        mountAll   = 'Monta tutto'
        unmountAll = 'Smonta tutto'
        partitions = 'Partizioni ext4'
        diskSpace  = 'Spazio disco'
        openWsl    = 'Apri cartella WSL'
        shutdownWsl= 'Spegni WSL'
        agent      = 'Agent'
        agentStart = 'Avvia Agent'
        agentStop  = 'Ferma Agent'
        agentRestart='Riavvia Agent'
        service    = 'Servizio'
        svcStart   = 'Avvia servizio'
        svcStop    = 'Ferma servizio'
        svcRestart = 'Riavvia servizio'
        update     = 'Aggiorna Ext4Win'
        language   = 'Lingua'
        langAuto   = 'Auto'
        langIt     = 'Italiano'
        langEn     = 'English'
        exit       = 'Esci'
        tip        = 'Ext4Win – Mount ext4 via WSL2'
    }
    en = @{
        title      = 'Ext4Win'
        status     = 'Status'
        mounted    = 'Mounted'
        idle       = 'Idle'
        error      = 'Error'
        mountAll   = 'Mount all'
        unmountAll = 'Unmount all'
        partitions = 'ext4 partitions'
        diskSpace  = 'Disk space'
        openWsl    = 'Open WSL folder'
        shutdownWsl= 'Shutdown WSL'
        agent      = 'Agent'
        agentStart = 'Start Agent'
        agentStop  = 'Stop Agent'
        agentRestart='Restart Agent'
        service    = 'Service'
        svcStart   = 'Start service'
        svcStop    = 'Stop service'
        svcRestart = 'Restart service'
        update     = 'Update Ext4Win'
        language   = 'Language'
        langAuto   = 'Auto'
        langIt     = 'Italiano'
        langEn     = 'English'
        exit       = 'Exit'
        tip        = 'Ext4Win – Mount ext4 via WSL2'
    }
}

if ($Lang -eq 'auto') {
    try {
        $ui = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName.ToLowerInvariant()
        if ($ui -eq 'it') { $Lang = 'it' } else { $Lang = 'en' }
    } catch { $Lang = 'en' }
}
if (-not $Strings.ContainsKey($Lang)) { $Lang = 'en' }
$S = $Strings[$Lang]
function T([string]$Key) {
    if ($S.ContainsKey($Key)) { return $S[$Key] }
    return $Key
}

# Persist language change
function Save-Language([string]$NewLang) {
    try {
        $Cfg.language = $NewLang
        ($Cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $CfgPath -Encoding UTF8
    } catch {}
}

# -----------------------------
# Assemblies
# -----------------------------
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    Write-TrayLog -Level error -Message ("Add-Type failed: {0}" -f $_.Exception.Message)
    # Can't run tray without WinForms + System.Drawing
    exit 1
}

# Win32 DestroyIcon to prevent handle leaks
try {
    Add-Type -Namespace Ext4Win -Name Native -MemberDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Native {
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern bool DestroyIcon(IntPtr handle);
}
"@ -ErrorAction SilentlyContinue | Out-Null
} catch {}

# -----------------------------
# Helpers: tasks / process / json
# -----------------------------
function Run-Task([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    try {
        if (Get-Command Start-ScheduledTask -ErrorAction SilentlyContinue) {
            Start-ScheduledTask -TaskName $Name
        } else {
            & schtasks.exe /Run /TN $Name | Out-Null
        }
    } catch {}
}
function Stop-Task([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    try {
        if (Get-Command Stop-ScheduledTask -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $Name | Out-Null
        } else {
            & schtasks.exe /End /TN $Name | Out-Null
        }
    } catch {}
}
function Get-TaskState([string]$Name) {
    try {
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            $t = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
            $i = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction Stop
            return $i.State.ToString()
        }
    } catch {}
    # fallback schtasks output parse (IT/EN)
    try {
        $out = (& schtasks.exe /Query /TN $Name /FO LIST /V 2>$null) -join "`n"
        if ($out -match '^\s*(Stato|Status)\s*:\s*(.+)\s*$'m) { return $Matches[2].Trim() }
    } catch {}
    return 'Unknown'
}

function Read-JsonSafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Invoke-CtlJson([string[]]$args) {
    if (-not (Test-Path -LiteralPath $CtlPath)) { return @() }
    try {
        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CtlPath @args 2>$null
        if ($null -eq $raw) { return @() }
        $txt = ($raw | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($txt)) { return @() }
        return ($txt | ConvertFrom-Json)
    } catch {
        return @()
    }
}

function Get-Mounts {
    $m = Invoke-CtlJson @('-Action','ListMounts')
    if ($m -is [string]) { return @($m) }
    if ($m -is [System.Collections.IEnumerable]) { return @($m) }
    return @()
}
function Get-Ext4Parts {
    $p = Invoke-CtlJson @('-Action','ListExt4')
    if ($p -is [System.Collections.IEnumerable]) { return @($p) }
    return @()
}

function Open-WslFolder {
    try {
        $path = "\\\\wsl.localhost\\{0}\\mnt\\wsl" -f $Distro
        Start-Process explorer.exe $path | Out-Null
    } catch {
        Write-TrayLog -Level warn -Message ("Open WSL folder failed: {0}" -f $_.Exception.Message)
    }
}

function Shutdown-Wsl {
    try {
        # Best-effort unmount task first (may require elevation)
        Run-Task $TaskUmount
        Start-Sleep -Seconds 2
    } catch {}
    try {
        & wsl.exe --shutdown | Out-Null
    } catch {
        Write-TrayLog -Level warn -Message ("WSL shutdown failed: {0}" -f $_.Exception.Message)
    }
}

function Human-Bytes([Int64]$b) {
    $units = @('B','KB','MB','GB','TB','PB')
    $v = [double]$b
    $i = 0
    while ($v -ge 1024 -and $i -lt ($units.Count-1)) { $v /= 1024; $i++ }
    return ("{0:N1} {1}" -f $v, $units[$i])
}

function Bar([int]$pct, [int]$len=10) {
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $filled = [int][Math]::Round(($pct/100.0)*$len)
    if ($filled -gt $len) { $filled = $len }
    $empty = $len - $filled
    return ('█' * $filled) + ('░' * $empty)
}

function Get-DiskSpaceLines {
    $lines = @()
    $mounts = Get-Mounts
    foreach ($mp in $mounts) {
        try {
            # df -B1P prints: Filesystem 1024-blocks Used Available Capacity Mounted on
            $script = "df -B1P `"$mp`" | tail -1"
            $df = & wsl.exe -d $Distro --exec sh -lc $script 2>$null
            $row = ($df | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($row)) { continue }
            $parts = ($row -split '\s+')
            if ($parts.Count -lt 6) { continue }
            $size  = [Int64]$parts[1]
            $used  = [Int64]$parts[2]
            $avail = [Int64]$parts[3]
            $usep  = $parts[4].TrimEnd('%')
            $pct = 0
            [int]::TryParse($usep, [ref]$pct) | Out-Null
            $label = $mp
            if ($mp -match '/mnt/wsl/([^/]+)') { $label = $Matches[1] }
            $lines += ("{0} [{1}] {2}% | free {3}" -f $label, (Bar $pct 10), $pct, (Human-Bytes $avail))
        } catch {}
    }
    return $lines
}

# -----------------------------
# Icon generation (base ico + colored dot)
# -----------------------------
function Load-BaseIcon {
    try {
        if (Test-Path -LiteralPath $IconPath) {
            return (New-Object System.Drawing.Icon($IconPath))
        }
    } catch {}
    try {
        return [System.Drawing.SystemIcons]::Application
    } catch {
        return $null
    }
}

$BaseIcon = Load-BaseIcon

function New-StatusIcon([System.Drawing.Color]$DotColor) {
    if ($null -eq $BaseIcon) { return $null }
    try {
        $bmp = $BaseIcon.ToBitmap()
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        # Dot bottom-right
        $diam = 9
        $x = $bmp.Width - $diam - 3
        $y = $bmp.Height - $diam - 3
        $brush = New-Object System.Drawing.SolidBrush($DotColor)
        $g.FillEllipse($brush, $x, $y, $diam, $diam)
        $g.Dispose(); $brush.Dispose()
        $h = $bmp.GetHicon()
        $ico = [System.Drawing.Icon]::FromHandle($h).Clone()
        try { [Ext4Win.Native]::DestroyIcon($h) | Out-Null } catch {}
        $bmp.Dispose()
        return $ico
    } catch {
        return $BaseIcon
    }
}

$IconIdle   = New-StatusIcon ([System.Drawing.Color]::White)
$IconMounted= New-StatusIcon ([System.Drawing.Color]::Lime)
$IconError  = New-StatusIcon ([System.Drawing.Color]::Red)

# -----------------------------
# Single instance (mutex)
# -----------------------------
$mutex = $null
try {
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, "Global\Ext4WinTrayMutex", [ref]$created)
    if (-not $created) {
        Write-TrayLog -Level warn -Message 'Another tray instance is already running; exiting.'
        exit 0
    }
} catch {}

# -----------------------------
# UI: NotifyIcon + Menu
# -----------------------------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text = (T 'tip')
$notify.Icon = $IconIdle
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu

# Status header (disabled item)
$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$statusItem.Enabled = $false
$null = $menu.Items.Add($statusItem)
$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Mount/Unmount
$miMountAll = New-Object System.Windows.Forms.ToolStripMenuItem (T 'mountAll')
$miMountAll.Add_Click({ Run-Task $TaskMount }) | Out-Null
$null = $menu.Items.Add($miMountAll)

$miUnmountAll = New-Object System.Windows.Forms.ToolStripMenuItem (T 'unmountAll')
$miUnmountAll.Add_Click({ Run-Task $TaskUmount }) | Out-Null
$null = $menu.Items.Add($miUnmountAll)

# Partitions submenu
$miParts = New-Object System.Windows.Forms.ToolStripMenuItem (T 'partitions')
$null = $menu.Items.Add($miParts)

# Disk space submenu
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
$miAgentStart.Add_Click({ Run-Task $TaskAgent }) | Out-Null
$miAgentStop = New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentStop')
$miAgentStop.Add_Click({ Stop-Task $TaskAgent }) | Out-Null
$miAgentRestart = New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentRestart')
$miAgentRestart.Add_Click({ try { Stop-Task $TaskAgent; Start-Sleep -Seconds 1; Run-Task $TaskAgent } catch {} }) | Out-Null
$null = $miAgent.DropDownItems.Add($miAgentStart)
$null = $miAgent.DropDownItems.Add($miAgentStop)
$null = $miAgent.DropDownItems.Add($miAgentRestart)
$null = $menu.Items.Add($miAgent)

# Service submenu (optional if Ext4WinSvc exists)
$svc = $null
try { $svc = Get-Service -Name 'Ext4WinSvc' -ErrorAction SilentlyContinue } catch {}
if ($null -ne $svc) {
    $miSvc = New-Object System.Windows.Forms.ToolStripMenuItem (T 'service')
    $miSvcStart = New-Object System.Windows.Forms.ToolStripMenuItem (T 'svcStart')
    $miSvcStop  = New-Object System.Windows.Forms.ToolStripMenuItem (T 'svcStop')
    $miSvcRestart= New-Object System.Windows.Forms.ToolStripMenuItem (T 'svcRestart')
    $miSvcStart.Add_Click({ try { Start-Service -Name 'Ext4WinSvc' } catch {} }) | Out-Null
    $miSvcStop.Add_Click({ try { Stop-Service -Name 'Ext4WinSvc' -Force } catch {} }) | Out-Null
    $miSvcRestart.Add_Click({ try { Restart-Service -Name 'Ext4WinSvc' -Force } catch {} }) | Out-Null
    $null = $miSvc.DropDownItems.Add($miSvcStart)
    $null = $miSvc.DropDownItems.Add($miSvcStop)
    $null = $miSvc.DropDownItems.Add($miSvcRestart)
    $null = $menu.Items.Add($miSvc)
}

# Update
$miUpdate = New-Object System.Windows.Forms.ToolStripMenuItem (T 'update')
$miUpdate.Add_Click({ Run-Task $TaskUpdate }) | Out-Null
$null = $menu.Items.Add($miUpdate)

# Language submenu
$miLang = New-Object System.Windows.Forms.ToolStripMenuItem (T 'language')
$miLangAuto = New-Object System.Windows.Forms.ToolStripMenuItem (T 'langAuto')
$miLangIt = New-Object System.Windows.Forms.ToolStripMenuItem (T 'langIt')
$miLangEn = New-Object System.Windows.Forms.ToolStripMenuItem (T 'langEn')
$miLangAuto.Add_Click({ Save-Language 'auto'; [System.Windows.Forms.Application]::Restart() }) | Out-Null
$miLangIt.Add_Click({ Save-Language 'it'; [System.Windows.Forms.Application]::Restart() }) | Out-Null
$miLangEn.Add_Click({ Save-Language 'en'; [System.Windows.Forms.Application]::Restart() }) | Out-Null
$null = $miLang.DropDownItems.Add($miLangAuto)
$null = $miLang.DropDownItems.Add($miLangIt)
$null = $miLang.DropDownItems.Add($miLangEn)
$null = $menu.Items.Add($miLang)

$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

# Exit
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem (T 'exit')
$miExit.Add_Click({
    try {
        $notify.Visible = $false
        $notify.Dispose()
    } catch {}
    try { if ($mutex) { $mutex.ReleaseMutex() | Out-Null; $mutex.Dispose() } } catch {}
    [System.Windows.Forms.Application]::Exit()
}) | Out-Null
$null = $menu.Items.Add($miExit)

# -----------------------------
# Refresh loop
# -----------------------------
$global:LastError = $false

function Refresh-Menu {
    $err = $false
    $mounts = @()
    $parts = @()
    try { $mounts = Get-Mounts } catch { $err = $true }
    try { $parts = Get-Ext4Parts } catch { $err = $true }

    # Status line
    $agentState = Get-TaskState $TaskAgent
    $mCount = @($mounts).Count
    $pCount = @($parts).Count

    $st = "{0} | Agent: {1} | ext4: {2} | {3}: {4}" -f (T 'title'), $agentState, $pCount, (T 'mounted'), $mCount
    $statusItem.Text = $st

    # Icons
    if ($err) {
        $notify.Icon = $IconError
        $notify.Text = (T 'error')
    } elseif ($mCount -gt 0) {
        $notify.Icon = $IconMounted
        $notify.Text = (T 'mounted')
    } else {
        $notify.Icon = $IconIdle
        $notify.Text = (T 'idle')
    }
    $global:LastError = $err

    # Partitions submenu refresh
    try {
        $miParts.DropDownItems.Clear()
        if ($pCount -eq 0) {
            $it = New-Object System.Windows.Forms.ToolStripMenuItem '—'
            $it.Enabled = $false
            $null = $miParts.DropDownItems.Add($it)
        } else {
            foreach ($p in $parts) {
                $dn = $p.DiskNumber
                $pn = $p.PartitionNumber
                $name = "Disk {0} / Part {1}" -f $dn, $pn
                if ($p.DiskFriendlyName) { $name = "{0} (Disk {1} Part {2})" -f $p.DiskFriendlyName, $dn, $pn }
                $it = New-Object System.Windows.Forms.ToolStripMenuItem $name
                $it.Enabled = $false
                $null = $miParts.DropDownItems.Add($it)
            }
        }
    } catch {}

    # Disk space submenu refresh
    try {
        $miSpace.DropDownItems.Clear()
        $lines = Get-DiskSpaceLines
        if (@($lines).Count -eq 0) {
            $it = New-Object System.Windows.Forms.ToolStripMenuItem '—'
            $it.Enabled = $false
            $null = $miSpace.DropDownItems.Add($it)
        } else {
            foreach ($ln in $lines) {
                $it = New-Object System.Windows.Forms.ToolStripMenuItem $ln
                $it.Enabled = $false
                $null = $miSpace.DropDownItems.Add($it)
            }
        }
    } catch {}
}

# Timer
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({ Refresh-Menu }) | Out-Null
$timer.Start()

# Initial refresh
Refresh-Menu

Write-TrayLog -Level info -Message 'Tray running.'

# Message loop
$appCtx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($appCtx)

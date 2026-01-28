<#
Ext4WinTray.ps1
Version: 4.4
Windows tray UI for Ext4Win (WSL2 ext4 mount helper)

Fixes in v4.4:
- Removed invalid PowerShell regex syntax (no "'m" multiline flag outside string)
- Avoids non-ASCII in source to prevent encoding-related parsing issues on Windows PowerShell 5.1
- Robust scheduled task state parsing without multiline regex
- Still provides: IT/EN, Shutdown WSL, disk space bar, status icon colors

Run:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File C:\ext4win\Ext4WinTray.ps1

Logs:
  C:\ext4win\logs\Ext4WinTray.runtime.log (internal)
  C:\ext4win\logs\Ext4WinTray.out.log     (stdout/stderr if started via RunTray.cmd)
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

$TaskMount   = CfgGet 'task_mount'   'Ext4Win_MountAll'
$TaskUmount  = CfgGet 'task_unmount' 'Ext4Win_UnmountAll'
$TaskAgent   = CfgGet 'task_agent'   'Ext4Win_Agent'
$TaskUpdate  = CfgGet 'task_update'  'Ext4Win_Update'

$CtlPath = Join-Path $InstallDir 'Ext4WinCtl.ps1'
$IconPath = Join-Path $InstallDir 'file.ico'

# -----------------------------
# i18n strings (ASCII-only source)
# -----------------------------
$Strings = @{
    it = @{
        title       = 'Ext4Win'
        status      = 'Stato'
        mounted     = 'Montato'
        idle        = 'Inattivo'
        error       = 'Errore'
        mountAll    = 'Monta tutto'
        unmountAll  = 'Smonta tutto'
        partitions  = 'Partizioni ext4'
        diskSpace   = 'Spazio disco'
        openWsl     = 'Apri cartella WSL'
        shutdownWsl = 'Spegni WSL'
        agent       = 'Agent'
        agentStart  = 'Avvia Agent'
        agentStop   = 'Ferma Agent'
        agentRestart= 'Riavvia Agent'
        service     = 'Servizio'
        svcStart    = 'Avvia servizio'
        svcStop     = 'Ferma servizio'
        svcRestart  = 'Riavvia servizio'
        update      = 'Aggiorna Ext4Win'
        language    = 'Lingua'
        langAuto    = 'Auto'
        langIt      = 'Italiano'
        langEn      = 'English'
        exit        = 'Esci'
        tip         = 'Ext4Win - Mount ext4 via WSL2'
    }
    en = @{
        title       = 'Ext4Win'
        status      = 'Status'
        mounted     = 'Mounted'
        idle        = 'Idle'
        error       = 'Error'
        mountAll    = 'Mount all'
        unmountAll  = 'Unmount all'
        partitions  = 'ext4 partitions'
        diskSpace   = 'Disk space'
        openWsl     = 'Open WSL folder'
        shutdownWsl = 'Shutdown WSL'
        agent       = 'Agent'
        agentStart  = 'Start Agent'
        agentStop   = 'Stop Agent'
        agentRestart= 'Restart Agent'
        service     = 'Service'
        svcStart    = 'Start service'
        svcStop     = 'Stop service'
        svcRestart  = 'Restart service'
        update      = 'Update Ext4Win'
        language    = 'Language'
        langAuto    = 'Auto'
        langIt      = 'Italiano'
        langEn      = 'English'
        exit        = 'Exit'
        tip         = 'Ext4Win - Mount ext4 via WSL2'
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

function Save-Language([string]$NewLang) {
    try {
        $Cfg.language = $NewLang
        ($Cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $CfgPath -Encoding UTF8
    } catch {}
}

# -----------------------------
# Assemblies (robust load)
# -----------------------------
function Try-LoadAssembly([string]$name, [string[]]$paths) {
    try {
        Add-Type -AssemblyName $name -ErrorAction Stop
        return $true
    } catch {
        foreach ($p in $paths) {
            try {
                if (Test-Path -LiteralPath $p) {
                    Add-Type -Path $p -ErrorAction Stop
                    return $true
                }
            } catch {}
        }
        return $false
    }
}

$fw64 = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$fw32 = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
$formsOk = Try-LoadAssembly 'System.Windows.Forms' @(
    (Join-Path $fw64 'System.Windows.Forms.dll'),
    (Join-Path $fw32 'System.Windows.Forms.dll')
)
$drawOk = Try-LoadAssembly 'System.Drawing' @(
    (Join-Path $fw64 'System.Drawing.dll'),
    (Join-Path $fw32 'System.Drawing.dll')
)

if (-not $formsOk) {
    Write-TrayLog -Level error -Message 'Cannot load System.Windows.Forms. Tray cannot start.'
    exit 1
}
if (-not $drawOk) {
    Write-TrayLog -Level warn -Message 'Cannot explicitly load System.Drawing. Will attempt to continue.'
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
# Helpers: tasks / json / WSL
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
        if (Get-Command Get-ScheduledTaskInfo -ErrorAction SilentlyContinue) {
            $i = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction Stop
            return $i.State.ToString()
        }
    } catch {}

    try {
        $lines = & schtasks.exe /Query /TN $Name /FO LIST /V 2>$null
        foreach ($ln in $lines) {
            # Match both Italian and English output
            if ($ln -match '^\s*(Stato|Status)\s*:\s*(.+)\s*$') {
                return $Matches[2].Trim()
            }
        }
    } catch {}
    return 'Unknown'
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
    try { Run-Task $TaskUmount; Start-Sleep -Seconds 2 } catch {}
    try { & wsl.exe --shutdown | Out-Null } catch {
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

function Bar([int]$pct, [int]$len) {
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $filled = [int][Math]::Round(($pct/100.0)*$len)
    if ($filled -gt $len) { $filled = $len }
    $empty = $len - $filled
    return ('#' * $filled) + ('-' * $empty)
}

function Get-DiskSpaceLines {
    $lines = @()
    $mounts = Get-Mounts
    foreach ($mp in $mounts) {
        try {
            $script = "df -B1P `"$mp`" | tail -1"
            $df = & wsl.exe -d $Distro --exec sh -lc $script 2>$null
            $row = ($df | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($row)) { continue }
            $parts = ($row -split '\s+')
            if ($parts.Count -lt 6) { continue }
            $avail = [Int64]$parts[3]
            $usep  = $parts[4].TrimEnd('%')
            $pct = 0; [int]::TryParse($usep, [ref]$pct) | Out-Null
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
    try { return [System.Drawing.SystemIcons]::Application } catch { return $null }
}
$BaseIcon = Load-BaseIcon

function New-StatusIcon([System.Drawing.Color]$DotColor) {
    if ($null -eq $BaseIcon) { return $null }
    try {
        $bmp = $BaseIcon.ToBitmap()
        $g = [System.Drawing.Graphics]::FromImage($bmp)
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

$IconIdle    = New-StatusIcon ([System.Drawing.Color]::White)
$IconMounted = New-StatusIcon ([System.Drawing.Color]::Lime)
$IconError   = New-StatusIcon ([System.Drawing.Color]::Red)

# -----------------------------
# Single instance mutex
# -----------------------------
$mutex = $null
try {
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, "Ext4WinTrayMutex", [ref]$created)
    if (-not $created) {
        Write-TrayLog -Level warn -Message 'Another tray instance is already running; exiting.'
        exit 0
    }
} catch {}

# -----------------------------
# UI + main loop (global try/catch)
# -----------------------------
try {
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Text = (T 'tip')
    $notify.Icon = $IconIdle
    $notify.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $notify.ContextMenuStrip = $menu

    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Enabled = $false
    [void]$menu.Items.Add($statusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miMountAll = New-Object System.Windows.Forms.ToolStripMenuItem (T 'mountAll')
    $miMountAll.Add_Click({ Run-Task $TaskMount }) | Out-Null
    [void]$menu.Items.Add($miMountAll)

    $miUnmountAll = New-Object System.Windows.Forms.ToolStripMenuItem (T 'unmountAll')
    $miUnmountAll.Add_Click({ Run-Task $TaskUmount }) | Out-Null
    [void]$menu.Items.Add($miUnmountAll)

    $miParts = New-Object System.Windows.Forms.ToolStripMenuItem (T 'partitions')
    [void]$menu.Items.Add($miParts)

    $miSpace = New-Object System.Windows.Forms.ToolStripMenuItem (T 'diskSpace')
    [void]$menu.Items.Add($miSpace)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miOpenWsl = New-Object System.Windows.Forms.ToolStripMenuItem (T 'openWsl')
    $miOpenWsl.Add_Click({ Open-WslFolder }) | Out-Null
    [void]$menu.Items.Add($miOpenWsl)

    $miShutdown = New-Object System.Windows.Forms.ToolStripMenuItem (T 'shutdownWsl')
    $miShutdown.Add_Click({ Shutdown-Wsl }) | Out-Null
    [void]$menu.Items.Add($miShutdown)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miAgent = New-Object System.Windows.Forms.ToolStripMenuItem (T 'agent')
    $miAgentStart = New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentStart')
    $miAgentStart.Add_Click({ Run-Task $TaskAgent }) | Out-Null
    $miAgentStop = New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentStop')
    $miAgentStop.Add_Click({ Stop-Task $TaskAgent }) | Out-Null
    $miAgentRestart = New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentRestart')
    $miAgentRestart.Add_Click({ try { Stop-Task $TaskAgent; Start-Sleep -Seconds 1; Run-Task $TaskAgent } catch {} }) | Out-Null

    [void]$miAgent.DropDownItems.Add($miAgentStart)
    [void]$miAgent.DropDownItems.Add($miAgentStop)
    [void]$miAgent.DropDownItems.Add($miAgentRestart)
    [void]$menu.Items.Add($miAgent)

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
        [void]$miSvc.DropDownItems.Add($miSvcStart)
        [void]$miSvc.DropDownItems.Add($miSvcStop)
        [void]$miSvc.DropDownItems.Add($miSvcRestart)
        [void]$menu.Items.Add($miSvc)
    }

    $miUpdate = New-Object System.Windows.Forms.ToolStripMenuItem (T 'update')
    $miUpdate.Add_Click({ Run-Task $TaskUpdate }) | Out-Null
    [void]$menu.Items.Add($miUpdate)

    $miLang = New-Object System.Windows.Forms.ToolStripMenuItem (T 'language')
    $miLangAuto = New-Object System.Windows.Forms.ToolStripMenuItem (T 'langAuto')
    $miLangIt = New-Object System.Windows.Forms.ToolStripMenuItem (T 'langIt')
    $miLangEn = New-Object System.Windows.Forms.ToolStripMenuItem (T 'langEn')

    function Restart-Tray {
        try {
            Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File', $PSCommandPath) `
                -WorkingDirectory $InstallDir -WindowStyle Hidden | Out-Null
        } catch {}
        try { [System.Windows.Forms.Application]::Exit() } catch {}
    }

    $miLangAuto.Add_Click({ Save-Language 'auto'; Restart-Tray }) | Out-Null
    $miLangIt.Add_Click({ Save-Language 'it'; Restart-Tray }) | Out-Null
    $miLangEn.Add_Click({ Save-Language 'en'; Restart-Tray }) | Out-Null

    [void]$miLang.DropDownItems.Add($miLangAuto)
    [void]$miLang.DropDownItems.Add($miLangIt)
    [void]$miLang.DropDownItems.Add($miLangEn)
    [void]$menu.Items.Add($miLang)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem (T 'exit')
    $miExit.Add_Click({
        try { $notify.Visible = $false; $notify.Dispose() } catch {}
        try { if ($mutex) { $mutex.ReleaseMutex() | Out-Null; $mutex.Dispose() } } catch {}
        try { [System.Windows.Forms.Application]::Exit() } catch {}
    }) | Out-Null
    [void]$menu.Items.Add($miExit)

    function Refresh-Menu {
        $err = $false
        $mounts = @()
        $parts = @()

        try { $mounts = Get-Mounts } catch { $err = $true }
        try { $parts = Get-Ext4Parts } catch { $err = $true }

        $agentState = Get-TaskState $TaskAgent
        $mCount = @($mounts).Count
        $pCount = @($parts).Count

        $statusItem.Text = ("{0} | Agent: {1} | ext4: {2} | {3}: {4}" -f (T 'title'), $agentState, $pCount, (T 'mounted'), $mCount)

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

        try {
            $miParts.DropDownItems.Clear()
            if ($pCount -eq 0) {
                $it = New-Object System.Windows.Forms.ToolStripMenuItem '-'
                $it.Enabled = $false
                [void]$miParts.DropDownItems.Add($it)
            } else {
                foreach ($p in $parts) {
                    $dn = $p.DiskNumber
                    $pn = $p.PartitionNumber
                    $name = "Disk {0} / Part {1}" -f $dn, $pn
                    if ($p.DiskFriendlyName) { $name = "{0} (Disk {1} Part {2})" -f $p.DiskFriendlyName, $dn, $pn }
                    $it = New-Object System.Windows.Forms.ToolStripMenuItem $name
                    $it.Enabled = $false
                    [void]$miParts.DropDownItems.Add($it)
                }
            }
        } catch {}

        try {
            $miSpace.DropDownItems.Clear()
            $lines = Get-DiskSpaceLines
            if (@($lines).Count -eq 0) {
                $it = New-Object System.Windows.Forms.ToolStripMenuItem '-'
                $it.Enabled = $false
                [void]$miSpace.DropDownItems.Add($it)
            } else {
                foreach ($ln in $lines) {
                    $it = New-Object System.Windows.Forms.ToolStripMenuItem $ln
                    $it.Enabled = $false
                    [void]$miSpace.DropDownItems.Add($it)
                }
            }
        } catch {}
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 4000
    $timer.Add_Tick({ Refresh-Menu }) | Out-Null
    $timer.Start()

    Refresh-Menu
    Write-TrayLog -Level info -Message 'Tray running.'

    $appCtx = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($appCtx)
}
catch {
    Write-TrayLog -Level error -Message ("Tray fatal error: {0}" -f $_.Exception.Message)
    try { Write-TrayLog -Level error -Message ($_.ScriptStackTrace) } catch {}
    exit 1
}
finally {
    try { if ($mutex) { $mutex.Dispose() } } catch {}
}

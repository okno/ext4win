<#
Ext4WinTray.ps1
Version: 4.6
Hotfix: prevent UI hangs + stop process explosions.

Main changes vs 4.5:
- FIXED bug: array concatenation in function calls (was passing '+' as an argument) which caused continuous failures and re-launch storms.
- Added timeouts for external calls (powershell/wsl/schtasks).
- Added refresh re-entrancy guard.
- Disk space computed only when opening submenu.
- Hard safety: if too many WSL-related processes are detected, refresh pauses.

#>

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$InstallDir = Split-Path -Parent $PSCommandPath
$LogDir = Join-Path $InstallDir 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$RuntimeLog = Join-Path $LogDir 'Ext4WinTray.runtime.log'

function Write-TrayLog {
    param([string]$Level='info',[string]$Message='')
    try {
        $ts = (Get-Date).ToString('s')
        Add-Content -LiteralPath $RuntimeLog -Value ("{0} [{1}] {2}" -f $ts,$Level,$Message) -Encoding UTF8
    } catch {}
}
Write-TrayLog info ("Tray starting (PID={0})." -f $PID)

# Mutex early
$mutex=$null
try {
  $created=$false
  $mutex = New-Object System.Threading.Mutex($true, "Ext4WinTrayMutex", [ref]$created)
  if (-not $created) { Write-TrayLog warn "Another tray instance is already running; exiting."; exit 0 }
} catch {
  Write-TrayLog warn ("Mutex init failed: {0}" -f $_.Exception.Message)
}

# Config
$CfgPath = Join-Path $InstallDir 'config.json'
$Cfg=@{}
if (Test-Path -LiteralPath $CfgPath) {
  try { $Cfg = (Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $Cfg=@{} }
}
function CfgGet([string]$k,$d){ try{ if($null -ne $Cfg.$k -and ($Cfg.$k.ToString().Length -gt 0)){return $Cfg.$k}}catch{}; return $d }

$Distro = CfgGet 'distro' 'Debian'
$Lang = (CfgGet 'language' 'auto').ToString().ToLowerInvariant()
$TaskMount  = CfgGet 'task_mount' 'Ext4Win_MountAll'
$TaskUmount = CfgGet 'task_unmount' 'Ext4Win_UnmountAll'
$TaskAgent  = CfgGet 'task_agent' 'Ext4Win_Agent'
$TaskUpdate = CfgGet 'task_update' 'Ext4Win_Update'
$CtlPath = Join-Path $InstallDir 'Ext4WinCtl.ps1'
$IconPath = Join-Path $InstallDir 'file.ico'

$Strings=@{
 it=@{ title='Ext4Win'; mounted='Montato'; idle='Inattivo'; error='Errore'; mountAll='Monta tutto'; unmountAll='Smonta tutto';
       partitions='Partizioni ext4'; diskSpace='Spazio disco'; openWsl='Apri cartella WSL'; shutdownWsl='Spegni WSL';
       agent='Agent'; agentStart='Avvia Agent'; agentStop='Ferma Agent'; agentRestart='Riavvia Agent'; update='Aggiorna Ext4Win';
       language='Lingua'; langAuto='Auto'; langIt='Italiano'; langEn='English'; exit='Esci'; tip='Ext4Win - Mount ext4 via WSL2';
       loading='Aggiornamento...'; openToRefresh='Apri per aggiornare'; paused='Refresh in pausa (troppe istanze WSL)' }
 en=@{ title='Ext4Win'; mounted='Mounted'; idle='Idle'; error='Error'; mountAll='Mount all'; unmountAll='Unmount all';
       partitions='ext4 partitions'; diskSpace='Disk space'; openWsl='Open WSL folder'; shutdownWsl='Shutdown WSL';
       agent='Agent'; agentStart='Start Agent'; agentStop='Stop Agent'; agentRestart='Restart Agent'; update='Update Ext4Win';
       language='Language'; langAuto='Auto'; langIt='Italiano'; langEn='English'; exit='Exit'; tip='Ext4Win - Mount ext4 via WSL2';
       loading='Refreshing...'; openToRefresh='Open to refresh'; paused='Refresh paused (too many WSL instances)' }
}
if ($Lang -eq 'auto') {
  try { $ui=[System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName.ToLowerInvariant(); if($ui -eq 'it'){$Lang='it'}else{$Lang='en'} } catch { $Lang='en' }
}
if (-not $Strings.ContainsKey($Lang)) { $Lang='en' }
$S=$Strings[$Lang]
function T([string]$k){ if($S.ContainsKey($k)){return $S[$k]} return $k }
function Save-Language([string]$NewLang){ try{$Cfg.language=$NewLang; ($Cfg|ConvertTo-Json -Depth 6)|Set-Content -LiteralPath $CfgPath -Encoding UTF8}catch{} }

# Assemblies
function Try-LoadAssembly([string]$name,[string[]]$paths){
  try{ Add-Type -AssemblyName $name -ErrorAction Stop; return $true } catch {
    foreach($p in $paths){ try{ if(Test-Path -LiteralPath $p){ Add-Type -Path $p -ErrorAction Stop; return $true } }catch{} }
    return $false
  }
}
$fw64 = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$fw32 = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
if (-not (Try-LoadAssembly 'System.Windows.Forms' @((Join-Path $fw64 'System.Windows.Forms.dll'),(Join-Path $fw32 'System.Windows.Forms.dll')))) { Write-TrayLog error "Cannot load System.Windows.Forms."; exit 1 }
Try-LoadAssembly 'System.Drawing' @((Join-Path $fw64 'System.Drawing.dll'),(Join-Path $fw32 'System.Drawing.dll')) | Out-Null

# DestroyIcon (optional)
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

# Process helper with timeout
function Quote-Arg([string]$a){ if($null -eq $a){return '""'}; if($a -match '[\s"]'){ return '"' + ($a -replace '"','\\"') + '"' }; return $a }

function Invoke-ProcessCapture {
 param([string]$FilePath,[string[]]$Args=@(),[int]$TimeoutMs=1500,[string]$WorkDir=$InstallDir)
 $outFile = Join-Path $env:TEMP ("ext4win_tray_out_{0}.txt" -f ([guid]::NewGuid().ToString('n')))
 $errFile = Join-Path $env:TEMP ("ext4win_tray_err_{0}.txt" -f ([guid]::NewGuid().ToString('n')))
 try{
   $argLine = ($Args | ForEach-Object { Quote-Arg $_ }) -join ' '
   $p = Start-Process -FilePath $FilePath -ArgumentList $argLine -WorkingDirectory $WorkDir -WindowStyle Hidden -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru
   if(-not $p.WaitForExit($TimeoutMs)){ try{$p.Kill()}catch{}; return @{ok=$false;timeout=$true;exitcode=124;stdout='';stderr=("timeout {0}ms" -f $TimeoutMs)} }
   $stdout=''; $stderr=''
   try{ if(Test-Path -LiteralPath $outFile){ $stdout=Get-Content -Raw -LiteralPath $outFile -ErrorAction SilentlyContinue } }catch{}
   try{ if(Test-Path -LiteralPath $errFile){ $stderr=Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue } }catch{}
   return @{ok=$true;timeout=$false;exitcode=$p.ExitCode;stdout=$stdout;stderr=$stderr}
 } finally { Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue }
}

function Run-Task([string]$Name){ if([string]::IsNullOrWhiteSpace($Name)){return}; try{ & schtasks.exe /Run /TN $Name | Out-Null }catch{} }
function Stop-Task([string]$Name){ if([string]::IsNullOrWhiteSpace($Name)){return}; try{ & schtasks.exe /End /TN $Name | Out-Null }catch{} }

$CacheAgentState='Unknown'; $LastAgentCheck=Get-Date '2000-01-01'
function Get-TaskState([string]$Name){
 $now=Get-Date
 if(($now-$LastAgentCheck).TotalSeconds -lt 15){ return $CacheAgentState }
 try{
   $r=Invoke-ProcessCapture -FilePath 'schtasks.exe' -Args @('/Query','/TN',$Name,'/FO','LIST','/V') -TimeoutMs 1200
   $state='Unknown'
   if($r.ok){
     foreach($ln in ($r.stdout -split "`r?`n")){ if($ln -match '^\s*(Stato|Status)\s*:\s*(.+)\s*$'){ $state=$Matches[2].Trim(); break } }
   }
   $CacheAgentState=$state; $LastAgentCheck=$now; return $CacheAgentState
 } catch { $CacheAgentState='Unknown'; $LastAgentCheck=$now; return $CacheAgentState }
}

function Invoke-CtlJson([string[]]$args){
 if(-not (Test-Path -LiteralPath $CtlPath)){ return @() }
 try{
   $fullArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$CtlPath) + $args
   $r = Invoke-ProcessCapture -FilePath 'powershell.exe' -Args $fullArgs -TimeoutMs 1800 -WorkDir $InstallDir
   if(-not $r.ok){ return @() }
   $txt = ($r.stdout | Out-String).Trim()
   if([string]::IsNullOrWhiteSpace($txt)){ return @() }
   return ($txt | ConvertFrom-Json)
 } catch {
   Write-TrayLog warn ("Ext4WinCtl parse error: {0}" -f $_.Exception.Message)
   return @()
 }
}
function Get-Mounts{ $m=Invoke-CtlJson @('-Action','ListMounts'); if($m -is [string]){return @($m)}; if($m -is [System.Collections.IEnumerable]){return @($m)}; @() }
function Get-Ext4Parts{ $p=Invoke-CtlJson @('-Action','ListExt4'); if($p -is [System.Collections.IEnumerable]){return @($p)}; @() }

function Open-WslFolder{ try{ Start-Process explorer.exe ("\\wsl.localhost\{0}\mnt\wsl" -f $Distro) | Out-Null }catch{} }
function Shutdown-Wsl{ try{ Run-Task $TaskUmount; Start-Sleep 2 }catch{}; try{ & wsl.exe --shutdown | Out-Null }catch{} }

function Human-Bytes([Int64]$b){ $u=@('B','KB','MB','GB','TB','PB'); $v=[double]$b; $i=0; while($v -ge 1024 -and $i -lt ($u.Count-1)){ $v/=1024; $i++ }; ("{0:N1} {1}" -f $v,$u[$i]) }
function Bar([int]$pct,[int]$len){ if($pct -lt 0){$pct=0}; if($pct -gt 100){$pct=100}; $f=[int][Math]::Round(($pct/100.0)*$len); if($f -gt $len){$f=$len}; ('#'*$f)+('-'*($len-$f)) }

function Get-DiskSpaceLines([string[]]$mounts){
 $lines=@()
 foreach($mp in $mounts){
  try{
    $script = "df -B1P `"$mp`" | tail -1"
    $r = Invoke-ProcessCapture -FilePath 'wsl.exe' -Args @('-d',$Distro,'--exec','sh','-lc',$script) -TimeoutMs 1500
    if(-not $r.ok){ continue }
    $row = ($r.stdout | Out-String).Trim()
    if([string]::IsNullOrWhiteSpace($row)){ continue }
    $parts = ($row -split '\s+')
    if($parts.Count -lt 6){ continue }
    $avail=[Int64]$parts[3]
    $usep=$parts[4].TrimEnd('%')
    $pct=0; [int]::TryParse($usep,[ref]$pct) | Out-Null
    $label=$mp; if($mp -match '/mnt/wsl/([^/]+)'){ $Matches[1] | Out-Null; $label=$Matches[1] }
    $lines += ("{0} [{1}] {2}% | free {3}" -f $label,(Bar $pct 10),$pct,(Human-Bytes $avail))
  } catch {}
 }
 $lines
}

function Load-BaseIcon{ try{ if(Test-Path -LiteralPath $IconPath){ return (New-Object System.Drawing.Icon($IconPath)) } }catch{}; try{ [System.Drawing.SystemIcons]::Application }catch{ $null } }
$BaseIcon = Load-BaseIcon

function New-StatusIcon([System.Drawing.Color]$DotColor){
 if($null -eq $BaseIcon){ return $null }
 try{
  $bmp=$BaseIcon.ToBitmap()
  $g=[System.Drawing.Graphics]::FromImage($bmp)
  $diam=9; $x=$bmp.Width-$diam-3; $y=$bmp.Height-$diam-3
  $brush=New-Object System.Drawing.SolidBrush($DotColor)
  $g.FillEllipse($brush,$x,$y,$diam,$diam)
  $g.Dispose(); $brush.Dispose()
  $h=$bmp.GetHicon()
  $ico=[System.Drawing.Icon]::FromHandle($h).Clone()
  try{ [Ext4Win.Native]::DestroyIcon($h) | Out-Null }catch{}
  $bmp.Dispose()
  $ico
 } catch { $BaseIcon }
}
$IconIdle=New-StatusIcon ([System.Drawing.Color]::White)
$IconMounted=New-StatusIcon ([System.Drawing.Color]::Lime)
$IconError=New-StatusIcon ([System.Drawing.Color]::Red)

function TooManyWslProcesses {
  try { ((Get-Process -Name 'wsl','wslhost','conhost' -ErrorAction SilentlyContinue | Measure-Object).Count) -gt 200 } catch { $false }
}

# UI
try{
 $notify=New-Object System.Windows.Forms.NotifyIcon
 $notify.Text=(T 'tip')
 $notify.Icon=$IconIdle
 $notify.Visible=$true

 $menu=New-Object System.Windows.Forms.ContextMenuStrip
 $notify.ContextMenuStrip=$menu

 $statusItem=New-Object System.Windows.Forms.ToolStripMenuItem
 $statusItem.Enabled=$false
 [void]$menu.Items.Add($statusItem)
 [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

 $miMountAll=New-Object System.Windows.Forms.ToolStripMenuItem (T 'mountAll')
 $miMountAll.Add_Click({ Run-Task $TaskMount }) | Out-Null
 [void]$menu.Items.Add($miMountAll)

 $miUnmountAll=New-Object System.Windows.Forms.ToolStripMenuItem (T 'unmountAll')
 $miUnmountAll.Add_Click({ Run-Task $TaskUmount }) | Out-Null
 [void]$menu.Items.Add($miUnmountAll)

 $miParts=New-Object System.Windows.Forms.ToolStripMenuItem (T 'partitions')
 [void]$menu.Items.Add($miParts)

 $miSpace=New-Object System.Windows.Forms.ToolStripMenuItem (T 'diskSpace')
 [void]$menu.Items.Add($miSpace)

 [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

 $miOpenWsl=New-Object System.Windows.Forms.ToolStripMenuItem (T 'openWsl')
 $miOpenWsl.Add_Click({ Open-WslFolder }) | Out-Null
 [void]$menu.Items.Add($miOpenWsl)

 $miShutdown=New-Object System.Windows.Forms.ToolStripMenuItem (T 'shutdownWsl')
 $miShutdown.Add_Click({ Shutdown-Wsl }) | Out-Null
 [void]$menu.Items.Add($miShutdown)

 [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

 $miAgent=New-Object System.Windows.Forms.ToolStripMenuItem (T 'agent')
 $miAgentStart=New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentStart')
 $miAgentStart.Add_Click({ Run-Task $TaskAgent }) | Out-Null
 $miAgentStop=New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentStop')
 $miAgentStop.Add_Click({ Stop-Task $TaskAgent }) | Out-Null
 $miAgentRestart=New-Object System.Windows.Forms.ToolStripMenuItem (T 'agentRestart')
 $miAgentRestart.Add_Click({ try{ Stop-Task $TaskAgent; Start-Sleep 1; Run-Task $TaskAgent }catch{} }) | Out-Null
 [void]$miAgent.DropDownItems.Add($miAgentStart)
 [void]$miAgent.DropDownItems.Add($miAgentStop)
 [void]$miAgent.DropDownItems.Add($miAgentRestart)
 [void]$menu.Items.Add($miAgent)

 $miUpdate=New-Object System.Windows.Forms.ToolStripMenuItem (T 'update')
 $miUpdate.Add_Click({ Run-Task $TaskUpdate }) | Out-Null
 [void]$menu.Items.Add($miUpdate)

 $miLang=New-Object System.Windows.Forms.ToolStripMenuItem (T 'language')
 $miLangAuto=New-Object System.Windows.Forms.ToolStripMenuItem (T 'langAuto')
 $miLangIt=New-Object System.Windows.Forms.ToolStripMenuItem (T 'langIt')
 $miLangEn=New-Object System.Windows.Forms.ToolStripMenuItem (T 'langEn')

 function Restart-Tray{
  try{ Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',$PSCommandPath) -WorkingDirectory $InstallDir -WindowStyle Hidden | Out-Null }catch{}
  try{ [System.Windows.Forms.Application]::Exit() }catch{}
 }
 $miLangAuto.Add_Click({ Save-Language 'auto'; Restart-Tray }) | Out-Null
 $miLangIt.Add_Click({ Save-Language 'it'; Restart-Tray }) | Out-Null
 $miLangEn.Add_Click({ Save-Language 'en'; Restart-Tray }) | Out-Null
 [void]$miLang.DropDownItems.Add($miLangAuto)
 [void]$miLang.DropDownItems.Add($miLangIt)
 [void]$miLang.DropDownItems.Add($miLangEn)
 [void]$menu.Items.Add($miLang)

 [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

 $miExit=New-Object System.Windows.Forms.ToolStripMenuItem (T 'exit')
 $miExit.Add_Click({
   try{ $notify.Visible=$false; $notify.Dispose() }catch{}
   try{ if($mutex){ $mutex.ReleaseMutex() | Out-Null; $mutex.Dispose() } }catch{}
   try{ [System.Windows.Forms.Application]::Exit() }catch{}
 }) | Out-Null
 [void]$menu.Items.Add($miExit)

 $CacheMounts=@(); $CacheParts=@(); $CacheErr=$false
 $RefreshInProgress=$false

 function Populate-PartsFromCache{
  try{
   $miParts.DropDownItems.Clear()
   if(@($CacheParts).Count -eq 0){ $it=New-Object System.Windows.Forms.ToolStripMenuItem '-'; $it.Enabled=$false; [void]$miParts.DropDownItems.Add($it); return }
   foreach($p in $CacheParts){
     $name=("Disk {0} / Part {1}" -f $p.DiskNumber,$p.PartitionNumber)
     if($p.DiskFriendlyName){ $name=("{0} (Disk {1} Part {2})" -f $p.DiskFriendlyName,$p.DiskNumber,$p.PartitionNumber) }
     $it=New-Object System.Windows.Forms.ToolStripMenuItem $name; $it.Enabled=$false; [void]$miParts.DropDownItems.Add($it)
   }
  }catch{}
 }

 function Populate-SpaceLazy{
  try{
    $miSpace.DropDownItems.Clear()
    $ph=New-Object System.Windows.Forms.ToolStripMenuItem (T 'loading'); $ph.Enabled=$false; [void]$miSpace.DropDownItems.Add($ph)
    $lines = Get-DiskSpaceLines -mounts @($CacheMounts)
    $miSpace.DropDownItems.Clear()
    if(@($lines).Count -eq 0){ $it=New-Object System.Windows.Forms.ToolStripMenuItem '-'; $it.Enabled=$false; [void]$miSpace.DropDownItems.Add($it) }
    else { foreach($ln in $lines){ $it=New-Object System.Windows.Forms.ToolStripMenuItem $ln; $it.Enabled=$false; [void]$miSpace.DropDownItems.Add($it) } }
  }catch{}
 }

 $miParts.Add_DropDownOpening({ Populate-PartsFromCache }) | Out-Null
 $miSpace.Add_DropDownOpening({ Populate-SpaceLazy }) | Out-Null

 function Refresh-State{
  if($RefreshInProgress){ return }
  $RefreshInProgress=$true
  try{
    if(TooManyWslProcesses){
      $CacheErr=$true
      $statusItem.Text=(T 'paused')
      $notify.Icon=$IconError
      return
    }
    $CacheMounts=@(Get-Mounts)
    $CacheParts=@(Get-Ext4Parts)
    $agentState=Get-TaskState $TaskAgent
    $statusItem.Text=("{0} | Agent: {1} | ext4: {2} | mounts: {3}" -f (T 'title'),$agentState,@($CacheParts).Count,@($CacheMounts).Count)
    if(@($CacheMounts).Count -gt 0){ $notify.Icon=$IconMounted } else { $notify.Icon=$IconIdle }
    Populate-PartsFromCache
    $miSpace.DropDownItems.Clear()
    $it=New-Object System.Windows.Forms.ToolStripMenuItem (T 'openToRefresh'); $it.Enabled=$false; [void]$miSpace.DropDownItems.Add($it)
  } finally { $RefreshInProgress=$false }
 }

 $menu.Add_Opening({ Refresh-State }) | Out-Null

 $timer=New-Object System.Windows.Forms.Timer
 $timer.Interval=5000
 $timer.Add_Tick({ Refresh-State }) | Out-Null
 $timer.Start()

 Refresh-State
 Write-TrayLog info "Tray running."

 $appCtx=New-Object System.Windows.Forms.ApplicationContext
 [System.Windows.Forms.Application]::Run($appCtx)
}
catch{
 Write-TrayLog error ("Tray fatal error: {0}" -f $_.Exception.Message)
 try{ Write-TrayLog error ($_.ScriptStackTrace) }catch{}
 exit 1
}
finally{
 try{ if($mutex){ $mutex.Dispose() } }catch{}
}

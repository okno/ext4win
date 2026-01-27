# Ext4WinCore.ps1 - v4.0 - by Pawel Zorzan Urban 'okno' - zorzan.pawel@gmail.com
# Core functions (detection ext4, mount/unmount via WSL, keepalive, logging).
# NOTE: Keep this file self-contained and PowerShell 5.1 compatible.

Set-StrictMode -Off

# --- Globals ---
$global:Ext4WinInstallDir = Split-Path -Parent $PSCommandPath
$global:Ext4WinLogsDir    = Join-Path $global:Ext4WinInstallDir 'logs'
$global:Ext4WinRunDir     = Join-Path $global:Ext4WinInstallDir 'run'
$global:Ext4WinDocsDir    = Join-Path $global:Ext4WinInstallDir 'docs'
$global:Ext4WinConfigPath = Join-Path $global:Ext4WinInstallDir 'config.json'
New-Item -ItemType Directory -Force -Path $global:Ext4WinLogsDir, $global:Ext4WinRunDir | Out-Null

# --- Logging ---
function Write-Ext4WinLog {
  param(
    [Parameter(Mandatory=$true)][ValidateSet('info','warn','error','debug')][string]$Level,
    [Parameter(Mandatory=$true)][string]$Message,
    [string]$File = 'Ext4Win.log'
  )
  try {
    $path = Join-Path $global:Ext4WinLogsDir $File
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    Add-Content -LiteralPath $path -Value ("{0} [{1}] {2}" -f $ts, $Level, $Message)
  } catch { }
}

# --- Config ---
function Get-Ext4WinConfig {
  try {
    $raw = Get-Content -LiteralPath $global:Ext4WinConfigPath -Raw -ErrorAction Stop
    $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
    return $cfg
  } catch {
    return [pscustomobject]@{
      install_dir = $global:Ext4WinInstallDir
      distro = 'Debian'
      language = 'auto'
      offline_before_mount = $true
      auto_open_explorer = $true
      explorer_subpath = ''
      keepalive = @{ mode = 'wsl_sleep' }
      agent = @{ enabled = $true; poll_seconds = 5; open_explorer_on_new_mount = $true }
    }
  }
}

function Save-Ext4WinConfig {
  param([Parameter(Mandatory=$true)]$Config)
  try {
    ($Config | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $global:Ext4WinConfigPath -Encoding UTF8
    return $true
  } catch {
    return $false
  }
}

function Set-Ext4WinConfigValue {
  param(
    [Parameter(Mandatory=$true)][string]$Key,
    [Parameter(Mandatory=$true)]$Value
  )
  $cfg = Get-Ext4WinConfig
  try {
    $cfg | Add-Member -Force -NotePropertyName $Key -NotePropertyValue $Value
  } catch {
    # fallback: rebuild object
    $h = @{}
    $cfg.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
    $h[$Key] = $Value
    $cfg = [pscustomobject]$h
  }
  [void](Save-Ext4WinConfig -Config $cfg)
  return $cfg
}

# --- Privileges ---
function Test-Ext4WinAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal $id
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
  } catch {
    return $false
  }
}

# --- External invocation (native commands) ---
function Invoke-Ext4WinExternal {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string[]]$Arguments
  )
  $oldEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $FilePath @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
  } finally {
    $ErrorActionPreference = $oldEAP
  }
}

function Get-Ext4WinWslPath {
  $p = Join-Path $env:SystemRoot 'System32\wsl.exe'
  if (Test-Path -LiteralPath $p) { return $p }
  $cmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Get-Ext4WinPrereqs {
  $wsl = Get-Ext4WinWslPath
  if (-not $wsl) { return [pscustomobject]@{ ok = $false; reason = 'wsl.exe non trovato' } }

  # Check support --mount. Normalizzo NUL e spazi perché alcune localizzazioni stampano help "spaziato".
  $res = Invoke-Ext4WinExternal -FilePath $wsl -Arguments @('--help')
  $help = ($res.Output -replace "`0","")
  $helpNorm = ($help -replace '\s+','')
  if ($helpNorm -notmatch '--mount') {
    return [pscustomobject]@{ ok = $false; reason = 'La tua versione di WSL non supporta wsl --mount'; wsl = $wsl }
  }

  $cfg = Get-Ext4WinConfig
  $distro = $cfg.distro
  if (-not $distro) { $distro = 'Debian' }

  return [pscustomobject]@{ ok = $true; wsl = $wsl; distro = $distro }
}

# --- Raw helpers (ext4 magic + GPT parsing) ---
function ConvertTo-GuidString {
  param([byte[]]$Bytes16)
  try {
    $g = New-Object System.Guid -ArgumentList (,$Bytes16)
    return $g.ToString().ToUpperInvariant()
  } catch { return '' }
}

$script:LinuxFsGuid = '0FC63DAF-8483-4772-8E79-3D69D8477DE4'

function Read-Ext4Magic {
  param([int]$DiskNumber, [UInt64]$PartitionOffset)
  $diskPath = "\\.\PHYSICALDRIVE$DiskNumber"
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($diskPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    # ext4 superblock is at offset 1024; magic at 0x38 inside superblock
    $pos = [Int64]($PartitionOffset + 1024 + 0x38)
    [void]$fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] 2
    $n = $fs.Read($buf,0,2)
    if ($n -ne 2) { return $false }
    return ($buf[0] -eq 0x53 -and $buf[1] -eq 0xEF)
  } catch {
    return $false
  } finally {
    if ($fs) { $fs.Dispose() }
  }
}

function Read-GptPartitions {
  param([int]$DiskNumber)
  $diskPath = "\\.\PHYSICALDRIVE$DiskNumber"
  $fs = $null
  $list = @()
  try {
    $fs = [System.IO.File]::Open($diskPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)

    $hdr = New-Object byte[] 512
    [void]$fs.Seek(512, [System.IO.SeekOrigin]::Begin) # LBA1
    $r = $fs.Read($hdr,0,512)
    if ($r -lt 92) { return @() }

    $sig = [System.Text.Encoding]::ASCII.GetString($hdr,0,8)
    if ($sig -ne 'EFI PART') { return @() }

    $partLba = [BitConverter]::ToUInt64($hdr,72)
    $num = [BitConverter]::ToUInt32($hdr,80)
    $esz = [BitConverter]::ToUInt32($hdr,84)
    if ($num -lt 1 -or $esz -lt 128) { return @() }

    $entriesOff = [Int64]($partLba * 512)
    $entryBuf = New-Object byte[] $esz

    for ($i=0; $i -lt $num; $i++) {
      $off = $entriesOff + [Int64]($i * $esz)
      [void]$fs.Seek($off, [System.IO.SeekOrigin]::Begin)
      $rr = $fs.Read($entryBuf,0,$esz)
      if ($rr -lt 56) { break }

      $typeBytes = New-Object byte[] 16
      [Array]::Copy($entryBuf,0,$typeBytes,0,16)
      $allZero = $true
      foreach ($b in $typeBytes) { if ($b -ne 0) { $allZero=$false; break } }
      if ($allZero) { continue }

      $typeGuid = ConvertTo-GuidString -Bytes16 $typeBytes
      $firstLba = [BitConverter]::ToUInt64($entryBuf,32)
      $lastLba  = [BitConverter]::ToUInt64($entryBuf,40)
      if ($firstLba -eq 0 -or $lastLba -lt $firstLba) { continue }

      $pOffset = [UInt64]($firstLba * 512)
      $pSize   = [UInt64](($lastLba - $firstLba + 1) * 512)
      $pNum    = $i + 1

      $list += [pscustomobject]@{
        PartitionNumber = $pNum
        PartitionOffset = $pOffset
        PartitionSize   = $pSize
        GptType         = $typeGuid
      }
    }

    return $list
  } catch {
    return @()
  } finally {
    if ($fs) { $fs.Dispose() }
  }
}

# --- Detection (v3.3 logic: Type OR Magic; fallback RawGPT+Magic when Get-Partition fails) ---
function Get-Ext4WinExt4Partitions {
  $out = @()
  $disks = @()
  try { $disks = @(Get-Disk | Sort-Object Number) } catch { $disks = @() }

  $linuxGuid = [Guid]'0FC63DAF-8483-4772-8E79-3D69D8477DE4'

  foreach ($d in $disks) {
    try { if ($d.IsBoot -or $d.IsSystem) { continue } } catch { }

    $dn = [int]$d.Number
    $parts = @()
    try { $parts = @(Get-Partition -DiskNumber $dn -ErrorAction Stop) } catch { $parts = @() }

    $foundThisDisk = $false

    foreach ($p in $parts) {
      $pNum = 0
      try { $pNum = [int]$p.PartitionNumber } catch { $pNum = 0 }

      $offset = $null
      $size   = 0
      try { $offset = [UInt64]$p.Offset } catch { $offset = $null }
      try { $size   = [UInt64]$p.Size } catch { $size = 0 }

      $isLinuxType = $false
      try {
        if ($p.PSObject.Properties.Name -contains 'GptType' -and $p.GptType) {
          try { if ([Guid]$p.GptType -eq $linuxGuid) { $isLinuxType = $true } } catch { }
        }
      } catch { }

      try {
        if (-not $isLinuxType -and $p.PSObject.Properties.Name -contains 'MbrType' -and $null -ne $p.MbrType) {
          try { if ([int]$p.MbrType -eq 131) { $isLinuxType = $true } } catch { }
        }
      } catch { }

      $hasMagic = $false
      if ($null -ne $offset) {
        try { $hasMagic = Read-Ext4Magic -DiskNumber $dn -PartitionOffset $offset } catch { $hasMagic = $false }
      }

      if ($isLinuxType -or $hasMagic) {
        $det = @()
        if ($isLinuxType) { $det += 'Type' }
        if ($hasMagic)   { $det += 'Magic' }
        if ($det.Count -eq 0) { $det += 'Heuristic' }

        $po = 0
        if ($null -ne $offset) { $po = [UInt64]$offset }

        $out += [pscustomobject]@{
          DiskNumber       = $dn
          PartitionNumber  = $pNum
          PartitionSize    = [UInt64]$size
          PartitionOffset  = [UInt64]$po
          DetectedBy       = 'Get-Partition+' + ($det -join '+')
          DiskFriendlyName = $d.FriendlyName
          DiskBusType      = $d.BusType.ToString()
          DiskSize         = [UInt64]$d.Size
          DiskIsOffline    = [bool]$d.IsOffline
          DiskStatus       = $d.OperationalStatus.ToString()
        }

        $foundThisDisk = $true
      }
    }

    if (-not $foundThisDisk) {
      # Fallback RAW GPT (solo magic) - utile quando Get-Partition non funziona (es. disco OFFLINE).
      $gptParts = @()
      try { $gptParts = @(Read-GptPartitions -DiskNumber $dn) } catch { $gptParts = @() }

      foreach ($gp in $gptParts) {
        try {
          if (Read-Ext4Magic -DiskNumber $dn -PartitionOffset $gp.PartitionOffset) {
            $out += [pscustomobject]@{
              DiskNumber       = $dn
              PartitionNumber  = [int]$gp.PartitionNumber
              PartitionSize    = [UInt64]$gp.PartitionSize
              PartitionOffset  = [UInt64]$gp.PartitionOffset
              DetectedBy       = 'RawGPT+Magic'
              DiskFriendlyName = $d.FriendlyName
              DiskBusType      = $d.BusType.ToString()
              DiskSize         = [UInt64]$d.Size
              DiskIsOffline    = [bool]$d.IsOffline
              DiskStatus       = $d.OperationalStatus.ToString()
            }
          }
        } catch { }
      }
    }
  }

  return $out
}

# --- Mount listing ---
function Get-Ext4WinMountpoint {
  param([int]$DiskNumber, [int]$PartitionNumber)
  return ("/mnt/wsl/PHYSICALDRIVE{0}p{1}" -f $DiskNumber, $PartitionNumber)
}

function Get-Ext4WinMounts {
  $pr = Get-Ext4WinPrereqs
  if (-not $pr.ok) { return @() }
  $cmd = 'for d in /mnt/wsl/PHYSICALDRIVE*p*; do [ -d "$d" ] && echo "$d"; done 2>/dev/null'
  $res = Invoke-Ext4WinExternal -FilePath $pr.wsl -Arguments @('-d', $pr.distro, '--exec', 'sh', '-lc', $cmd)

  $lines = @()
  foreach ($l in ($res.Output -split "`r?`n")) {
    $t = $l.Trim()
    if ($t) { $lines += $t }
  }
  return $lines
}

# --- KeepAlive (Windows process wsl.exe -d <distro> --exec /bin/sleep infinity) ---
function Start-Ext4WinKeepAlive {
  $pr = Get-Ext4WinPrereqs
  if (-not $pr.ok) { return $false }
  $pidFile = Join-Path $global:Ext4WinRunDir 'keepalive.pid'

  if (Test-Path -LiteralPath $pidFile) {
    try {
      $pid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
      if ($pid -gt 0 -and (Get-Process -Id $pid -ErrorAction SilentlyContinue)) { return $true }
    } catch { }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
  }

  try {
    $p = Start-Process -FilePath $pr.wsl -ArgumentList @('-d', $pr.distro, '--exec', '/bin/sleep', 'infinity') -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $pidFile -Value $p.Id -Encoding ASCII
    Write-Ext4WinLog -Level 'info' -Message ("KeepAlive avviato (Windows PID={0})" -f $p.Id)
    return $true
  } catch {
    Write-Ext4WinLog -Level 'error' -Message ("KeepAlive start failed: {0}" -f $_.Exception.Message)
    return $false
  }
}

function Stop-Ext4WinKeepAlive {
  $pidFile = Join-Path $global:Ext4WinRunDir 'keepalive.pid'
  if (-not (Test-Path -LiteralPath $pidFile)) { return $true }
  try {
    $pid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($pid -gt 0) { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    Write-Ext4WinLog -Level 'info' -Message ("KeepAlive stop (Windows PID={0})" -f $pid)
    return $true
  } catch {
    return $false
  }
}

# --- Explorer path helpers ---
function Get-Ext4WinExplorerPath {
  param([int]$DiskNumber, [int]$PartitionNumber, [string]$SubPath = '')
  $pr = Get-Ext4WinPrereqs
  if (-not $pr.ok) { return $null }
  $mp = ("PHYSICALDRIVE{0}p{1}" -f $DiskNumber, $PartitionNumber)
  $base = ("\\wsl.localhost\{0}\mnt\wsl\{1}" -f $pr.distro, $mp)
  if ($SubPath) { return (Join-Path $base $SubPath) }
  return $base
}

function Open-Ext4WinExplorer {
  param([int]$DiskNumber, [int]$PartitionNumber)
  $cfg = Get-Ext4WinConfig
  $sub = $cfg.explorer_subpath
  $path = Get-Ext4WinExplorerPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -SubPath $sub
  if (-not $path) { return }
  try { Start-Process explorer.exe $path | Out-Null } catch { }
}

# --- Mount/Unmount ---
function Mount-Ext4WinPartition {
  param([int]$DiskNumber, [int]$PartitionNumber)

  $pr = Get-Ext4WinPrereqs
  if (-not $pr.ok) { throw ("Prerequisiti non OK: {0}" -f $pr.reason) }
  if (-not (Test-Ext4WinAdmin)) { throw 'Serve PowerShell come Amministratore per wsl --mount.' }

  $cfg = Get-Ext4WinConfig
  $diskPath = ("\\.\PHYSICALDRIVE{0}" -f $DiskNumber)

  if ($cfg.offline_before_mount -eq $true) {
    try {
      $d = Get-Disk -Number $DiskNumber -ErrorAction Stop
      if (-not $d.IsOffline) {
        Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction Stop
        Write-Ext4WinLog -Level 'info' -Message ("Disk {0} portato OFFLINE prima del mount." -f $DiskNumber)
      }
    } catch {
      Write-Ext4WinLog -Level 'warn' -Message ("Impossibile portare OFFLINE Disk {0}: {1}" -f $DiskNumber, $_.Exception.Message)
    }
  }

  Write-Ext4WinLog -Level 'info' -Message ("Mount: {0} partition {1}" -f $diskPath, $PartitionNumber)
  $res = Invoke-Ext4WinExternal -FilePath $pr.wsl -Arguments @('--mount', $diskPath, '--partition', "$PartitionNumber", '--type', 'ext4')

  if ($res.ExitCode -ne 0) {
    if ($res.Output -match 'WSL_E_DISK_ALREADY_MOUNTED') {
      Write-Ext4WinLog -Level 'warn' -Message ("Disk {0} già montato in WSL (WSL_E_DISK_ALREADY_MOUNTED) - considero OK." -f $DiskNumber)
    } else {
      Write-Ext4WinLog -Level 'error' -Message ("Mount failed Disk {0} Part {1}: {2}" -f $DiskNumber, $PartitionNumber, ($res.Output.Trim()))
      throw ("Ext4Win: mount fallito: {0}" -f ($res.Output.Trim()))
    }
  }

  [void](Start-Ext4WinKeepAlive)

  if ($cfg.auto_open_explorer -eq $true) {
    Open-Ext4WinExplorer -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber
  }
}

function MountAll-Ext4Win {
  $parts = @(Get-Ext4WinExt4Partitions)
  foreach ($p in $parts) {
    try {
      Mount-Ext4WinPartition -DiskNumber ([int]$p.DiskNumber) -PartitionNumber ([int]$p.PartitionNumber)
    } catch {
      Write-Ext4WinLog -Level 'error' -Message ("MountAll error Disk {0} Part {1}: {2}" -f $p.DiskNumber, $p.PartitionNumber, $_.Exception.Message)
    }
  }
}

function UnmountDisk-Ext4Win {
  param([int]$DiskNumber)
  $pr = Get-Ext4WinPrereqs
  if (-not $pr.ok) { return }
  if (-not (Test-Ext4WinAdmin)) { throw 'Serve PowerShell come Amministratore per wsl --unmount.' }

  $diskPath = ("\\.\PHYSICALDRIVE{0}" -f $DiskNumber)
  Write-Ext4WinLog -Level 'info' -Message ("Unmount: {0}" -f $diskPath)
  $res = Invoke-Ext4WinExternal -FilePath $pr.wsl -Arguments @('--unmount', $diskPath)

  # ExitCode != 0 qui spesso è "not found" (non montato) -> warn only
  if ($res.ExitCode -ne 0 -and $res.Output) {
    Write-Ext4WinLog -Level 'warn' -Message ("Unmount warning Disk {0}: {1}" -f $DiskNumber, ($res.Output.Trim()))
  }
}

function UnmountAll-Ext4Win {
  $parts = @(Get-Ext4WinExt4Partitions)
  $done = @{}
  foreach ($p in $parts) {
    $dn = [int]$p.DiskNumber
    if ($done.ContainsKey($dn)) { continue }
    try { UnmountDisk-Ext4Win -DiskNumber $dn } catch { }
    $done[$dn] = $true
  }

  $m = @(Get-Ext4WinMounts)
  if ($m.Count -eq 0) { [void](Stop-Ext4WinKeepAlive) }
}

# --- Diagnostics ---
function Get-Ext4WinDiag {
  $pr = Get-Ext4WinPrereqs
  $disks = @()
  try { $disks = @(Get-Disk | Sort-Object Number | Select-Object Number,FriendlyName,BusType,IsOffline,OperationalStatus,Size) } catch { $disks = @() }
  return [pscustomobject]@{
    time    = (Get-Date).ToString('s')
    isAdmin = (Test-Ext4WinAdmin)
    prereqs = $pr
    disks   = $disks
    ext4    = @(Get-Ext4WinExt4Partitions)
    mounts  = @(Get-Ext4WinMounts)
  }
}

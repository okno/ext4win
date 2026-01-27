<# 
Ext4WinAgent.ps1 - v4.0 - by Pawel Zorzan Urban 'okno' - zorzan.pawel@gmail.com
Background "service" (actually a Scheduled Task) that:
- detects ext4 partitions
- mounts them via WSL
- keeps them alive via wsl sleep
- optionally opens Explorer on new mounts

It writes:
  logs\Ext4WinAgent.log
  run\agent.status.json  (heartbeat/state for tray)

Stop:
- Preferred: Task Scheduler -> End Task (or tray Stop)
- Optional: create file run\agent.stop to request clean exit
#>

[CmdletBinding()]
param(
  [switch]$RunOnce
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Ext4WinCore.ps1"

$cfg = Get-Ext4WinConfig
$poll = 5
try { if ($cfg.agent -and $cfg.agent.poll_seconds) { $poll = [int]$cfg.agent.poll_seconds } } catch { $poll = 5 }
if ($poll -lt 2) { $poll = 2 }

$stopFile = Join-Path $global:Ext4WinRunDir 'agent.stop'
$stateFile = Join-Path $global:Ext4WinRunDir 'agent.status.json'
$pidFile   = Join-Path $global:Ext4WinRunDir 'agent.pid'

# record PID
try { Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII } catch { }

Write-Ext4WinLog -Level 'info' -Message ("Agent start (PID={0}, poll={1}s)" -f $PID, $poll) -File 'Ext4WinAgent.log'

$seen = @{}  # key: mountpoint -> firstSeen time

function Save-AgentState {
  param(
    [bool]$Ok,
    [string]$LastError,
    [object[]]$Ext4,
    [string[]]$Mounts
  )
  try {
    $obj = [pscustomobject]@{
      time      = (Get-Date).ToString('s')
      pid       = $PID
      ok        = $Ok
      lastError = $LastError
      ext4Count = ($Ext4 | Measure-Object).Count
      mounts    = $Mounts
    }
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $stateFile -Encoding UTF8
  } catch { }
}

while ($true) {
  if (Test-Path -LiteralPath $stopFile) {
    try { Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue } catch { }
    Write-Ext4WinLog -Level 'info' -Message "Agent stop requested (stop file)." -File 'Ext4WinAgent.log'
    break
  }

  $lastErr = $null
  $ok = $true

  try {
    $pr = Get-Ext4WinPrereqs
    if (-not $pr.ok) {
      $ok = $false
      $lastErr = $pr.reason
    } else {
      $parts  = @(Get-Ext4WinExt4Partitions)
      $mounts = @(Get-Ext4WinMounts)

      # Mount missing
      foreach ($p in $parts) {
        $mp = Get-Ext4WinMountpoint -DiskNumber ([int]$p.DiskNumber) -PartitionNumber ([int]$p.PartitionNumber)
        $already = ($mounts -contains $mp)
        if (-not $already) {
          try {
            Mount-Ext4WinPartition -DiskNumber ([int]$p.DiskNumber) -PartitionNumber ([int]$p.PartitionNumber)

            # Refresh mounts list
            $mounts = @(Get-Ext4WinMounts)

            # Explorer on new mount (optional)
            $open = $false
            try { if ($cfg.agent -and $cfg.agent.open_explorer_on_new_mount -eq $true) { $open = $true } } catch { $open = $false }
            if ($open) {
              try { Open-Ext4WinExplorer -DiskNumber ([int]$p.DiskNumber) -PartitionNumber ([int]$p.PartitionNumber) } catch { }
            }
          } catch {
            $ok = $false
            $lastErr = $_.Exception.Message
            Write-Ext4WinLog -Level 'error' -Message ("Agent mount error: {0}" -f $lastErr) -File 'Ext4WinAgent.log'
          }
        }

        # Track mounts for "seen" (for diagnostics)
        if (-not $seen.ContainsKey($mp)) {
          $seen[$mp] = (Get-Date).ToString('s')
        }
      }

      # KeepAlive management
      if ($mounts.Count -gt 0) { [void](Start-Ext4WinKeepAlive) }
      else { [void](Stop-Ext4WinKeepAlive) }

      Save-AgentState -Ok $ok -LastError $lastErr -Ext4 $parts -Mounts $mounts
    }
  } catch {
    $ok = $false
    $lastErr = $_.Exception.Message
    Write-Ext4WinLog -Level 'error' -Message ("Agent loop error: {0}" -f $lastErr) -File 'Ext4WinAgent.log'
  }

  if (-not $pr -or -not $pr.ok) {
    Save-AgentState -Ok $ok -LastError $lastErr -Ext4 @() -Mounts @()
  }

  if ($RunOnce) { break }
  Start-Sleep -Seconds $poll
}

# Cleanup
try { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue } catch { }
Save-AgentState -Ok $false -LastError "stopped" -Ext4 @() -Mounts @()
Write-Ext4WinLog -Level 'info' -Message "Agent stopped." -File 'Ext4WinAgent.log'

<# 
Ext4WinCtl.ps1 - v4.0 - by Pawel Zorzan Urban 'okno' - zorzan.pawel@gmail.com
CLI controller for Ext4Win (useful for scripting and troubleshooting).

Examples (run as Admin for mount/unmount):
  .\Ext4WinCtl.ps1 -Action Prereqs
  .\Ext4WinCtl.ps1 -Action Diag
  .\Ext4WinCtl.ps1 -Action ListExt4
  .\Ext4WinCtl.ps1 -Action MountAll
  .\Ext4WinCtl.ps1 -Action UnmountAll
  .\Ext4WinCtl.ps1 -Action ListMounts

Single partition:
  .\Ext4WinCtl.ps1 -Action Mount -DiskNumber 1 -PartitionNumber 1
  .\Ext4WinCtl.ps1 -Action Unmount -DiskNumber 1
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('Prereqs','Diag','ListExt4','MountAll','UnmountAll','ListMounts','Mount','Unmount')]
  [string]$Action,

  [int]$DiskNumber,
  [int]$PartitionNumber
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Ext4WinCore.ps1"

switch ($Action) {
  'Prereqs'   { (Get-Ext4WinPrereqs) | ConvertTo-Json -Depth 6 }
  'Diag'      { (Get-Ext4WinDiag)     | ConvertTo-Json -Depth 8 }
  'ListExt4'  { @(Get-Ext4WinExt4Partitions) | ConvertTo-Json -Depth 8 }
  'MountAll'  { MountAll-Ext4Win }
  'UnmountAll'{ UnmountAll-Ext4Win }
  'ListMounts'{ @(Get-Ext4WinMounts) | ConvertTo-Json -Depth 4 }

  'Mount' {
    if ($DiskNumber -lt 0 -or $PartitionNumber -lt 1) { throw 'Usa -DiskNumber e -PartitionNumber.' }
    Mount-Ext4WinPartition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber
  }
  'Unmount' {
    if ($DiskNumber -lt 0) { throw 'Usa -DiskNumber.' }
    UnmountDisk-Ext4Win -DiskNumber $DiskNumber
  }
}

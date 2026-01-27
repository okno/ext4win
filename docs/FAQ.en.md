# Ext4Win – FAQ (English)

## What is Ext4Win?

Ext4Win is an open‑source tool for Windows 10/11 that allows you to mount **ext4** partitions in **read/write** mode via **WSL2**, making them accessible from Windows Explorer through `\\wsl.localhost\\<Distro>\\mnt\\wsl\\...`.

## Why use Ext4Win instead of paid drivers?

* No proprietary kernel drivers
* No paid licenses
* Uses native Windows functionality (`wsl.exe --mount`)
* Safer and more transparent for technical, IR and forensic workflows

## Requirements

* Windows 10 2004+ or Windows 11
* WSL2 installed
* At least one WSL distribution (Debian recommended)
* Administrator privileges for mounting disks

## Where are disks mounted?

Disks are mounted inside WSL under:

```
/mnt/wsl/PHYSICALDRIVE<NUM>p<PART>
```

And are accessible from Windows via:

```
\\wsl.localhost\\Debian\\mnt\\wsl\\...
```

## How to mount all ext4 partitions

```powershell
C:\ext4win\Ext4WinCtl.ps1 -Action MountAll
```

## How to unmount everything

```powershell
C:\ext4win\Ext4WinCtl.ps1 -Action UnmountAll
```

## How to start the system tray

```powershell
schtasks /Run /TN Ext4Win_Tray
```

## How to close the tray

From the tray menu → **Exit**

Or force it:

```powershell
Get-Process powershell | Where-Object { $_.CommandLine -like "*Ext4WinTray.ps1*" } | Stop-Process -Force
```

## How to start or stop the Agent (logical service)

Start:

```powershell
schtasks /Run /TN Ext4Win_Agent
```

Stop:

```powershell
schtasks /End /TN Ext4Win_Agent
```

## Recommended full restart procedure

```powershell
C:\ext4win\Ext4WinCtl.ps1 -Action UnmountAll
wsl --shutdown
schtasks /End /TN Ext4Win_Agent
schtasks /End /TN Ext4Win_Tray
schtasks /Run /TN Ext4Win_Agent
schtasks /Run /TN Ext4Win_Tray
C:\ext4win\Ext4WinCtl.ps1 -Action MountAll
```

## How to check overall status

```powershell
C:\ext4win\Ext4WinCtl.ps1 -Action Diag
```

## Partition appears briefly then disappears

This is almost always **USB power management**.

Recommended fix:

```powershell
powercfg -setacvalueindex SCHEME_CURRENT SUB_USB USBSELECTSUSPEND 0
powercfg -setdcvalueindex SCHEME_CURRENT SUB_USB USBSELECTSUSPEND 0
powercfg -setactive SCHEME_CURRENT
```

Disable disk sleep:

```powershell
powercfg -change -disk-timeout-ac 0
powercfg -change -disk-timeout-dc 0
```

## Ext4Win does not detect the ext4 disk

Check if Windows sees the disk:

```powershell
Get-Disk
```

If it does not appear here, Ext4Win cannot mount it.

## Useful logs

```powershell
C:\ext4win\logs\Ext4Win.log
C:\ext4win\logs\Ext4WinTray.runtime.log
C:\ext4win\logs\Ext4WinTray.out.log
```

## Full reset without uninstalling

```powershell
C:\ext4win\Ext4WinCtl.ps1 -Action UnmountAll
wsl --unmount
wsl --shutdown
schtasks /End /TN Ext4Win_Agent
schtasks /End /TN Ext4Win_Tray
```

---

If the issue persists, please open a GitHub issue and attach the output of `-Action Diag` and the log files.


## Why does the disk become OFFLINE in Windows?

In many scenarios WSL requires the disk to be OFFLINE on the Windows side before `wsl --mount` can attach it to WSL2.  
Seeing `IsOffline = True` in `Get-Disk` after mount is expected.

You can disable it in `config.json`:
- `offline_before_mount: false`

## Why admin privileges?

`wsl --mount` and `wsl --unmount` interact with physical disks, so Windows requires elevation.

Ext4Win uses elevated scheduled tasks to avoid repeated UAC prompts.

## Where are logs?

`C:\ext4win\logs\`

## Tray icon not showing

- Check task: `schtasks /Query /TN Ext4Win_Tray /V /FO LIST`
- Run manually:
  - `powershell -NoProfile -ExecutionPolicy Bypass -STA -File "C:\ext4win\Ext4WinTray.ps1"`


# FAQ (EN)

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


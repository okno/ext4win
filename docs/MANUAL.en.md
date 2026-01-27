# Ext4Win Manual (EN)

## 1) What is Ext4Win

Ext4Win automates `wsl.exe --mount` to mount **ext4** disks into WSL2 and expose them to Windows via:

- `\\wsl.localhost\<Distro>\mnt\wsl\PHYSICALDRIVE<n>p<m>\`

Ext4Win does **not** install an ext4 driver on Windows. It relies on **WSL2** (Linux kernel) to mount ext4 natively.

## 2) Architecture

- **Ext4WinCore.ps1**  
  Core library: disk/partition detection, mount/unmount, keepalive, logging.
- **Ext4WinCtl.ps1**  
  CLI controller.
- **Ext4WinTray.ps1**  
  Tray UI, bilingual IT/EN, status and commands.
- **Ext4WinAgent.ps1**  
  “Service” (scheduled task) performing auto-detect and auto-mount.

### Scheduled tasks

- `Ext4Win_Tray`  
  Starts `Ext4WinTray.ps1` at user logon (elevated).
- `Ext4Win_Agent`  
  Starts `Ext4WinAgent.ps1` at user logon (elevated, loop).
- `Ext4Win_MountAll` / `Ext4Win_UnmountAll`  
  On-demand tasks used by Desktop shortcuts.

## 3) Stable mount flow

WSL may detach/lose mounts when idle. Ext4Win uses a keepalive:

- `wsl.exe -d <Distro> --exec /bin/sleep infinity`

The Windows PID is stored in:
- `C:\ext4win\run\keepalive.pid`

## 4) Paths

- WSL mountpoint: `/mnt/wsl/PHYSICALDRIVE<n>p<m>`
- Explorer:
  - `\\wsl.localhost\Debian\mnt\wsl\PHYSICALDRIVE1p1\`

## 5) Configuration (config.json)

Key options:

- `distro`
- `offline_before_mount` (recommended `true`)
- `auto_open_explorer`
- `language`: `auto` / `it` / `en`
- `agent.poll_seconds`
- `agent.open_explorer_on_new_mount`

## 6) Quick troubleshooting

### “Ext4Win does not see my disk”

- Check Windows sees it:
  - `Get-Disk`
- Check Ext4Win detection:
  - `C:\ext4win\Ext4WinCtl.ps1 -Action ListExt4`

### “Mount disappears after a few seconds”

- Keepalive not running:
  - check `run\keepalive.pid`
  - check logs
- Ensure the Agent is running (tray → Service).


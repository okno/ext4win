# Ext4Win

Ext4Win is a lightweight helper for **Windows 10/11** that mounts **ext4** partitions (physical/USB/VHD) into **WSL2** using `wsl.exe --mount`, keeps the mount “alive” (keepalive), and lets you browse files from Windows Explorer via `\\wsl.localhost\<Distro>\...`.

## Key features

- Automatic ext4 detection (heuristics: *Linux FS GPT GUID / MBR 0x83* **or** *ext4 magic*).
- Mount/Unmount using `wsl --mount` / `wsl --unmount`.
- KeepAlive (`wsl.exe -d <distro> --exec /bin/sleep infinity`) to prevent the mount disappearing after a few seconds.
- **Systray UI**:
  - Mount/Unmount all
  - Per-disk / per-partition dropdown
  - Start/Stop/Restart the **Service (Agent)** (scheduled task)
  - Docs / Logs
  - **Bilingual IT/EN** (Auto/Italian/English)
  - **Colored icon**: Green=mounted, Red=error, White=normal
- Scheduled tasks to avoid UAC prompts on every action.
- Custom icon: replace `C:\ext4win\file.ico`.

## Requirements

- Windows 10/11 with **WSL2**.
- `wsl.exe` must support `--mount` (check `wsl --help`).
- A WSL2 distro installed (default: **Debian**).
- Administrator privileges for mount/unmount.

## Install (single-file installer)

1. Download **Ext4WinInstaller.ps1** (single file).
2. Run PowerShell as Admin:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1
```

Uninstall:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1 -Uninstall
```

## Quick usage

- Plug in a USB disk containing an ext4 partition.
- Right click the **Ext4Win** tray icon:
  - **Mount all** (or pick a specific partition)
  - Open WSL folder

Typical path:
- `\\wsl.localhost\Debian\mnt\wsl\PHYSICALDRIVE1p1\`

## Logs

- `C:\ext4win\logs\Ext4Win.log`
- `C:\ext4win\logs\Ext4WinTray.runtime.log`
- `C:\ext4win\logs\Ext4WinAgent.log`
- `C:\ext4win\run\agent.status.json`

## Configuration

File: `C:\ext4win\config.json`

---

For details:
- `docs/MANUAL.en.md`
- `docs/FAQ.en.md`

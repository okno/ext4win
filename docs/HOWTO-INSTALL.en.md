# HowTo Install (EN)

## Quick install

1. Download `Ext4WinInstaller.ps1`.
2. Open **PowerShell as Administrator**.
3. Run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1
```

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1 -Uninstall
```

## If `wsl --mount` is not available

- Update WSL (Microsoft Store) or Windows.
- Check:
  - `wsl --help` and look for `--mount`.

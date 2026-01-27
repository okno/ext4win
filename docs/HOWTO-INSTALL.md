# HowTo Install (IT)

## Installazione rapida

1. Scarica `Ext4WinInstaller.ps1`.
2. Apri **PowerShell come Amministratore**.
3. Esegui:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1
```

## Disinstallazione

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1 -Uninstall
```

## Se `wsl --mount` non funziona

- Aggiorna WSL (Microsoft Store) oppure Windows.
- Verifica supporto:
  - `wsl --help` e cerca `--mount`.

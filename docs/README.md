# Ext4Win

Ext4Win è un piccolo tool per **Windows 10/11** che ti permette di montare partizioni **ext4** (dischi fisici/USB/VHD) dentro **WSL2** usando `wsl.exe --mount`, mantenere il mount “vivo” (keepalive) e accedere ai file da Esplora file tramite `\\wsl.localhost\<Distro>\...`.

## Funzioni principali

- Rilevamento automatico di partizioni ext4 (euristica: *GPT Linux FS GUID / MBR 0x83* **oppure** *magic ext4*).
- Mount/Unmount via `wsl --mount` / `wsl --unmount`.
- KeepAlive (processo `wsl.exe -d <distro> --exec /bin/sleep infinity`) per evitare che il mount “sparisca” dopo pochi secondi.
- **Systray (tray icon)** con:
  - Monta/Smonta tutte
  - Lista dischi/partizioni (menu a tendina)
  - Start/Stop/Restart del **Servizio (Agent)** (task schedulato)
  - Documentazione / Logs
  - **Doppia lingua IT/EN** (Auto/Italiano/Inglese)
  - **Icona a colori**: Verde=montato, Rosso=errore, Bianco=normale
- Task schedulati per evitare UAC ogni volta (le azioni avvengono “elevate”).
- Icona personalizzabile: sostituisci `C:\ext4win\file.ico`.

## Requisiti

- Windows 10/11 con **WSL2**.
- `wsl.exe` deve supportare `--mount` (verificabile con `wsl --help`).
- Una distro WSL2 installata (default: **Debian**).
- Privilegi amministratore per mount/unmount.

## Installazione (installer singolo file)

1. Scarica **Ext4WinInstaller.ps1** (file singolo).
2. Avvia PowerShell come Admin e lancia:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1
```

Per disinstallare:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Ext4WinInstaller.ps1 -Uninstall
```

> In alternativa trovi “Ext4Win” in Start Menu e/o “App e funzionalità” (se la policy/registro lo consente).

## Uso rapido

- Collega un disco USB con ext4.
- Clic destro sull’icona **Ext4Win** nel tray:
  - **Monta tutte** (oppure seleziona una partizione specifica)
  - Apri la cartella WSL

Percorsi tipici:
- `\\wsl.localhost\Debian\mnt\wsl\PHYSICALDRIVE1p1\`

## Log

- `C:\ext4win\logs\Ext4Win.log`
- `C:\ext4win\logs\Ext4WinTray.runtime.log`
- `C:\ext4win\logs\Ext4WinAgent.log`
- `C:\ext4win\run\agent.status.json`

## Configurazione

File: `C:\ext4win\config.json`

Parametri utili:
- `distro`: nome distro WSL (`wsl -l -v`)
- `offline_before_mount`: in genere `true` (WSL spesso richiede disco OFFLINE lato Windows)
- `auto_open_explorer`: apre Explorer sul mount dopo il mount
- `language`: `auto` / `it` / `en`
- `agent.enabled`: abilita l’agent
- `agent.poll_seconds`: intervallo scansione

---

Per dettagli, vedi:
- `docs/MANUAL.md`
- `docs/FAQ.md`

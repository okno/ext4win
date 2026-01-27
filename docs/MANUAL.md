# Manuale Ext4Win (IT)

## 1) Cos’è Ext4Win

Ext4Win automatizza l’uso di `wsl.exe --mount` per montare dischi **ext4** in WSL2 e renderli accessibili da Windows tramite:

- `\\wsl.localhost\<Distro>\mnt\wsl\PHYSICALDRIVE<n>p<m>\`

Ext4Win non installa driver ext4 su Windows: si appoggia a **WSL2** (kernel Linux) per montare ext4 in modo nativo e sicuro.

## 2) Architettura

- **Ext4WinCore.ps1**  
  Libreria “core”: rilevamento dischi/partizioni, mount/unmount, keepalive, log.
- **Ext4WinCtl.ps1**  
  CLI per test e automazioni.
- **Ext4WinTray.ps1**  
  UI in tray, bilingue IT/EN, mostra stato e comandi.
- **Ext4WinAgent.ps1**  
  “Servizio” (task schedulato) che fa auto-detect e auto-mount.

### Task Scheduler creati

- `Ext4Win_Tray`  
  Avvia `Ext4WinTray.ps1` all’accesso utente, elevato.
- `Ext4Win_Agent`  
  Avvia `Ext4WinAgent.ps1` all’accesso utente, elevato (loop).
- `Ext4Win_MountAll` / `Ext4Win_UnmountAll`  
  Task “on demand” per i collegamenti desktop MONTA/SMONTA.

## 3) Flusso di mount stabile

WSL può staccare il mount se non c’è attività. Ext4Win usa un keepalive:

- Avvia `wsl.exe -d <Distro> --exec /bin/sleep infinity`
- Finché il processo è vivo, il mount resta attivo.

Il PID Windows è salvato in:
- `C:\ext4win\run\keepalive.pid`

## 4) Percorsi e accesso

- Base mountpoint WSL: `/mnt/wsl/PHYSICALDRIVE<n>p<m>`
- Da Windows Explorer:
  - `\\wsl.localhost\Debian\mnt\wsl\PHYSICALDRIVE1p1\`
- Se configuri `explorer_subpath` (es. `data`), Ext4Win aprirà direttamente:
  - `...\PHYSICALDRIVE1p1\data`

## 5) Configurazione (config.json)

Chiavi importanti:

- `distro`: distro WSL target (`wsl -l -v`)
- `offline_before_mount`: `true` consigliato
  - WSL spesso richiede che il disco sia OFFLINE in Windows prima del mount
- `auto_open_explorer`: apre Explorer quando monta
- `language`: `auto` / `it` / `en`
- `agent.poll_seconds`: intervallo loop agent
- `agent.open_explorer_on_new_mount`: true/false

## 6) Troubleshooting rapido

### “Non vede il disco ext4”

- Verifica che Windows lo veda:
  - `Get-Disk`
- Verifica che Ext4Win lo rilevi:
  - `C:\ext4win\Ext4WinCtl.ps1 -Action ListExt4`
- Se il disco è OFFLINE, è normale se è stato montato o tentato mount con `offline_before_mount=true`.

### “Il mount sparisce dopo pochi secondi”

- Keepalive non è partito o è stato terminato:
  - controlla `C:\ext4win\run\keepalive.pid`
  - log: `C:\ext4win\logs\Ext4Win.log`
- Assicurati che l’Agent sia “In esecuzione” (tray → Servizio).

### “UAC ogni volta”

- Usa i link desktop MONTA/SMONTA (lanciano task elevati).
- Oppure usa tray (task elevato).

## 7) Sicurezza / DevSecOps note

- Ext4Win non modifica file di sistema se non:
  - Task Scheduler
  - cartella installazione
  - chiave uninstall (opzionale)
- I comandi WSL sono chiamati con argomenti espliciti (no parsing “pericoloso”).
- Log locali in `C:\ext4win\logs`.


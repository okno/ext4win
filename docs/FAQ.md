# FAQ (IT)

## Perché il disco diventa OFFLINE in Windows?

Per molti scenari WSL richiede che il disco sia OFFLINE lato Windows prima di poterlo attaccare a WSL2 (`wsl --mount`).  
È normale vedere `IsOffline = True` su `Get-Disk` dopo il mount o il tentativo di mount.

Puoi disabilitare questo comportamento in `config.json`:
- `offline_before_mount: false`

> Nota: se lo disabiliti, il mount potrebbe fallire su alcune build.

## Perché serve l’Admin?

`wsl --mount` e `wsl --unmount` sono operazioni che toccano dischi fisici: Windows richiede privilegi amministrativi.

Ext4Win evita UAC ripetuti usando task schedulati “elevati”.

## Posso montare più partizioni?

Sì. Ext4Win gestisce ogni partizione rilevata e monta tutte (o selezionate).

## Ext4Win legge/scrive sul disco?

WSL monta ext4 in modalità standard (lettura/scrittura).  
Se vuoi read-only, puoi estendere la logica aggiungendo `--options ro` al mount.

## Dove sono i log?

`C:\ext4win\logs\`

## L’icona del tray non compare

- Verifica task: `schtasks /Query /TN Ext4Win_Tray /V /FO LIST`
- Avvia manualmente:
  - `powershell -NoProfile -ExecutionPolicy Bypass -STA -File "C:\ext4win\Ext4WinTray.ps1"`


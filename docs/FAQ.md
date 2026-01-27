# Ext4Win – FAQ (Italiano)

## Cos’è Ext4Win?

Ext4Win è un tool open‑source per Windows 10/11 che permette di montare partizioni **ext4** in **lettura/scrittura** tramite **WSL2**, rendendole accessibili da Esplora File via `\\wsl.localhost\\<Distro>\\mnt\\wsl\\...`.

## Perché usare Ext4Win invece di driver a pagamento?

* Nessun driver kernel proprietario
* Nessuna licenza a pagamento
* Usa funzionalità native di Windows (`wsl.exe --mount`)
* Più sicuro e trasparente per ambienti tecnici, IR e forensics

## Requisiti

* Windows 10 2004+ o Windows 11
* WSL2 installato
* Almeno una distribuzione WSL (consigliata Debian)
* Privilegi amministrativi per il mount

## Dove vengono montati i dischi?

I dischi vengono montati in WSL sotto:

```
/mnt/wsl/PHYSICALDRIVE<NUM>p<PART>
```

E sono accessibili da Windows tramite:

```
\\wsl.localhost\\Debian\\mnt\\wsl\\...
```

## Come montare tutte le partizioni ext4

```powershell
C:\ext4win\Ext4WinCtl.ps1 -Action MountAll
```

## Come smontare tutto

```powershell
C:\ext4win\Ext4WinCtl.ps1 -Action UnmountAll
```

## Come avviare la systray

```powershell
schtasks /Run /TN Ext4Win_Tray
```

## Come chiudere la systray

Dal menu dell’icona → **Esci / Exit**

Oppure forzatamente:

```powershell
Get-Process powershell | Where-Object { $_.CommandLine -like "*Ext4WinTray.ps1*" } | Stop-Process -Force
```

## Come avviare o fermare l’Agent (servizio logico)

Avviare:

```powershell
schtasks /Run /TN Ext4Win_Agent
```

Fermare:

```powershell
schtasks /End /TN Ext4Win_Agent
```

## Come riavviare tutto (procedura consigliata)

```powershell
C:\ext4win\Ext4WinCtl.ps1 -Action UnmountAll
wsl --shutdown
schtasks /End /TN Ext4Win_Agent
schtasks /End /TN Ext4Win_Tray
schtasks /Run /TN Ext4Win_Agent
schtasks /Run /TN Ext4Win_Tray
C:\ext4win\Ext4WinCtl.ps1 -Action MountAll
```

## Come verificare lo stato generale

```powershell
C:\ext4win\Ext4WinCtl.ps1 -Action Diag
```

## La partizione appare per pochi secondi e poi sparisce

Quasi sempre è **power management USB**.

Soluzione consigliata:

```powershell
powercfg -setacvalueindex SCHEME_CURRENT SUB_USB USBSELECTSUSPEND 0
powercfg -setdcvalueindex SCHEME_CURRENT SUB_USB USBSELECTSUSPEND 0
powercfg -setactive SCHEME_CURRENT
```

E disabilitare la sospensione dei dischi:

```powershell
powercfg -change -disk-timeout-ac 0
powercfg -change -disk-timeout-dc 0
```

## Ext4Win non vede il disco ext4

Verifica che Windows veda il disco:

```powershell
Get-Disk
```

Se non compare qui, Ext4Win non può montarlo.

## Log utili

```powershell
C:\ext4win\logs\Ext4Win.log
C:\ext4win\logs\Ext4WinTray.runtime.log
C:\ext4win\logs\Ext4WinTray.out.log
```

## Reset totale senza disinstallare

```powershell
C:\ext4win\Ext4WinCtl.ps1 -Action UnmountAll
wsl --unmount
wsl --shutdown
schtasks /End /TN Ext4Win_Agent
schtasks /End /TN Ext4Win_Tray
```

---

Se il problema persiste, apri una issue su GitHub allegando l’output di `-Action Diag` e i log.



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


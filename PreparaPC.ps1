<#
    PreparaPC.ps1 - preparazione standard dei PC Windows 11 da consegnare

    Uso (PowerShell, anche non amministratore: si auto-eleva):
        irm https://TUO-URL/PreparaPC.ps1 | iex

    Per aggiungere una personalizzazione: aggiungi un blocco  Passo 'Nome' { ... }
    nella sezione PASSI. Per disattivarne una: metti  -Attivo $false  in fondo.

    Le impostazioni utente vengono scritte sia sull'utente corrente sia sul
    profilo "Default", cosi' valgono anche per gli account creati dal cliente.
    Log: C:\ProgramData\PreparaPC\
#>

$PreparaPCUrl  = 'https://raw.githubusercontent.com/guidobarsocchini-oss/PC/refs/heads/main/PreparaPC.ps1'   # <-- da cambiare
$PreparaPCFile = $PSCommandPath

& {
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- elevazione
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -or $PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'Rilancio come amministratore in Windows PowerShell...' -ForegroundColor Yellow
    if ($PreparaPCFile) {
        $argomenti = "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PreparaPCFile`""
    } else {
        $argomenti = "-NoProfile -NoExit -ExecutionPolicy Bypass -Command `"[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm '$PreparaPCUrl' | iex`""
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argomenti
    return
}

$ErrorActionPreference = 'Stop'
$logDir = "$env:ProgramData\PreparaPC"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path "$logDir\PreparaPC_$(Get-Date -Format yyyyMMdd_HHmmss).log" | Out-Null } catch {}

if ([Environment]::OSVersion.Version.Build -lt 22000) {
    Write-Warning 'Questo non sembra Windows 11: alcuni passi potrebbero non avere effetto.'
}

# ================================================================ CONFIG
# App Store/Appx da rimuovere (accettano i caratteri jolly *)
$AppDaRimuovere = @(
    'Microsoft.MicrosoftOfficeHub'          # app "Microsoft 365 (Office)"
    'Microsoft.Office.OneNote'
    'Microsoft.OutlookForWindows'           # nuovo Outlook
    'MSTeams', 'MicrosoftTeams'
    'Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider'
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch'
    'Microsoft.GetHelp', 'Microsoft.Getstarted'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.People', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps'
    'Microsoft.Todos', 'Microsoft.PowerAutomateDesktop', 'Clipchamp.Clipchamp'
    'Microsoft.549981C3F5F10'               # Cortana
    'Microsoft.Windows.DevHome'
    'Microsoft.ZuneVideo'                   # Film e TV
    'MicrosoftCorporationII.MicrosoftFamily'
    '7EE7776C.LinkedInforWindows'
    '*SpotifyMusic*', '*Disney*', '*TikTok*', '*Instagram*', '*Facebook*'
    '*CandyCrush*', '*king.com*', '*Netflix*', '*PrimeVideo*'
    # 'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay'   # Xbox / Game Bar
)

# Office Click-to-Run preinstallato dall'OEM (tutte le lingue): regex sul nome
# ATTENZIONE: rimuove anche un Office installato da te. Disattiva il passo se serve.
$OfficeDaRimuovere = '^(Microsoft 365|Microsoft Office|Office 16|Microsoft OneNote)'

# ================================================================ FUNZIONI
$RadiciUtente = @('Registry::HKEY_CURRENT_USER')
$HiveDefault  = $false
$Passi = New-Object System.Collections.Generic.List[object]

function Passo {
    param([string]$Nome, [scriptblock]$Azione, [bool]$Attivo = $true)
    $Passi.Add([pscustomobject]@{ Nome = $Nome; Azione = $Azione; Attivo = $Attivo })
}

function Start-Exe {
    param([string]$Exe, [string]$Argomenti = '')
    $p = Start-Process -FilePath $Exe -ArgumentList $Argomenti -Wait -PassThru -WindowStyle Hidden
    return $p.ExitCode
}

# Scrive un valore di registro (Name '' = valore predefinito della chiave)
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    if ($Name -eq '') { Set-Item -LiteralPath $Path -Value $Value }
    else { New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null }
}

# Scrive un valore utente su HKCU e sul profilo Default
function Set-UserReg {
    param([string]$SubPath, [string]$Name, $Value, [string]$Type = 'DWord')
    foreach ($r in $RadiciUtente) {
        try { Set-Reg "$r\$SubPath" $Name $Value $Type }
        catch { Write-Warning "  $r\$SubPath [$Name]: $($_.Exception.Message)" }
    }
}

function Get-VociDisinstallazione {
    Get-ItemProperty -ErrorAction SilentlyContinue -Path `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.DisplayName -and $_.UninstallString }
}

# Separa "C:\percorso\prog.exe" argomenti  ->  exe, argomenti
function Split-Comando([string]$cmd) {
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$')   { return $Matches[1], $Matches[2] }
    if ($cmd -match '^\s*(.+?\.exe)\s*(.*)$') { return $Matches[1], $Matches[2] }
    return $cmd, ''
}

$KeyAdvanced = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

# ================================================================ PASSI
Passo 'Menu tasto destro classico (stile Windows 10)' {
    Set-UserReg 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' '' 'String'
    # Per i nuovi utenti lo riapplico anche al primo accesso (Software\Classes vive in UsrClass.dat)
    if ($HiveDefault) {
        Set-Reg 'Registry::HKEY_USERS\PrepDefault\Software\Microsoft\Windows\CurrentVersion\RunOnce' `
            'PreparaPC_MenuClassico' 'reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /f' 'String'
    }
}

Passo 'Barra delle applicazioni allineata a sinistra' {
    Set-UserReg $KeyAdvanced 'TaskbarAl' 0
}

Passo 'Nascondi Visualizzazione attivita, Widget, Copilot, Chat' {
    Set-UserReg $KeyAdvanced 'ShowTaskViewButton' 0
    Set-UserReg $KeyAdvanced 'ShowCopilotButton' 0
    Set-UserReg $KeyAdvanced 'TaskbarMn' 0
    Set-UserReg $KeyAdvanced 'TaskbarDa' 0    # sulle build recenti puo' dare "accesso negato": c'e' la policy sotto
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
}

Passo 'Ricerca sulla barra solo come icona' {
    Set-UserReg 'Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1   # 0=nascosta 1=icona 2=casella
}

Passo 'Disattiva "Riprendi" (continua app dal telefono)' {
    Set-UserReg 'Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration' 'IsResumeAllowed' 0
    Set-UserReg 'Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration' 'IsOneDriveResumeAllowed' 0
}

Passo 'Start: niente consigli/suggerimenti, niente app sponsorizzate' {
    Set-UserReg $KeyAdvanced 'Start_IrisRecommendations' 0
    $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($v in 'SilentInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled',
                   'SystemPaneSuggestionsEnabled', 'SubscribedContent-338388Enabled',
                   'SubscribedContent-338389Enabled', 'SubscribedContent-353694Enabled',
                   'SubscribedContent-353696Enabled', 'SoftLandingEnabled') {
        Set-UserReg $cdm $v 0
    }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
}

Passo 'Rimozione app preinstallate (Store/Appx)' {
    $installate  = Get-AppxPackage -AllUsers | Sort-Object PackageFullName -Unique
    $provisioned = Get-AppxProvisionedPackage -Online
    foreach ($pat in $AppDaRimuovere) {
        foreach ($p in ($provisioned | Where-Object { $_.DisplayName -like $pat })) {
            Write-Host "  - provisioned: $($p.DisplayName)"
            try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName | Out-Null }
            catch { Write-Warning "    $($_.Exception.Message)" }
        }
        foreach ($a in ($installate | Where-Object { $_.Name -like $pat -and -not $_.NonRemovable -and -not $_.IsFramework })) {
            Write-Host "  - installata:  $($a.Name)"
            try { Remove-AppxPackage -Package $a.PackageFullName -AllUsers }
            catch { Write-Warning "    $($_.Exception.Message)" }
        }
    }
}

Passo 'Rimozione Microsoft 365 / OneNote preinstallati (Click-to-Run)' {
    $voci = Get-VociDisinstallazione | Where-Object {
        $_.UninstallString -match 'OfficeClickToRun\.exe' -and $_.DisplayName -match $OfficeDaRimuovere }
    if (-not $voci) { Write-Host '  nessuna installazione Office trovata'; return }
    foreach ($v in $voci) {
        Write-Host "  - $($v.DisplayName)  (puo' richiedere qualche minuto)"
        $exe, $arg = Split-Comando $v.UninstallString
        $rc = Start-Exe $exe "$arg DisplayLevel=False"
        if ($rc -ne 0) { Write-Warning "    codice di uscita $rc" }
    }
}

Passo 'Disinstallazione OneDrive' {
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($v in (Get-VociDisinstallazione | Where-Object { $_.DisplayName -match '^Microsoft OneDrive' })) {
        $exe, $arg = Split-Comando $v.UninstallString
        if (Test-Path -LiteralPath $exe) {
            Write-Host "  - $($v.DisplayName)"
            [void](Start-Exe $exe "$arg /silent")
        }
    }
    foreach ($s in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
        if (Test-Path $s) { [void](Start-Exe $s '/uninstall') }
    }
    # niente reinstallazione automatica per i nuovi utenti
    foreach ($r in $RadiciUtente) {
        Remove-ItemProperty -Path "$r\Software\Microsoft\Windows\CurrentVersion\Run" -Name 'OneDriveSetup', 'OneDrive' -ErrorAction SilentlyContinue
    }
    # togli OneDrive dal riquadro di spostamento di Esplora file
    Set-UserReg 'Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' 'System.IsPinnedToNameSpaceTree' 0
}

# ---- esempi pronti, disattivati: metti $true per usarli ----
Passo 'Esplora file apre "Questo PC"' {
    Set-UserReg $KeyAdvanced 'LaunchTo' 1
} -Attivo $false

Passo 'Mostra estensioni dei file' {
    Set-UserReg $KeyAdvanced 'HideFileExt' 0
} -Attivo $false

# ================================================================ ESECUZIONE
$ntuser = "$env:SystemDrive\Users\Default\NTUSER.DAT"
if (Test-Path $ntuser) {
    if ((Start-Exe 'reg.exe' "load HKU\PrepDefault `"$ntuser`"") -eq 0) {
        $RadiciUtente += 'Registry::HKEY_USERS\PrepDefault'
        $HiveDefault = $true
    } else { Write-Warning 'Impossibile caricare il profilo Default: impostazioni solo per l''utente corrente.' }
}

$risultati = New-Object System.Collections.Generic.List[object]
try {
    foreach ($p in $Passi) {
        if (-not $p.Attivo) { $risultati.Add([pscustomobject]@{ Passo = $p.Nome; Esito = 'saltato' }); continue }
        Write-Host "`n>> $($p.Nome)" -ForegroundColor Cyan
        try   { & $p.Azione; $esito = 'OK' }
        catch { $esito = "ERRORE: $($_.Exception.Message)"; Write-Warning $esito }
        $risultati.Add([pscustomobject]@{ Passo = $p.Nome; Esito = $esito })
    }
}
finally {
    if ($HiveDefault) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        foreach ($i in 1..5) {
            if ((Start-Exe 'reg.exe' 'unload HKU\PrepDefault') -eq 0) { break }
            Start-Sleep -Seconds 1
        }
    }
}

Write-Host "`nRiavvio Esplora risorse..." -ForegroundColor Cyan
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }

Write-Host "`n================ RIEPILOGO ================" -ForegroundColor Green
$risultati | Format-Table -AutoSize -Wrap | Out-String | Write-Host
Write-Host "Log in $logDir - consigliato un riavvio del PC." -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
}

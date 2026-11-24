# =============================================================================
#  setup.ps1 - Configuration automatique de Windows Server 2025
#  Lance par l'installation sans intervention (autounattend.xml), puis par une
#  tache planifiee a chaque demarrage (compte SYSTEM) jusqu'a la fin.
#
#  Etapes (C:\Setup\state.txt) :
#    1 = pilotes VirtIO, agent QEMU, IP fixe, RDP, roles AD DS + DNS
#    2 = promotion en controleur de domaine (nouvelle foret) -> redemarrage
#    3 = configuration DNS + compte de service svc-sql
#    4 = SQL Server 2025 Express
#    5 = SSMS 22
#    6 = nettoyage (mots de passe supprimes du disque)
#   99 = termine
#  Journal : C:\Setup\setup.log
# =============================================================================
param([switch]$Register)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Base      = 'C:\Setup'
$StateFile = Join-Path $Base 'state.txt'
$LogFile   = Join-Path $Base 'setup.log'
$TaskName  = 'WS2025-AutoSetup'

function Write-Log([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}
function Get-State { if (Test-Path $StateFile) { [int](Get-Content $StateFile -Raw).Trim() } else { 0 } }
function Set-State([int]$n) { Set-Content -Path $StateFile -Value $n; Write-Log "--- Etape $n ---" }

function Wait-Internet {
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $null = Invoke-WebRequest -Uri 'https://download.microsoft.com' -Method Head -UseBasicParsing -TimeoutSec 10
            return
        } catch { Start-Sleep -Seconds 10 }
    }
    throw "Pas d'acces a Internet apres 10 minutes (passerelle, DNS ou pare-feu ?)."
}

function Get-File([string]$Url, [string]$Out) {
    Wait-Internet
    for ($i = 1; $i -le 3; $i++) {
        try {
            Write-Log "Telechargement : $Url"
            Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing
            return
        } catch {
            Write-Log "Echec du telechargement (essai $i/3) : $($_.Exception.Message)"
            Start-Sleep -Seconds 15
        }
    }
    throw "Impossible de telecharger $Url"
}

function Invoke-Program([string]$File, [string]$Arguments, [int[]]$OkCodes = @(0, 3010)) {
    Write-Log "Execution : $File"
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    if ($OkCodes -notcontains $p.ExitCode) { throw "$File a echoue (code $($p.ExitCode))." }
    if ($p.ExitCode -eq 3010) { $script:NeedReboot = $true }
}

function Get-AccountName([string]$Sid) {
    (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value
}

# -----------------------------------------------------------------------------
#  Enregistrement de la tache planifiee (appele par autounattend.xml)
# -----------------------------------------------------------------------------
if ($Register) {
    if (-not (Test-Path $Base)) { New-Item -ItemType Directory -Path $Base | Out-Null }
    Write-Log 'Enregistrement de la tache planifiee'
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Base\setup.ps1`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 6) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    exit 0
}

$cfg = Get-Content (Join-Path $Base 'config.json') -Raw | ConvertFrom-Json
$NeedReboot = $false

try {
    $state = Get-State
    if ($state -lt 1) { Set-State 1; $state = 1 }

    # =========================================================================
    #  1. Pilotes, reseau, roles
    # =========================================================================
    if ($state -eq 1) {
        # Lecteur VirtIO : celui qui contient le dossier NetKVM
        $virtio = Get-PSDrive -PSProvider FileSystem |
            Where-Object { Test-Path (Join-Path $_.Root 'NetKVM') } |
            Select-Object -First 1
        if ($virtio) {
            Write-Log "ISO VirtIO trouve sur $($virtio.Root)"
            Get-ChildItem -Path $virtio.Root -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '\\2k25\\amd64\\' } |
                ForEach-Object { & pnputil.exe /add-driver $_.FullName /install | Out-Null }
            $ga = Join-Path $virtio.Root 'guest-agent\qemu-ga-x86_64.msi'
            if (Test-Path $ga) { Invoke-Program 'msiexec.exe' "/i `"$ga`" /qn /norestart" }
            Write-Log 'Pilotes VirtIO et agent QEMU installes'
        } else {
            Write-Log 'ATTENTION : ISO VirtIO introuvable, pilotes non installes'
        }

        # Carte reseau active
        $nic = $null
        for ($i = 0; $i -lt 24 -and -not $nic; $i++) {
            $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
            if (-not $nic) { Start-Sleep -Seconds 5 }
        }
        if (-not $nic) { throw 'Aucune carte reseau active (pilote NetKVM ?).' }

        Write-Log "IP fixe $($cfg.Ip)/$($cfg.Prefix) sur $($nic.Name)"
        Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
        Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $cfg.Ip -PrefixLength $cfg.Prefix -DefaultGateway $cfg.Gateway | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $cfg.DnsForwarder

        if ($cfg.EnableRdp) {
            Write-Log 'Activation du Bureau a distance'
            Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
            Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'   # groupe "Bureau a distance", quelle que soit la langue
        }

        Write-Log 'Installation des roles AD DS et DNS'
        Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
        Set-State 2; $state = 2
    }

    # =========================================================================
    #  2. Promotion en controleur de domaine
    # =========================================================================
    if ($state -eq 2) {
        $role = (Get-CimInstance Win32_ComputerSystem).DomainRole
        if ($role -ge 4) {
            Write-Log 'Deja controleur de domaine'
            Set-State 3; $state = 3
        } else {
            Write-Log "Creation de la foret $($cfg.Domain) ($($cfg.Netbios)) - la VM va redemarrer"
            $dsrm = ConvertTo-SecureString $cfg.AdminPassword -AsPlainText -Force
            Import-Module ADDSDeployment
            Install-ADDSForest -DomainName $cfg.Domain -DomainNetbiosName $cfg.Netbios `
                -SafeModeAdministratorPassword $dsrm -InstallDns -Force -NoRebootOnCompletion:$false | Out-Null
            exit 0   # redemarrage automatique, la tache reprend a l'etape 2 puis passe a 3
        }
    }

    # =========================================================================
    #  3. Configuration AD / DNS
    # =========================================================================
    if ($state -eq 3) {
        Write-Log 'Attente des services Active Directory'
        Import-Module ActiveDirectory
        $ready = $false
        for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
            try { $null = Get-ADDomain; $ready = $true } catch { Start-Sleep -Seconds 10 }
        }
        if (-not $ready) { throw 'Active Directory ne repond pas apres 10 minutes.' }

        $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses @('127.0.0.1')
        Set-DnsServerForwarder -IPAddress $cfg.DnsForwarder
        Write-Log "DNS : serveur local, redirecteur $($cfg.DnsForwarder)"

        if ($cfg.InstallSql -and -not (Get-ADUser -Filter "SamAccountName -eq 'svc-sql'")) {
            $pw = ConvertTo-SecureString $cfg.SqlSvcPassword -AsPlainText -Force
            New-ADUser -Name 'svc-sql' -SamAccountName 'svc-sql' -UserPrincipalName "svc-sql@$($cfg.Domain)" `
                -Description 'Compte de service SQL Server' -AccountPassword $pw -Enabled $true `
                -PasswordNeverExpires $true -CannotChangePassword $true
            Write-Log "Compte de service $($cfg.Netbios)\svc-sql cree"
        }
        Set-State 4; $state = 4
    }

    # =========================================================================
    #  4. SQL Server 2025 Express
    # =========================================================================
    if ($state -eq 4) {
        if ($cfg.InstallSql -and -not (Get-Service -Name 'MSSQL$SQLEXPRESS' -ErrorAction SilentlyContinue)) {
            $media = Join-Path $Base 'SQLMedia'
            New-Item -ItemType Directory -Path $media -Force | Out-Null
            $ssei = Join-Path $Base 'SQL2025-SSEI-Expr.exe'
            Get-File $cfg.SqlSseiUrl $ssei

            Write-Log 'Telechargement du media SQL Server Express (Core)'
            Invoke-Program $ssei "/ACTION=Download /MEDIAPATH=`"$media`" /MEDIATYPE=Core /QUIET"
            $pkg = Get-ChildItem -Path $media -Filter 'SQLEXPR*.exe' -Recurse | Select-Object -First 1
            if (-not $pkg) { throw "Media SQL introuvable dans $media apres le telechargement." }

            $extract = Join-Path $media 'extract'
            Invoke-Program $pkg.FullName "/q /x:`"$extract`""
            $setupExe = Join-Path $extract 'setup.exe'
            if (-not (Test-Path $setupExe)) { throw "setup.exe introuvable dans $extract." }

            # Noms localises des groupes (Administrateurs / Admins du domaine)
            $builtinAdmins = Get-AccountName 'S-1-5-32-544'
            $domainAdmins  = Get-AccountName "$((Get-ADDomain).DomainSID.Value)-512"

            $sqlArgs = @(
                '/Q', '/ACTION=Install', '/IACCEPTSQLSERVERLICENSETERMS', '/SUPPRESSPRIVACYSTATEMENTNOTICE',
                '/FEATURES=SQLENGINE', '/INSTANCENAME=SQLEXPRESS',
                "/SQLSVCACCOUNT=`"$($cfg.Netbios)\svc-sql`"", "/SQLSVCPASSWORD=`"$($cfg.SqlSvcPassword)`"",
                '/SQLSVCSTARTUPTYPE=Automatic',
                "/SQLSYSADMINACCOUNTS=`"$builtinAdmins`" `"$domainAdmins`"",
                '/TCPENABLED=1', '/BROWSERSVCSTARTUPTYPE=Automatic', '/UPDATEENABLED=False'
            )
            if ($cfg.SqlMixed) { $sqlArgs += @('/SECURITYMODE=SQL', "/SAPWD=`"$($cfg.SaPassword)`"") }
            if ($pkg.Name -match '_ENU' -and (Get-UICulture).Name -ne 'en-US') { $sqlArgs += '/ENU' }

            Write-Log 'Installation de SQL Server 2025 Express (instance SQLEXPRESS)'
            Invoke-Program $setupExe ($sqlArgs -join ' ')

            # Pare-feu : moteur SQL + SQL Browser (UDP 1434)
            $sqlservr = Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Recurse -Filter 'sqlservr.exe' -ErrorAction SilentlyContinue |
                Where-Object FullName -match 'SQLEXPRESS' | Select-Object -First 1
            if ($sqlservr) {
                New-NetFirewallRule -DisplayName 'SQL Server (SQLEXPRESS)' -Direction Inbound -Program $sqlservr.FullName -Action Allow -Profile Domain,Private | Out-Null
            }
            New-NetFirewallRule -DisplayName 'SQL Server Browser (UDP 1434)' -Direction Inbound -Protocol UDP -LocalPort 1434 -Action Allow -Profile Domain,Private | Out-Null
            Write-Log 'SQL Server installe'
        } else {
            Write-Log 'SQL Server : ignore (non demande ou deja installe)'
        }
        Set-State 5; $state = 5
    }

    # =========================================================================
    #  5. SSMS 22
    # =========================================================================
    if ($state -eq 5) {
        if ($cfg.InstallSsms) {
            $vs = Join-Path $Base 'vs_SSMS.exe'
            Get-File $cfg.SsmsUrl $vs
            Write-Log 'Installation de SSMS 22 (10 a 20 minutes)'
            Invoke-Program $vs '--quiet --wait --norestart --nocache'
            Write-Log 'SSMS installe'
        }
        Set-State 6; $state = 6
    }

    # =========================================================================
    #  6. Nettoyage
    # =========================================================================
    if ($state -eq 6) {
        Write-Log 'Nettoyage : suppression des fichiers contenant des mots de passe'
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        foreach ($f in @("$Base\config.json", 'C:\Windows\Panther\unattend.xml', 'C:\Windows\Panther\Unattend\unattend.xml',
                         'C:\Windows\System32\Sysprep\unattend.xml')) {
            Remove-Item -Path $f -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -Path "$Base\SQLMedia", "$Base\*.exe" -Recurse -Force -ErrorAction SilentlyContinue
        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '0' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue

        Set-Content -Path "$Base\TERMINE.txt" -Value ("Installation terminee le {0}`r`nDomaine : {1}`r`nVoir setup.log" -f (Get-Date), $cfg.Domain)
        Set-State 99
        Write-Log 'Installation terminee'
        if ($NeedReboot) { Restart-Computer -Force }
    }
}
catch {
    Write-Log "ERREUR : $($_.Exception.Message)"
    Write-Log "Ligne : $($_.InvocationInfo.ScriptLineNumber) - $($_.InvocationInfo.Line.Trim())"
    Set-Content -Path "$Base\ERREUR.txt" -Value $_.Exception.Message
    exit 1
}

#!/usr/bin/env bash
# =============================================================================
#  deploy-ws2025.sh — Déploie une VM Windows Server 2025 sur Proxmox VE,
#  100 % automatiquement :
#    - VM optimisée (q35, UEFI, TPM, VirtIO SCSI + réseau VirtIO)
#    - installation Windows sans intervention (autounattend.xml)
#    - pilotes VirtIO + agent QEMU
#    - IP fixe, contrôleur de domaine Active Directory + DNS
#    - SQL Server 2025 Express + SSMS 22 (facultatif)
#
#  À lancer sur l'HÔTE Proxmox, en root :
#    bash deploy-ws2025.sh          -> mode interactif
#    bash deploy-ws2025.sh --yes    -> valeurs par défaut / variables d'env.
#    bash deploy-ws2025.sh --help
#  Auteur : Evan Morboeuf
# =============================================================================
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
REPO_RAW="https://raw.githubusercontent.com/emorboeuf/WS2025-autoinstall/main"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
SQL_SSEI_URL="https://download.microsoft.com/download/7ab8f535-7eb8-4b16-82eb-eca0fa2d38f3/SQL2025-SSEI-Expr.exe"
SSMS_URL="https://aka.ms/ssms/22/release/vs_SSMS.exe"
LOG_FILE="/var/log/deploy-ws2025.log"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /tmp)

# --- Valeurs par défaut (modifiables par variables d'environnement) ---------
VMID="${VMID:-}"
VM_STORAGE="${VM_STORAGE:-local-lvm}"
ISO_STORAGE="${ISO_STORAGE:-local}"
WIN_ISO="${WIN_ISO:-}"
VM_CORES="${VM_CORES:-4}"
VM_RAM="${VM_RAM:-8192}"
VM_DISK="${VM_DISK:-80}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
WIN_INDEX="${WIN_INDEX:-2}"
PRODUCT_KEY="${PRODUCT_KEY:-}"
UI_LANG="${UI_LANG:-fr-FR}"
KEYBOARD="${KEYBOARD:-fr-FR}"
WIN_TZ="${WIN_TZ:-Romance Standard Time}"
HOSTNAME_WIN="${HOSTNAME_WIN:-SRV-AD01}"
ADMIN_PASS="${ADMIN_PASS:-}"
DOMAIN_FQDN="${DOMAIN_FQDN:-lab.lan}"
NETBIOS="${NETBIOS:-}"
IP_CIDR="${IP_CIDR:-}"
GATEWAY="${GATEWAY:-}"
DNS_FWD="${DNS_FWD:-}"
INSTALL_SQL="${INSTALL_SQL:-o}"
SQL_MIXED="${SQL_MIXED:-n}"
INSTALL_SSMS="${INSTALL_SSMS:-o}"
ENABLE_RDP="${ENABLE_RDP:-o}"
FOLLOW="${FOLLOW:-o}"
ASSUME_YES=0
STEP=0
TOTAL_STEPS=5
WORK_DIR=""

# --- Affichage ---------------------------------------------------------------
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1;34m'; W=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; W=""; N=""
fi
info() { echo "${B}[INFO]${N} $*"; }
ok()   { echo "${G}[ OK ]${N} $*"; }
warn() { echo "${Y}[WARN]${N} $*" >&2; }
die()  { echo "${R}[ERREUR]${N} $*" >&2; exit 1; }
step() { STEP=$((STEP + 1)); echo; echo "${B}==> [${STEP}/${TOTAL_STEPS}] $*${N}"; }
run()  { echo "+ $*" >>"$LOG_FILE"; "$@" >>"$LOG_FILE" 2>&1; }

on_error() {
  echo >&2
  echo "${R}[ERREUR]${N} Échec à la ligne $1 : $2" >&2
  [[ -f $LOG_FILE ]] && { echo "${Y}--- fin de ${LOG_FILE} ---${N}" >&2; tail -n 15 "$LOG_FILE" >&2 || true; }
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap '[[ -n $WORK_DIR ]] && rm -rf "$WORK_DIR"' EXIT

usage() {
  cat <<EOF
deploy-ws2025.sh v${SCRIPT_VERSION} — VM Windows Server 2025 + AD + SQL Server + SSMS sur Proxmox.

Usage : bash deploy-ws2025.sh [--yes] [--help]   (en root, sur l'hôte Proxmox)

Prérequis : l'ISO de Windows Server 2025 doit déjà être dans un stockage ISO
de Proxmox (ex. local). L'ISO VirtIO est téléchargé automatiquement s'il manque.

Variables d'environnement utiles en mode --yes :
  WIN_ISO        nom du fichier ISO Windows (ex. ws2025-eval.iso)   [obligatoire]
  ADMIN_PASS     mot de passe Administrateur / DSRM                 [obligatoire]
  IP_CIDR        ex. 192.168.1.10/24                                [obligatoire]
  GATEWAY        ex. 192.168.1.1                                    [obligatoire]
  DNS_FWD        redirecteur DNS (défaut : la passerelle)
  VMID VM_STORAGE ISO_STORAGE VM_CORES VM_RAM VM_DISK VM_BRIDGE
  WIN_INDEX (1 à 4) PRODUCT_KEY UI_LANG KEYBOARD WIN_TZ HOSTNAME_WIN
  DOMAIN_FQDN NETBIOS INSTALL_SQL SQL_MIXED INSTALL_SSMS ENABLE_RDP FOLLOW (o/n)
EOF
}

# --- Questions ---------------------------------------------------------------
has_tty() { [[ $ASSUME_YES -eq 0 ]] && { : </dev/tty; } 2>/dev/null; }

ask() {
  local __var=$1 __q=$2 __def=${3:-} __ans=""
  if has_tty; then read -r -p "  ${__q} [${__def}] : " __ans </dev/tty || true; fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

ask_yn() {
  local __var=$1 __yn
  ask __yn "$2 (o/n)" "$3"
  case "${__yn,,}" in o|oui|y|yes) printf -v "$__var" 'o' ;; *) printf -v "$__var" 'n' ;; esac
}

# Redemande tant que la fonction de validation $3 échoue
ask_valid() {
  local __var=$1 __q=$2 __check=$3 __val
  while true; do
    ask __val "$__q" "${!__var}"
    if "$__check" "$__val"; then printf -v "$__var" '%s' "$__val"; return; fi
    has_tty || die "Valeur invalide pour « ${__q} » : ${__val}"
  done
}

gen_password() {
  # 16 caractères avec majuscule, minuscule, chiffre et symbole (règles Windows)
  local base
  base=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-13)
  echo "${base}Aa9!"
}

# Mot de passe compatible Windows, XML et JSON
password_ok() {
  local p=$1 classes=0
  if [[ ! $p =~ ^[A-Za-z0-9!#%*+,.:=?@_~^-]+$ ]]; then
    warn "Caractères autorisés : lettres, chiffres et ! # % * + , . : = ? @ _ ~ ^ -"
    return 1
  fi
  [[ ${#p} -ge 8 ]] || { warn "8 caractères minimum."; return 1; }
  [[ $p =~ [A-Z] ]] && classes=$((classes + 1))
  [[ $p =~ [a-z] ]] && classes=$((classes + 1))
  [[ $p =~ [0-9] ]] && classes=$((classes + 1))
  [[ $p =~ [^A-Za-z0-9] ]] && classes=$((classes + 1))
  [[ $classes -ge 3 ]] || { warn "Il faut au moins 3 types parmi : majuscules, minuscules, chiffres, symboles."; return 1; }
}

ask_password() { # ask_password VARIABLE "libellé"
  local __var=$1 __label=$2 p1 p2
  if [[ -n ${!__var} ]]; then password_ok "${!__var}" || die "Mot de passe ${__label} refusé."; return; fi
  if ! has_tty; then die "En mode --yes, fournis ADMIN_PASS."; fi
  while true; do
    read -r -s -p "  Mot de passe ${__label} (Entrée = généré) : " p1 </dev/tty || true; echo >&2
    if [[ -z $p1 ]]; then p1=$(gen_password); printf -v "$__var" '%s' "$p1"; GENERATED_PASS=1; return; fi
    password_ok "$p1" || continue
    read -r -s -p "  Confirmer : " p2 </dev/tty || true; echo >&2
    [[ $p1 == "$p2" ]] && { printf -v "$__var" '%s' "$p1"; return; }
    warn "Les mots de passe ne correspondent pas."
  done
}

# --- Validations ---------------------------------------------------------------
is_int()      { [[ $1 =~ ^[0-9]+$ ]] || { warn "Nombre attendu."; return 1; }; }
is_vmid()     { is_int "$1" || return 1; [[ $1 -ge 100 ]] || { warn "VMID >= 100."; return 1; }
                if qm status "$1" >/dev/null 2>&1; then warn "Le VMID $1 est déjà utilisé."; return 1; fi; }
is_hostname() { [[ $1 =~ ^[A-Za-z][A-Za-z0-9-]{0,14}$ ]] || { warn "Nom Windows : 15 caractères max, lettres/chiffres/-."; return 1; }; }
is_fqdn()     { [[ $1 =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]] || { warn "Domaine attendu, ex. lab.lan"; return 1; }; }
is_netbios()  { [[ $1 =~ ^[A-Z0-9-]{1,15}$ ]] || { warn "NetBIOS : 15 caractères max, MAJUSCULES/chiffres/-."; return 1; }; }
is_ip()       { local IFS=. o; [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "Adresse IP attendue."; return 1; }
                for o in $1; do [[ $o -le 255 ]] || { warn "Adresse IP invalide."; return 1; }; done; }
is_cidr()     { [[ $1 == */* ]] || { warn "Format attendu : 192.168.1.10/24"; return 1; }
                is_ip "${1%/*}" || return 1; local p=${1#*/}; is_int "$p" && [[ $p -ge 8 && $p -le 30 ]] || { warn "Masque /8 à /30."; return 1; }; }
is_index()    { [[ $1 =~ ^[1-4]$ ]] || { warn "Choisis 1, 2, 3 ou 4."; return 1; }; }
is_lang()     { [[ $1 =~ ^[a-z]{2}-[A-Z]{2}$ ]] || { warn "Format attendu : fr-FR, en-US…"; return 1; }; }
is_key()      { [[ -z $1 || $1 =~ ^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$ ]] || { warn "Clé au format XXXXX-XXXXX-XXXXX-XXXXX-XXXXX (ou vide)."; return 1; }; }
is_storage()  { pvesm status --storage "$1" >/dev/null 2>&1 || { warn "Stockage $1 introuvable (voir : pvesm status)."; return 1; }; }
is_bridge()   { [[ -d /sys/class/net/$1/bridge ]] || { warn "Pont réseau $1 introuvable."; return 1; }; }

# --- Arguments -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Option inconnue : $1 (voir --help)" ;;
  esac
  shift
done
GENERATED_PASS=0

# =============================================================================
#  Vérifications
# =============================================================================
echo "${W}"
echo "  ╔════════════════════════════════════════════════════╗"
echo "  ║  Windows Server 2025 + AD + SQL — Proxmox — v${SCRIPT_VERSION} ║"
echo "  ╚════════════════════════════════════════════════════╝${N}"

[[ $EUID -eq 0 ]] || die "Lance ce script en root sur l'hôte Proxmox."
command -v qm >/dev/null 2>&1 && command -v pvesm >/dev/null 2>&1 \
  || die "Commandes qm/pvesm absentes : ce script se lance sur l'hôte Proxmox VE, pas dans une VM."
: >"$LOG_FILE"; chmod 600 "$LOG_FILE"

if ! command -v genisoimage >/dev/null 2>&1 && ! command -v xorriso >/dev/null 2>&1; then
  info "Installation de genisoimage (création de l'ISO de réponse)…"
  run apt-get update
  run apt-get install -y genisoimage
fi

# =============================================================================
#  Questions
# =============================================================================
echo
echo "${W}1) Machine virtuelle${N} (Entrée = valeur proposée)"
[[ -n $VMID ]] || VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
ask_valid VMID "VMID" is_vmid
ask_valid VM_STORAGE "Stockage du disque de la VM" is_storage
ask_valid ISO_STORAGE "Stockage des ISO" is_storage

mapfile -t ISO_LIST < <(pvesm list "$ISO_STORAGE" --content iso 2>/dev/null \
  | awk 'NR>1 {print $1}' | sed 's#^.*iso/##' | grep -vi -e '^virtio' -e '^ws2025-answer' || true)
[[ ${#ISO_LIST[@]} -gt 0 ]] || die "Aucun ISO Windows dans le stockage ${ISO_STORAGE}. Envoie d'abord l'ISO de Windows Server 2025 (Proxmox > ${ISO_STORAGE} > ISO Images > Upload)."
if [[ -z $WIN_ISO ]]; then
  WIN_ISO=${ISO_LIST[0]}
  for f in "${ISO_LIST[@]}"; do [[ ${f,,} == *2025* || ${f,,} == *26100* ]] && { WIN_ISO=$f; break; }; done
fi
echo "  ISO disponibles :"
for i in "${!ISO_LIST[@]}"; do echo "    $((i + 1))) ${ISO_LIST[$i]}"; done
while true; do
  ask choice "ISO de Windows Server 2025 (numéro ou nom)" "$WIN_ISO"
  if [[ $choice =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#ISO_LIST[@]} ]]; then WIN_ISO=${ISO_LIST[$((choice - 1))]}; break; fi
  if printf '%s\n' "${ISO_LIST[@]}" | grep -qxF "$choice"; then WIN_ISO=$choice; break; fi
  warn "ISO introuvable : ${choice}"; has_tty || die "ISO Windows introuvable : ${choice}"
done

ask_valid VM_CORES "Nombre de cœurs" is_int
ask_valid VM_RAM "Mémoire (Mo) — 8192 conseillé avec SQL Server" is_int
ask_valid VM_DISK "Taille du disque (Go)" is_int
ask_valid VM_BRIDGE "Pont réseau" is_bridge

echo
echo "${W}2) Windows${N}"
echo "  Édition : 1) Standard Core  2) Standard (Bureau)  3) Datacenter Core  4) Datacenter (Bureau)"
ask_valid WIN_INDEX "Édition" is_index
ask_valid PRODUCT_KEY "Clé produit (vide pour un ISO d'évaluation)" is_key
ask_valid UI_LANG "Langue de l'ISO Windows" is_lang
ask_valid KEYBOARD "Langue du clavier et format régional" is_lang
ask WIN_TZ "Fuseau horaire Windows" "$WIN_TZ"
ask_valid HOSTNAME_WIN "Nom de la machine" is_hostname
HOSTNAME_WIN=${HOSTNAME_WIN^^}
ask_password ADMIN_PASS "Administrateur (sert aussi de mot de passe DSRM)"

echo
echo "${W}3) Active Directory et réseau${N}"
ask_valid DOMAIN_FQDN "Nom du domaine" is_fqdn
DOMAIN_FQDN=${DOMAIN_FQDN,,}
[[ -n $NETBIOS ]] || NETBIOS=$(echo "${DOMAIN_FQDN%%.*}" | tr '[:lower:]' '[:upper:]' | cut -c1-15)
ask_valid NETBIOS "Nom NetBIOS du domaine" is_netbios
ask_valid IP_CIDR "IP fixe du serveur avec masque" is_cidr
[[ -n $GATEWAY ]] || GATEWAY="${IP_CIDR%.*}.1"
ask_valid GATEWAY "Passerelle" is_ip
[[ -n $DNS_FWD ]] || DNS_FWD=$GATEWAY
ask_valid DNS_FWD "Redirecteur DNS (pour Internet)" is_ip
ask_yn ENABLE_RDP "Activer le Bureau à distance (RDP) ?" "$ENABLE_RDP"

echo
echo "${W}4) SQL Server${N}"
ask_yn INSTALL_SQL "Installer SQL Server 2025 Express ?" "$INSTALL_SQL"
if [[ $INSTALL_SQL == "o" ]]; then
  ask_yn SQL_MIXED "Activer aussi l'authentification SQL (compte sa) ?" "$SQL_MIXED"
else
  SQL_MIXED="n"
fi
ask_yn INSTALL_SSMS "Installer SSMS 22 ?" "$INSTALL_SSMS"

SQL_SVC_PASS=$(gen_password)
SA_PASS=""; [[ $SQL_MIXED == "o" ]] && SA_PASS=$(gen_password)
case ${UI_LANG,,} in
  fr-*) ADMIN_USER="Administrateur" ;;
  es-*) ADMIN_USER="Administrador" ;;
  pt-*) ADMIN_USER="Administrador" ;;
  *)    ADMIN_USER="Administrator" ;;
esac
EDITIONS=("" "Standard Core" "Standard (Bureau)" "Datacenter Core" "Datacenter (Bureau)")

# --- Récapitulatif ---------------------------------------------------------------
echo
echo "${W}Récapitulatif${N}"
echo "  VM .............. ${VMID} — ${VM_CORES} cœurs, ${VM_RAM} Mo, ${VM_DISK} Go sur ${VM_STORAGE}, pont ${VM_BRIDGE}"
echo "  ISO ............. ${WIN_ISO} — édition ${EDITIONS[$WIN_INDEX]} — langue ${UI_LANG}, clavier ${KEYBOARD}"
echo "  Machine ......... ${HOSTNAME_WIN} — compte ${ADMIN_USER}"
echo "  Domaine ......... ${DOMAIN_FQDN} (${NETBIOS})"
echo "  Réseau .......... ${IP_CIDR} — passerelle ${GATEWAY} — redirecteur DNS ${DNS_FWD}"
echo "  SQL Server ...... ${INSTALL_SQL} (auth. SQL : ${SQL_MIXED}) — SSMS : ${INSTALL_SSMS} — RDP : ${ENABLE_RDP}"
echo
ask_yn CONFIRM "Créer la VM et lancer l'installation ?" "o"
[[ $CONFIRM == "o" ]] || die "Annulé : rien n'a été créé."

# =============================================================================
#  1. ISO VirtIO
# =============================================================================
step "Pilotes VirtIO…"
VIRTIO_ISO=$(pvesm list "$ISO_STORAGE" --content iso 2>/dev/null | awk 'NR>1 {print $1}' \
  | sed 's#^.*iso/##' | grep -i '^virtio-win.*\.iso$' | sort -V | tail -n1 || true)
if [[ -z $VIRTIO_ISO ]]; then
  VIRTIO_ISO="virtio-win.iso"
  VIRTIO_PATH=$(pvesm path "${ISO_STORAGE}:iso/${VIRTIO_ISO}")
  info "Téléchargement de virtio-win.iso (≈ 700 Mo)…"
  run curl -fL --retry 3 -o "${VIRTIO_PATH}.part" "$VIRTIO_URL"
  mv "${VIRTIO_PATH}.part" "$VIRTIO_PATH"
fi
ok "ISO VirtIO : ${VIRTIO_ISO}"

# =============================================================================
#  2. ISO de réponse (autounattend.xml + scripts)
# =============================================================================
step "Génération de l'ISO de réponse…"
WORK_DIR=$(mktemp -d)
mkdir -p "${WORK_DIR}/iso/setup"

if [[ -f ${SCRIPT_DIR}/windows/setup.ps1 ]]; then
  cp "${SCRIPT_DIR}/windows/setup.ps1" "${WORK_DIR}/iso/setup/setup.ps1"
else
  run curl -fsSL -o "${WORK_DIR}/iso/setup/setup.ps1" "${REPO_RAW}/windows/setup.ps1"
fi

PREFIX=${IP_CIDR#*/}
cat >"${WORK_DIR}/iso/setup/config.json" <<JSON
{
  "Hostname": "${HOSTNAME_WIN}",
  "AdminUser": "${ADMIN_USER}",
  "AdminPassword": "${ADMIN_PASS}",
  "Domain": "${DOMAIN_FQDN}",
  "Netbios": "${NETBIOS}",
  "Ip": "${IP_CIDR%/*}",
  "Prefix": ${PREFIX},
  "Gateway": "${GATEWAY}",
  "DnsForwarder": "${DNS_FWD}",
  "EnableRdp": $([[ $ENABLE_RDP == "o" ]] && echo true || echo false),
  "InstallSql": $([[ $INSTALL_SQL == "o" ]] && echo true || echo false),
  "SqlMixed": $([[ $SQL_MIXED == "o" ]] && echo true || echo false),
  "SqlSvcPassword": "${SQL_SVC_PASS}",
  "SaPassword": "${SA_PASS}",
  "SqlSseiUrl": "${SQL_SSEI_URL}",
  "InstallSsms": $([[ $INSTALL_SSMS == "o" ]] && echo true || echo false),
  "SsmsUrl": "${SSMS_URL}"
}
JSON

# Pilotes chargés pendant l'installation (le lecteur VirtIO peut avoir n'importe quelle lettre)
DRIVER_PATHS=""
k=1
for letter in D E F G H I J; do
  for drv in vioscsi NetKVM; do
    DRIVER_PATHS+="        <PathAndCredentials wcm:action=\"add\" wcm:keyValue=\"${k}\"><Path>${letter}:\\${drv}\\2k25\\amd64</Path></PathAndCredentials>"$'\n'
    k=$((k + 1))
  done
done

PRODUCT_KEY_XML=""
if [[ -n $PRODUCT_KEY ]]; then
  PRODUCT_KEY_XML="<ProductKey><Key>${PRODUCT_KEY}</Key><WillShowUI>OnError</WillShowUI></ProductKey>"
fi

COPY_CMD='cmd /c "for %d in (D E F G H I J) do @if exist %d:\setup\setup.ps1 xcopy /e /i /y %d:\setup C:\Setup"'
RUN_CMD='powershell -NoProfile -ExecutionPolicy Bypass -File C:\Setup\setup.ps1 -Register'
NS='xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
CMP='processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'

cat >"${WORK_DIR}/iso/autounattend.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<!-- Généré par deploy-ws2025.sh -->
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" ${CMP} ${NS}>
      <SetupUILanguage><UILanguage>${UI_LANG}</UILanguage></SetupUILanguage>
      <InputLocale>${KEYBOARD}</InputLocale>
      <SystemLocale>${KEYBOARD}</SystemLocale>
      <UILanguage>${UI_LANG}</UILanguage>
      <UserLocale>${KEYBOARD}</UserLocale>
    </component>
    <component name="Microsoft-Windows-PnpCustomizationsWinPE" ${CMP} ${NS}>
      <DriverPaths>
${DRIVER_PATHS}      </DriverPaths>
    </component>
    <component name="Microsoft-Windows-Setup" ${CMP} ${NS}>
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>${WIN_INDEX}</Value></MetaData></InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Administrateur</FullName>
        <Organization>${NETBIOS}</Organization>
        ${PRODUCT_KEY_XML}
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" ${CMP} ${NS}>
      <ComputerName>${HOSTNAME_WIN}</ComputerName>
      <TimeZone>${WIN_TZ}</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" ${CMP} ${NS}>
      <InputLocale>${KEYBOARD}</InputLocale>
      <SystemLocale>${KEYBOARD}</SystemLocale>
      <UILanguage>${UI_LANG}</UILanguage>
      <UserLocale>${KEYBOARD}</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" ${CMP} ${NS}>
      <UserAccounts>
        <AdministratorPassword><Value>${ADMIN_PASS}</Value><PlainText>true</PlainText></AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>${ADMIN_USER}</Username>
        <Password><Value>${ADMIN_PASS}</Value><PlainText>true</PlainText></Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>${COPY_CMD}</CommandLine><Description>Copie des scripts</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>${RUN_CMD}</CommandLine><Description>Lancement de la configuration</Description></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XML

ANSWER_ISO="ws2025-answer-${VMID}.iso"
ANSWER_PATH=$(pvesm path "${ISO_STORAGE}:iso/${ANSWER_ISO}")
if command -v genisoimage >/dev/null 2>&1; then
  run genisoimage -quiet -J -r -V WSANSWER -o "$ANSWER_PATH" "${WORK_DIR}/iso"
else
  run xorriso -as mkisofs -quiet -J -r -V WSANSWER -o "$ANSWER_PATH" "${WORK_DIR}/iso"
fi
chmod 600 "$ANSWER_PATH"
ok "ISO de réponse : ${ANSWER_ISO} (supprimé automatiquement à la fin)"

# =============================================================================
#  3. Création de la VM
# =============================================================================
step "Création de la VM ${VMID}…"
run qm create "$VMID" \
  --name "${HOSTNAME_WIN,,}" \
  --ostype win11 \
  --machine q35 \
  --bios ovmf \
  --efidisk0 "${VM_STORAGE}:1,efitype=4m,pre-enrolled-keys=1" \
  --tpmstate0 "${VM_STORAGE}:1,version=v2.0" \
  --cpu host \
  --cores "$VM_CORES" \
  --memory "$VM_RAM" \
  --scsihw virtio-scsi-single \
  --scsi0 "${VM_STORAGE}:${VM_DISK},iothread=1,discard=on,ssd=1" \
  --net0 "virtio,bridge=${VM_BRIDGE}" \
  --ide2 "${ISO_STORAGE}:iso/${WIN_ISO},media=cdrom" \
  --sata0 "${ISO_STORAGE}:iso/${VIRTIO_ISO},media=cdrom" \
  --sata1 "${ISO_STORAGE}:iso/${ANSWER_ISO},media=cdrom" \
  --boot "order=scsi0;ide2" \
  --agent enabled=1 \
  --tablet 1
ok "VM ${VMID} créée."

# =============================================================================
#  4. Démarrage
# =============================================================================
step "Démarrage de la VM et lancement de l'installation…"
run qm start "$VMID"
# L'ISO Windows affiche « Press any key to boot from CD » : on appuie à sa place.
for _ in $(seq 1 25); do qm sendkey "$VMID" ret >/dev/null 2>&1 || true; sleep 1; done
ok "Installation de Windows lancée (console : Proxmox > VM ${VMID} > Console)."

# =============================================================================
#  5. Suivi
# =============================================================================
step "Suivi de l'installation…"
PHASES=("Installation de Windows" "Pilotes, réseau et rôles AD" "Promotion en contrôleur de domaine" \
        "Configuration AD et DNS" "SQL Server 2025 Express" "SSMS 22" "Nettoyage")

guest_cat() { # lit un fichier dans la VM via l'agent QEMU
  qm guest exec "$VMID" --timeout 20 -- cmd /c "type $1" 2>/dev/null \
    | sed -n 's/.*"out-data"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | sed 's/\\r//g; s/\\n/ /g' | tr -d ' '
}

cleanup_isos() {
  qm set "$VMID" --delete sata0,sata1 >>"$LOG_FILE" 2>&1 || true
  qm set "$VMID" --ide2 none,media=cdrom >>"$LOG_FILE" 2>&1 || true
  rm -f "$ANSWER_PATH"
}

RESULT="suivi"
if [[ $FOLLOW == "o" ]]; then
  info "Ça prend en général 30 à 60 minutes. Ctrl+C arrête seulement le suivi, pas l'installation."
  last=""; start=$(date +%s)
  while true; do
    state=$(guest_cat 'C:\Setup\state.txt' || true)
    if [[ $state =~ ^[0-9]+$ ]]; then
      if [[ $state -ge 99 ]]; then RESULT="ok"; break; fi
      label=${PHASES[$state]:-"Étape ${state}"}
    else
      label=${last:-${PHASES[0]}}   # VM en cours de redémarrage : on garde l'étape affichée
    fi
    if [[ -n $(guest_cat 'C:\Setup\ERREUR.txt' || true) ]]; then RESULT="erreur"; break; fi
    if [[ $label != "$last" ]]; then
      echo "  $(date '+%H:%M') — ${label}…"; last=$label
    fi
    if (( $(date +%s) - start > 7200 )); then RESULT="timeout"; break; fi
    sleep 30
  done
fi

echo
case $RESULT in
  ok)
    cleanup_isos
    echo "${G}══════════════════════════════════════════════════════${N}"
    echo "${G}  ${HOSTNAME_WIN}.${DOMAIN_FQDN} est prêt !${N}"
    echo "${G}══════════════════════════════════════════════════════${N}" ;;
  erreur)
    warn "L'installation s'est arrêtée sur une erreur. Journal dans la VM : C:\\Setup\\setup.log"
    warn "L'ISO de réponse (qui contient les mots de passe) est conservé pour pouvoir relancer : ${ANSWER_PATH}" ;;
  timeout)
    warn "Pas terminé après 2 h. Regarde la console de la VM et C:\\Setup\\setup.log." ;;
  *)
    info "Suivi désactivé. Quand C:\\Setup\\TERMINE.txt existe dans la VM, retire les ISO et supprime ${ANSWER_PATH}." ;;
esac

echo "  Connexion ........ ${NETBIOS}\\${ADMIN_USER}"
[[ $GENERATED_PASS -eq 1 ]] && echo "  Mot de passe ..... ${W}${ADMIN_PASS}${N}  (généré — note-le !)"
echo "  IP ............... ${IP_CIDR%/*}"
if [[ $INSTALL_SQL == "o" ]]; then
  echo "  SQL Server ....... ${HOSTNAME_WIN}\\SQLEXPRESS (service : ${NETBIOS}\\svc-sql)"
  echo "  Mot de passe svc-sql : ${SQL_SVC_PASS}"
  [[ $SQL_MIXED == "o" ]] && echo "  Mot de passe sa .. ${SA_PASS}"
fi
echo

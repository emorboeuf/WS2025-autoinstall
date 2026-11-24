# WS2025-autoinstall

Déploie sur **Proxmox VE** une VM **Windows Server 2025** entièrement configurée, sans aucun clic :

- VM optimisée : q35, UEFI + Secure Boot, TPM 2.0, disque VirtIO SCSI, carte réseau VirtIO, agent QEMU
- installation propre de Windows à partir de ton ISO, avec les pilotes de **virtio-win.iso** chargés pendant l'installation
- IP fixe, Bureau à distance
- **contrôleur de domaine Active Directory** (nouvelle forêt) avec DNS
- **SQL Server 2025 Express** (instance `SQLEXPRESS`) et **SSMS 22** (facultatifs)

## Prérequis

- Un hôte Proxmox VE 8 ou 9 avec accès à Internet
- L'**ISO de Windows Server 2025** déposé dans un stockage ISO (Proxmox > `local` > *ISO Images* > *Upload*).
  L'ISO d'évaluation de Microsoft (180 jours) convient très bien.
- `virtio-win.iso` : s'il manque, le script le télécharge tout seul

## Utilisation

Dans le shell de l'hôte Proxmox (en root) :

```bash
wget https://raw.githubusercontent.com/emorboeuf/WS2025-autoinstall/main/deploy-ws2025.sh
bash deploy-ws2025.sh
```

Le script pose ses questions (avec des valeurs proposées par défaut), affiche un récapitulatif, crée la VM puis suit l'installation jusqu'au bout. Compte **30 à 60 minutes**.

## Questions posées

| Rubrique | Questions |
|---|---|
| VM | VMID, stockage, ISO Windows, cœurs, RAM, disque, pont réseau |
| Windows | édition (Standard/Datacenter, Core/Bureau), clé produit (vide = évaluation), langue de l'ISO, clavier, fuseau, nom de la machine, mot de passe Administrateur |
| AD / réseau | nom du domaine, nom NetBIOS, IP fixe, passerelle, redirecteur DNS, RDP |
| SQL | SQL Server Express, authentification SQL (`sa`), SSMS |

## Ce qui se passe dans la VM

| Étape | Contenu |
|---|---|
| 0 | Installation de Windows (autounattend.xml) |
| 1 | Pilotes VirtIO + agent QEMU, IP fixe, RDP, rôles AD DS et DNS |
| 2 | Promotion en contrôleur de domaine → redémarrage |
| 3 | DNS local + redirecteur, compte de service `svc-sql` |
| 4 | SQL Server 2025 Express, compte `svc-sql`, pare-feu |
| 5 | SSMS 22 |
| 6 | Nettoyage : les fichiers contenant des mots de passe sont supprimés |

Le journal se trouve dans la VM : `C:\Setup\setup.log`. Quand tout est fini, le script retire les ISO de la VM et supprime l'ISO de réponse (il contient les mots de passe).

## Mode automatique

```bash
WIN_ISO=SERVER_EVAL_2025_fr-fr.iso ADMIN_PASS='MonMotDePasse1!' \
IP_CIDR=192.168.1.10/24 GATEWAY=192.168.1.1 DOMAIN_FQDN=lab.lan \
bash deploy-ws2025.sh --yes
```

Toutes les variables : `bash deploy-ws2025.sh --help`.

## À savoir

- **SQL Server sur un contrôleur de domaine** : Microsoft le déconseille pour la sécurité. Ça reste acceptable pour un labo ou un projet de cours. C'est pour ça que SQL est installé *après* la promotion, avec un compte de domaine (`svc-sql`) : les comptes virtuels ne sont pas pris en charge sur un DC.
- **Langue de l'ISO** : elle doit correspondre à la question « Langue de l'ISO » (`fr-FR` pour un ISO français, `en-US` pour un ISO anglais). Sinon l'installation s'arrête dès le début.
- Les **mots de passe** autorisent lettres, chiffres et `! # % * + , . : = ? @ _ ~ ^ -`. Il faut au moins 3 types de caractères (règle Windows).
- **Windows Update** n'est pas lancé : fais-le à la main après l'installation.

## Dépannage

| Problème | Piste |
|---|---|
| La VM reste sur « Press any key to boot from CD » | dans la console Proxmox, appuie sur Entrée pendant l'affichage |
| L'installation demande la langue ou le disque | la langue de l'ISO ne correspond pas à `UI_LANG`, ou le disque n'est pas détecté (pilote vioscsi) |
| Erreur pendant la configuration | `C:\Setup\setup.log` dans la VM. Au redémarrage suivant, le script reprend là où il s'est arrêté |
| SQL ne s'installe pas | vérifier l'accès Internet de la VM (passerelle, redirecteur DNS) |

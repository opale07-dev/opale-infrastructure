# Opale Vault Backend — Procédure de Démarrage

> **Cible** : VM Infomaniak OpenStack avec vTPM 2.0  
> **OS** : Ubuntu 26.04 LTS  
> **Produit** : Opale Vault (PROJECT-004)  
> **Mode** : TPM v2 — pas de passphrase dans `.env`

---

## Architecture

```
Infomaniak OpenStack — Ubuntu 26.04
┌──────────────────────────────────────────┐
│ /opt/opale-vault/                        │
│   ├── .env           ← VAULT_UNSEAL_MODE=tpm
│   ├── deploy.env     ← GITHUB_DEPLOY_USER, GITHUB_DEPLOY_PAT
│   ├── docker-compose.prod.yml
│   └── Caddyfile
│                                          │
│ docker compose :                         │
│   vault (:3000, non exposé)              │
│     └── /dev/tpmrm0:/dev/tpmrm0          │
│     └── /data → secrets chiffrés         │
│   proxy (caddy:2-alpine, :8443)          │
│     └── TLS internal → vault:3000        │
└──────────────────────────────────────────┘
         ▲
         │ port 8443 (restreint à l'IP Oracle)
         │
Oracle VPS (144.24.253.255)
│ Caddy public → frontend → proxy /api/* →
```

---

## Prérequis

- **Terraform** ≥ 1.5.0 en local
- **OpenStack credentials** (variables d'environnement OpenRC)
- **Clé SSH** publique pour l'accès admin
- **GitHub PAT** avec scope `read:packages` (pour pull GHCR)
- **Pubkey Solana Base58** du wallet admin (pour `VAULT_ADMIN_PUBKEYS`)
- **IP publique** de l'Oracle VPS (pour `vault_allowed_cidr`)

---

## Étape 1 — Provisionner la VM (Terraform)

```bash
cd ~/Dev/ProjetsPerso/OpaleInfrastructure/opale-infrastructure/infra-vault

# Initialiser Terraform avec le backend S3 Infomaniak
terraform init \
  -backend-config="endpoint=https://s3.pub2.infomaniak.cloud" \
  -backend-config="skip_requesting_account_id=true" \
  -backend-config="skip_credentials_validation=true" \
  -backend-config="skip_region_validation=true" \
  -backend-config="skip_metadata_api_check=true" \
  -backend-config="skip_s3_checksum=true" \
  -backend-config="force_path_style=true"

# Planifier
terraform plan \
  -var="ssh_public_key=${SSH_PUBLIC_KEY}" \
  -var="admin_cidr=<TON_IP>/32" \
  -var="vault_allowed_cidr=<IP_ORACLE_VPS>/32"

# Appliquer — la VM est créée avec vTPM activé
terraform apply \
  -var="ssh_public_key=${SSH_PUBLIC_KEY}" \
  -var="admin_cidr=<TON_IP>/32" \
  -var="vault_allowed_cidr=<IP_ORACLE_VPS>/32"
```

### Ce que Terraform provisionne

| Ressource | Détail |
|-----------|--------|
| VM | Ubuntu 26.04 LTS, `a1-ram2-disk20-perf1` (1vCPU/2GB/20GB) |
| vTPM | `hw_tpm_version=2.0`, modèle `tpm-tis` |
| SSH | Port 2222, restreint à `admin_cidr` |
| Vault API | Port 8443, restreint à `vault_allowed_cidr` (Oracle) |
| Bootstrap | Port 22 temporaire pour le hardening initial |
| State | Stocké dans le bucket S3 `opale-core-tfstate` |

> **Après `terraform apply`**, noter l'IP publique affichée dans `outputs.instance_ip`.

---

## Étape 2 — Hardening initial

```bash
VM_IP=<IP de la VM>
SSH="ssh -i ~/Dev/ProjetsPerso/.key/ssh-key-2026-05-09.key -p 22 ubuntu@${VM_IP}"

# Copier le script de hardening Ubuntu
scp -P 22 -i ~/Dev/ProjetsPerso/.key/ssh-key-2026-05-09.key \
  ~/Dev/ProjetsPerso/OpaleInfrastructure/opale-infrastructure/scripts/harden-ubuntu-vps.sh \
  ubuntu@${VM_IP}:/tmp/

# Exécuter le hardening
$SSH "sudo bash /tmp/harden-ubuntu-vps.sh \
  --ssh-port 2222 \
  --app-port 8443 \
  --app-dir /opt/opale-vault \
  --admin-user ubuntu"
```

### Ce que le hardening fait

| Étape | Action |
|-------|--------|
| Updates | `apt-get update && upgrade` |
| Packages | auditd, ca-certificates, curl, docker.io, fail2ban, jq, openssh-server, ufw, unattended-upgrades |
| SSH | Port 2222, PermitRootLogin no, PasswordAuth no, no agent/tcp forwarding |
| Firewall | UFW : DROP par défaut, ACCEPT 2222 + 8443 uniquement |
| Fail2ban | Bantime 2h, maxretry 3 sur SSH, backend systemd |
| Sysctl | Anti-spoofing, TCP syncookies, no ICMP broadcast, fs.suid_dumpable=0 |
| Auditd | Surveille /etc/passwd, /etc/shadow, /etc/docker/daemon.json, `deploy.env` |
| Docker | icc=false, log rotation 10MB×3, live-restore, `ubuntu` ajouté au groupe docker |
| App dir | `/opt/opale-vault/` (chmod 750), `data/` (chmod 700) |
| Auto-updates | `unattended-upgrades` activé pour les patches de sécurité |

> ⚠️ Après le hardening, le port SSH passe de 22 à **2222**. Mettre à jour la variable `SSH`.

```bash
# Vérifier que le SSH sur le nouveau port fonctionne
SSH="ssh -i ~/Dev/ProjetsPerso/.key/ssh-key-2026-05-09.key -p 2222 ubuntu@${VM_IP}"
$SSH "echo OK"
```

---

## Étape 3 — Provisionner le TPM

Le TPM a été activé par Terraform (`hw_tpm_version=2.0`). Il faut maintenant y sceller la master key du Vault.

```bash
# Installer les outils TPM sur la VM
$SSH "sudo apt-get install -y -qq tpm2-tools"

# Vérifier que le TPM est accessible
$SSH "sudo tpm2_getcap properties-fixed -T device:/dev/tpmrm0 | head -5"

# Provisionner la master key dans le TPM
$SSH "sudo node --import tsx src/tpm-provision.ts"
```

### Ce que `tpm-provision.ts` fait

1. Vérifie que le TPM est joignable via `/dev/tpmrm0`
2. Nettoie l'index NV précédent s'il existe
3. Crée un index NV (32 bytes) avec politique PCR `sha256:0,1,2,3,4,5,6,7`
4. Génère une master key aléatoire de 32 bytes
5. Scelle la clé dans le TPM
6. **Affiche la master key en hex (64 chars) → SAUVEGARDER HORS LIGNE**

```
⚠️  Sans cette clé + un TPM réinitialisé = DONNÉES DU VAULT IRRÉCUPÉRABLES.
   Stocker dans KeePass / Bitwarden offline, imprimer, graver sur métal.
```

---

## Étape 4 — Premier déploiement

### 4a. Préparer `deploy.env` sur la VM

```bash
$SSH "cat | sudo tee /opt/opale-vault/deploy.env > /dev/null << 'EOF'
GITHUB_DEPLOY_USER=opale07-dev
GITHUB_DEPLOY_PAT=<ton_PAT_read:packages>
VAULT_ADMIN_PUBKEYS=<ta_pubkey_solana_base58>
VAULT_TPM_NV_INDEX=0x1500016
EOF
sudo chmod 600 /opt/opale-vault/deploy.env"
```

### 4b. Lancer le script de sync

```bash
# Copier le script de sync sur la VM
scp -P 2222 -i ~/Dev/ProjetsPerso/.key/ssh-key-2026-05-09.key \
  ~/Dev/ProjetsPerso/OpaleInfrastructure/opale-infrastructure/scripts/opale-vault-sync.sh \
  ubuntu@${VM_IP}:/opt/opale-vault/

$SSH "sudo chmod +x /opt/opale-vault/opale-vault-sync.sh"

# Exécuter
$SSH "cd /opt/opale-vault && sudo bash opale-vault-sync.sh"
```

### Ce que `opale-vault-sync.sh` fait

1. Lit `deploy.env`
2. Fetch `docker-compose.prod.yml` et `Caddyfile` depuis GitHub
3. Écrit `.env` avec :
   ```
   VAULT_UNSEAL_MODE=tpm
   VAULT_TPM_NV_INDEX=0x1500016
   VAULT_ADMIN_PUBKEYS=<pubkey>
   ```
   → **Aucune passphrase dans .env**
4. Login GHCR
5. `docker compose pull && up -d`
6. Attend le healthcheck (`curl -k https://localhost:8443/api/health`)

---

## Étape 5 — Vérifier

```bash
# Sur la VM vTPM
$SSH "curl -sk https://localhost:8443/api/health"
# → {"status":"ok","timestamp":"...","vault":"ready"}

# Vérifier que le frontend Oracle relaie bien
curl -sk https://core.gmlabs.ch/api/health
# → même réponse

# Vérifier l'audit
$SSH "sudo tail -5 /opt/opale-vault/data/vault-audit.jsonl"
```

---

## Étape 6 — Premier setup admin (via tunnel SSH)

Le dashboard admin Phantom n'est pas encore câblé en production. Contournement :

```bash
# Créer un tunnel SSH vers la VM vTPM (port 8443)
ssh -i ~/Dev/ProjetsPerso/.key/ssh-key-2026-05-09.key \
  -p 2222 -L 8443:localhost:8443 ubuntu@${VM_IP}

# Dans un autre terminal, ouvrir le dashboard Oracle
open https://core.gmlabs.ch
```

> Le frontend Oracle relaie `/api/*` vers la VM vTPM. Le tunnel SSH n'est nécessaire que si tu as besoin d'accéder directement à l'API backend.

---

## Commandes courantes

```bash
# Mise à jour du backend
$SSH "cd /opt/opale-vault && sudo bash opale-vault-sync.sh"

# Redémarrage propre
$SSH "cd /opt/opale-vault && sudo docker compose -f docker-compose.prod.yml down && sudo docker compose -f docker-compose.prod.yml up -d"

# Logs
$SSH "cd /opt/opale-vault && sudo docker compose -f docker-compose.prod.yml logs -f vault"

# Statut du TPM
$SSH "sudo tpm2_getcap properties-fixed -T device:/dev/tpmrm0 | grep -i vendor"

# Backup des données (à planifier en cron)
$SSH "cd /opt/opale-vault && sudo docker compose -f docker-compose.prod.yml exec vault npm run backup"
```

---

## Dépannage

| Problème | Diagnostic | Solution |
|----------|-----------|----------|
| TPM inaccessible | `tpm2_getcap` → erreur | Vérifier que `/dev/tpmrm0` existe et que `tpm2-tools` est installé |
| PCR policy mismatch | Le Vault refuse de desceller après un update kernel | PCRs ont changé → reprovisionner le TPM. Restaurer la master key depuis le backup offline. |
| Caddy TLS internal erreur | `curl -k` fonctionne mais pas `curl` | Normal : Caddy utilise un certificat auto-signé (`tls internal`). Le frontend Oracle a Let's Encrypt. |
| Permission denied sur /data | `EACCES` dans les logs vault | `sudo docker run --rm -v opale-vault_vault-data:/data alpine chown -R 1000:1000 /data` |
| GHCR pull refusé | `unauthorized` | Vérifier que le PAT a le scope `read:packages` et n'a pas expiré |
| Port 8443 inaccessible depuis Oracle | `curl` timeout | Vérifier le security group OpenStack : `vault_allowed_cidr` doit inclure l'IP Oracle |
| Docker permission denied | `ubuntu` pas dans le groupe docker | `sudo usermod -aG docker ubuntu` puis relogin |

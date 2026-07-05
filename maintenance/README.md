# Maintenance des VM Opale (systemd timers)

Tâches de maintenance récurrentes des VM produit, **possédées par
`opale-infrastructure`** conformément à la doctrine DevOps
(`_opale-platform/docs/practices/opale-devops-doctrine.md`, section
« Maintenance vs Deployment »).

## Principe : maintenance ≠ déploiement

Ces timers **entretiennent l'hôte et protègent les données**. Ils ne tirent
jamais de code ou d'image applicative et ne changent jamais la version
déployée — le déploiement reste push-based via CI/CD. C'est la ligne qui rend
ces timers autorisés (et recommandés) alors que les boucles de déploiement
auto restent interdites.

## Contenu

| Fichier | Rôle |
|---|---|
| `opale-maintenance-install.sh` | Installeur idempotent (scripts + unités + env + activation) |
| `opale-backup.sh` | Backup d'un volume Docker : local-first, vérif SHA-256, rotation, off-site optionnel |
| `opale-selfcheck.sh` | Santé, expiration cert TLS, âge des clés (rappel rotation), fraîcheur backup |
| `units/opale-backup@.{service,timer}` | Backup quotidien 03:20 UTC |
| `units/opale-selfcheck@.{service,timer}` | Self-check toutes les 6 h |
| `units/opale-harden@.{service,timer}` | Ré-application hebdo du hardening idempotent (drift) |

Les unités sont templatées par instance : `opale-backup@opale-vault.timer`.
`unattended-upgrades` (patches sécurité OS) est activé par l'installeur.

## Installation

Au premier boot, via cloud-init (déjà câblé pour `infra-vault`), ou à la
demande sur une VM existante avec `scripts/opale-maintenance-remote.sh`.

Exemple d'appel direct (sur la VM, en root) :

```sh
opale-maintenance-install.sh \
  --service opale-vault \
  --volume opale-vault_vault-data \
  --health-url https://127.0.0.1:8443/api/health \
  --health-expect '"status":"ok"' \
  --ssh-port 2222 --app-port 8443 --admin-user ubuntu --app-dir /opt/opale-vault \
  --key-stamp /opt/opale-vault/data/.tpm-provisioned
```

## Modèle de backup : local-first, puis off-site

Première étape (actuelle) : backups locaux dans `/opt/opale-backups/<service>/`,
vérifiés SHA-256, rotation sur 14 archives. Le contenu est déjà chiffré au
repos par le Vault.

⚠️ Un backup local ne protège pas contre la perte de la VM. Étape suivante :
renseigner `OPALE_BACKUP_OFFSITE` (cible rsync/SSH) dans
`/etc/opale/maintenance/<service>.env` pour répliquer hors site. Tant que
c'est vide, le self-check ne l'exige pas mais le backup log le signale.

## Vérification

```sh
systemctl list-timers 'opale-*@opale-vault.timer'
journalctl -u opale-backup@opale-vault.service -n 50
sudo systemctl start opale-selfcheck@opale-vault.service   # exécution immédiate
```

## Rétablir des données

Voir `OpaleVault/docs/procedures/05-backup-restore.md`. Une archive
`opale-vault-<stamp>.tar.gz` se restaure dans le volume Docker via un
conteneur jetable, puis redémarrage du service.

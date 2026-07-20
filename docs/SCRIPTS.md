# 🤖 Scripts d'automatisation

Deux scripts couvrent tout le cycle : installer/mettre à jour le WAF, puis le valider contre une
vraie cible. Le détail de ce que chacun configure exactement est dans
[CONFIGURATION.md](CONFIGURATION.md).

## `install-waf.sh` — installer / mettre à jour le WAF

```bash
sudo ./install-waf.sh
```

Automatise les étapes 1 à 10 de [CONFIGURATION.md](CONFIGURATION.md) : dépendances, compilation
de ModSecurity v3, connecteur Nginx, module dynamique, config ModSecurity, règles OWASP CRS,
site Nginx, démarrage + auto-test.

**Relançable à volonté.** À chaque exécution il :
- récupère la dernière version de ModSecurity (branche `v3/master`), du connecteur Nginx, et le
  dernier tag stable d'OWASP CRS v4 ;
- compare aux versions déjà installées (fichier d'état `/etc/modsecurity/.waf-install-state`) et
  **ne recompile que ce qui a changé** — un rerun sans changement prend quelques secondes, pas
  15 minutes ;
- réapplique la config (mode blocage/détection, niveau de paranoia, site Nginx) selon les options
  passées, même si rien n'a changé côté sources.

### Options

| Option | Effet | Défaut |
|--------|-------|--------|
| `--domain NAME` | `server_name` Nginx | `_` |
| `--port N` | Port d'écoute | `80` |
| `--web-root PATH` | Racine du site | `/var/www/html` |
| `--site-name NAME` | Nom du site Nginx | `waf-test` |
| `--detection-only` | Mode détection (pas de blocage) | blocage actif |
| `--paranoia N` | Niveau de paranoia OWASP CRS (1-4) | `1` |
| `--crs-version TAG\|latest` | Version d'OWASP CRS | `latest` |
| `--modsec-branch BRANCH` | Branche ModSecurity à suivre | `v3/master` |
| `--install-dir PATH` | Dossier des sources compilées | `/opt` |
| `--skip-site` | Ne touche pas à la config Nginx du site | — |
| `--force-rebuild` | Recompile même si rien n'a changé | — |

Toutes les options sont aussi lisibles avec `sudo ./install-waf.sh --help`.

### Exemples

```bash
# Installation par défaut (blocage actif, port 80)
sudo ./install-waf.sh

# Mode détection, pour observer sans bloquer
sudo ./install-waf.sh --detection-only

# Domaine + port custom, paranoia plus stricte
sudo ./install-waf.sh --domain mon-site.local --port 8080 --paranoia 2

# Juste mettre à jour les sources/règles sans toucher au site Nginx existant
sudo ./install-waf.sh --skip-site

# Forcer une recompilation complète même sans changement détecté
sudo ./install-waf.sh --force-rebuild
```

### Personnalisation permanente des règles

- `/etc/modsecurity/crs-custom.conf` — géré par le script (niveau de paranoia via `--paranoia`),
  **régénéré à chaque run**, ne pas éditer à la main.
- `/etc/modsecurity/local-custom.conf` — **jamais touché** par le script : c'est ici que vont tes
  règles ou exclusions personnelles permanentes.

Log complet de chaque run : `/var/log/waf-install.log`.

---

## `vuln-app/deploy-vuln-app.sh` — déployer la cible de test

```bash
cd vuln-app
sudo ./deploy-vuln-app.sh --port 8081
```

Nécessite que `install-waf.sh` ait déjà tourné (le WAF doit exister avant de mettre une cible
derrière). Installe Vuln-App comme service systemd (`vuln-app.service`, isolé sur
`127.0.0.1:5000`) et un site Nginx dédié sur le port choisi, protégé par le même
`/etc/modsecurity/main.conf` que le reste du repo.

| Option | Effet | Défaut |
|--------|-------|--------|
| `--port N` | Port Nginx d'exposition de Vuln-App | `8081` |

La méthodologie de test complète (payloads, comment prouver que l'app est vraiment vulnérable
avant de vérifier que le WAF la protège) est dans [`vuln-app/README.md`](../vuln-app/README.md).

> ⚠️ Laboratoire local uniquement — ne jamais exposer ce port sur Internet.

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

**Détection OS.** Le script lit `/etc/os-release` et s'arrête proprement (message clair) si le
système n'est ni Debian ni Ubuntu — plutôt que d'échouer en plein milieu d'un `apt-get` sur un
système non supporté. Les paquets dont la disponibilité varie selon la version (`libgeoip-dev`,
reliquat PCRE1) sont installés un par un en best-effort : leur absence est juste signalée, elle
ne bloque jamais l'installation des dépendances vraiment requises. Objectif : rester utilisable
sur plusieurs versions d'Ubuntu/Debian dans la durée, sans réécrire le script à chaque nouvelle
release qui renomme ou retire un paquet secondaire.

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
| `--proxy-to URL` | WAF sur `--port`, qui transmet au site réel (ex. `http://127.0.0.1:8090`). Pour protéger un site qui tourne sur **un autre port** | — |
| `--attach-to SITE` | Protège un site Nginx **déjà en place** (son port ne change pas). Ex. `--attach-to default` | — |
| `--allow-ip IP[/CIDR]` | IP de confiance **non filtrée** par le WAF (répétable). Ex. ton poste d'admin | aucune |
| `--upgrade-system` | Fait aussi `apt-get upgrade` (met à jour tout le système) | non |
| `--skip-site` | Ne touche pas à la config Nginx du site | — |
| `--force-rebuild` | Recompile même si rien n'a changé | — |

**Codes de sortie :** `0` = tout est OK ; `1` = erreur. En cas d'erreur, la configuration du site est restaurée à son état précédent.

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

# Garder ton poste d'admin hors du WAF (à réserver à une IP fiable)
sudo ./install-waf.sh --allow-ip 203.0.113.5
```

## Le plus simple : l'assistant

Tape juste `sudo ./install-waf.sh` (sans option). Il te pose des questions :

1. **Ce serveur sert-il déjà un site web ?** Si oui, il liste les sites et leur port, tu choisis celui à protéger.
2. **Sinon**, sur quel port veux-tu le WAF ? Si le port est pris, il propose un port libre.
3. **Mode** : détection (recommandé pour commencer) ou blocage.
4. **Ton IP** : à ajouter à la liste de confiance ?

Rien n'est modifié avant le récapitulatif final et ta confirmation. Les options en ligne de commande
ci-dessous restent disponibles pour ceux qui les connaissent.

## Le WAF peut-il tourner sur un autre port que le site ?

**Pas tout seul.** Un WAF sur le port 8080 ne protège pas un site sur le port 80 : le trafic
passe directement par le port 80 et ne touche jamais le WAF.

Il y a deux façons correctes de protéger un site :

| Ce que tu veux | Option | Résultat |
|---|---|---|
| Protéger le site **sur son port actuel** | `--attach-to SITE` | Le site garde son port, le WAF est dedans. Rien à changer côté visiteurs. |
| Le WAF sur **un autre port**, devant le site | `--proxy-to http://127.0.0.1:PORT_DU_SITE --port NOUVEAU` | Les visiteurs passent par le nouveau port. **Ferme l'ancien port au public** (`sudo ufw deny ANCIEN/tcp`), sinon il reste sans protection. |

L'assistant pose cette question quand il trouve un site existant.

## Port déjà occupé ? Deux solutions

Le WAF n'est lié à aucun port précis. Le port ne sert qu'à savoir où Nginx écoute.

| Situation | Commande |
|---|---|
| Le port est libre, mais tu veux un WAF sur un autre port | `sudo ./install-waf.sh --port 8080` |
| Un site tourne déjà sur le port et tu veux le protéger | `sudo ./install-waf.sh --attach-to NOM_DU_SITE` |

Si le port est pris, le script **propose lui-même un port libre** dans son message d'erreur.

**Différence importante :** sans `--attach-to`, le script crée un **nouveau** site : un site existant
sur le port 80 n'est pas protégé. Avec `--attach-to`, le site existant reçoit la protection
(`modsecurity on;` ajouté dans chacun de ses blocs `server`), sans changer son port.

**Pare-feu :** si UFW est actif, le port du WAF (et celui de Vuln-App) est ouvert automatiquement.
Sinon, ouvre-le toi-même : `sudo ufw allow PORT/tcp`.

## Sur un serveur qui sert déjà du web

Le script est prévu pour tourner sur une machine déjà en service. Ce qu'il fait exactement :

- **Avant toute modification**, il vérifie que le port (80 par défaut) est libre. Si Apache ou un
  autre service l'occupe, il s'arrête avec un message et ne touche à rien.
- **Il refuse** de remplacer un autre site Nginx qui écoute déjà sur le même port.
- **Le site par défaut** d'Ubuntu et les autres sites ne sont **jamais modifiés**.
- **Les autres sites Nginx** ne sont pas modifiés.
- **Il ne fait pas de `apt upgrade`** par défaut : seuls Nginx et les dépendances de compilation
  sont installés. Option `--upgrade-system` si tu veux tout mettre à jour.
- **Redémarrage de Nginx** : c'est le seul moment où les autres sites Nginx sont brièvement
  coupés (quelques secondes). Prévois-le.
- **Si la config est refusée**, le site est restauré à son état précédent et Nginx n'est pas redémarré.

> ⚠️ Vérifie avant : `sudo ss -ltnp` (quels services écoutent) et `ls /etc/nginx/sites-enabled/`.

### Personnalisation permanente des règles

- `/etc/modsecurity/crs-custom.conf` — géré par le script (niveau de paranoia via `--paranoia`),
  **régénéré à chaque run**, ne pas éditer à la main.
- `/etc/modsecurity/allowlist.conf` — généré par `--allow-ip` (IPs de confiance, chargé avant les règles).
- `/etc/modsecurity/local-before.conf` — **jamais touché** : exclusions à appliquer **avant** les règles OWASP.
- `/etc/modsecurity/local-after.conf` — **jamais touché** : `SecRuleRemoveById` à appliquer **après** les règles.
- Ancien `local-custom.conf` : repris automatiquement dans `local-after.conf` (il était déjà chargé après).
- `local-custom.conf` (ancien emplacement) — **jamais touché** par le script : c'est ici que vont tes
  règles ou exclusions personnelles permanentes.

Log complet de chaque run : `/var/log/waf-install.log`.

---

## `vuln-app/deploy-vuln-app.sh` — déployer la cible de test

```bash
cd vuln-app
sudo ./deploy-vuln-app.sh --port 8081
```

Fonctionne dans les deux ordres. Installe toujours Vuln-App comme service systemd
(`vuln-app.service`, isolé sur `127.0.0.1:5000`), **et** un site Nginx accessible via l'IP de la
VM sur le port choisi — Flask lui-même n'est jamais exposé directement. Si `install-waf.sh` a
déjà tourné (`/etc/modsecurity/main.conf` présent), ce site est protégé par ModSecurity ; sinon
c'est un simple reverse-proxy, pour pouvoir tester dans un navigateur avant même d'installer le
WAF. Relance le script après `install-waf.sh` pour activer la protection sur le même site.
Vérifie réellement que le port répond avant de rendre la main (sinon affiche les logs et échoue).

| Option | Effet | Défaut |
|--------|-------|--------|
| `--port N` | Port Nginx d'exposition de Vuln-App | `8081` |

La méthodologie de test complète (payloads, comment prouver que l'app est vraiment vulnérable
avant de vérifier que le WAF la protège) est dans [`vuln-app/README.md`](../vuln-app/README.md).

> ⚠️ Laboratoire local uniquement — ne jamais exposer ce port sur Internet.

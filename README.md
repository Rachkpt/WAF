<p align="center">
  <img src="assets/logo.png" alt="Logo WAF" width="220">
</p>

# 🛡️ WAF — Nginx + ModSecurity v3 + OWASP CRS

> Laboratoire complet pour déployer un WAF (Nginx + ModSecurity v3 + OWASP CRS) sur une VM
> Ubuntu Server, avec un script d'installation/mise à jour automatique, et une application
> volontairement vulnérable pour vérifier que ça bloque vraiment.

⚠️ **Usage lab/éducatif.** Pensé pour une VM locale isolée. Ne pas exposer une installation issue
de ce repo directement sur Internet sans l'avoir durcie et auditée toi-même.

---

## 📋 Environnement testé

- **OS** : Ubuntu Server 24.04
- **Nginx** : 1.24.0
- **ModSecurity** : v3.0.14
- **Connecteur** : ModSecurity-nginx v1.0.4
- **Règles** : OWASP CRS v4 (843 règles)

## 🏗️ Architecture

```
[Attaquant / Navigateur]
         │
         ▼
[Nginx 1.24.0]
         │
         ▼
[ModSecurity v3.0.14]  ◄── 843 règles OWASP CRS v4
         │
         ├── SQL Injection    → 🚫 BLOQUÉ (403)
         ├── XSS              → 🚫 BLOQUÉ (403)
         ├── Path Traversal   → 🚫 BLOQUÉ (403)
         └── Trafic normal    → ✅ AUTORISÉ (200)
         │
         ▼
[Application Web]
```

---

## 🚀 Installation — deux méthodes au choix

### Option A — Script automatique (rapide, recommandé)

```bash
sudo ./install-waf.sh
```

Une seule commande : installe et configure tout (Nginx, ModSecurity v3, connecteur, OWASP CRS).
Relançable à volonté pour mettre à jour. Personnalisable via des options
(`--domain`, `--port`, `--paranoia`, `--detection-only`, ...). Détail complet des options et
exemples : [`docs/SCRIPTS.md`](docs/SCRIPTS.md).

### Option B — Installation manuelle (pour comprendre / débugger)

Les 10 étapes détaillées (dépendances, compilation ModSecurity, module Nginx, config CRS, site
Nginx...) sont documentées commande par commande dans
[`docs/CONFIGURATION.md`](docs/CONFIGURATION.md). C'est exactement ce que fait le script
ci-dessus, mais à la main — utile pour comprendre ce qui se passe, adapter une étape précise, ou
diagnostiquer une erreur de compilation.

> Les deux méthodes aboutissent à la même config (`/etc/modsecurity/`, `/etc/nginx/`) — tu peux
> commencer en manuel puis basculer sur le script (ou l'inverse) sans conflit.

### Ensuite — valider que le WAF bloque vraiment

```bash
cd vuln-app && sudo ./deploy-vuln-app.sh   # cible volontairement vulnérable, derrière le WAF
curl -s "http://VM_IP:8081/search?q=<script>alert(1)</script>"   # doit renvoyer 403
```

Méthodologie complète et payloads par type de faille : [`vuln-app/README.md`](vuln-app/README.md).

---

## 📚 Documentation

| Fichier | Contenu |
|---------|---------|
| [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) | Détail étape par étape de ce que fait le WAF sous le capot (compilation, config ModSecurity/CRS, structure des fichiers, logs, commandes utiles) — pour comprendre, débugger ou installer à la main |
| [`docs/SCRIPTS.md`](docs/SCRIPTS.md) | Doc de `install-waf.sh` et `vuln-app/deploy-vuln-app.sh` : options, exemples, comportement de mise à jour |
| [`vuln-app/README.md`](vuln-app/README.md) | La cible de test vulnérable : payloads par type de faille, méthodologie pour prouver que le WAF bloque réellement |

## 📁 Structure du repo

```
.
├── README.md              ← ce fichier (vue d'ensemble)
├── install-waf.sh          ← installe / met à jour le WAF
├── docs/
│   ├── CONFIGURATION.md   ← détail technique étape par étape
│   └── SCRIPTS.md          ← doc des scripts
└── vuln-app/
    ├── README.md           ← méthodologie de test + payloads
    ├── app.py               ← app Flask volontairement vulnérable
    ├── deploy-vuln-app.sh   ← déploie la cible derrière le WAF
    └── requirements.txt
```

## 📚 Ressources externes

- [ModSecurity GitHub](https://github.com/SpiderLabs/ModSecurity)
- [OWASP Core Rule Set](https://github.com/coreruleset/coreruleset)
- [ModSecurity-nginx connector](https://github.com/SpiderLabs/ModSecurity-nginx)
- [OWASP Top 10](https://owasp.org/www-project-top-ten/)

## 📄 Licence

[MIT](LICENSE) — voir la note d'usage lab/éducatif à la fin du fichier.

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

## 🚀 Démarrage rapide

```bash
# 1. Installer le WAF (relançable pour mettre à jour)
sudo ./install-waf.sh

# 2. Déployer une cible volontairement vulnérable derrière, pour tester
cd vuln-app && sudo ./deploy-vuln-app.sh

# 3. Attaquer la cible et vérifier que le WAF bloque (403)
curl -s "http://VM_IP:8081/search?q=<script>alert(1)</script>"
```

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

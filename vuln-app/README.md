# 🎯 Vuln-App — cible de test pour valider le WAF

> ⚠️ **Application volontairement vulnérable.** Aucune sanitisation nulle part, exprès.
> Usage strictement local/lab, sur ta propre VM, jamais exposée sur Internet.
> N'écoute que sur `127.0.0.1:5000` ; seul Nginx (avec ModSecurity devant) y a accès.

## Pourquoi

Pour vérifier qu'un WAF « marche vraiment », il ne suffit pas de lire la config : il faut
l'attaquer avec de vrais payloads contre une cible réellement exploitable, et confirmer que
c'est bien **ModSecurity qui bloque (403)**, pas l'application qui se défend elle-même.

## Déploiement — marche dans les deux ordres

`deploy-vuln-app.sh` déploie toujours l'app (service systemd, écoute `127.0.0.1:5000`). Il détecte
tout seul si le WAF est déjà là :

```bash
cd vuln-app
sudo ./deploy-vuln-app.sh --port 8081
```

- **Pas de WAF installé** → l'app tourne sur `127.0.0.1:5000`, aucune config Nginx créée. Teste
  directement en local, hors WAF, pour prouver qu'elle est vraiment exploitable.
- **`install-waf.sh` déjà exécuté** (`/etc/modsecurity/main.conf` présent) → un site Nginx dédié
  est en plus créé sur le port choisi, protégé par le **même** `main.conf` ModSecurity que le
  reste du repo.

## Méthodologie de test (le principe demandé) : vulnérable d'abord, WAF ensuite

1. **Déploie et prouve que l'app est vraiment vulnérable, sans WAF** :
   ```bash
   cd vuln-app && sudo ./deploy-vuln-app.sh
   curl -s "http://127.0.0.1:5000/search?q=<script>alert(1)</script>"
   ```
   (payloads complets ci-dessous, à pointer sur `127.0.0.1:5000` à cette étape). Ils doivent
   **réussir**.
2. **Installe le WAF** — `sudo ./install-waf.sh` (mode `On`/blocage par défaut) depuis la racine
   du repo.
3. **Relance le déploiement pour brancher le site protégé** — `sudo ./deploy-vuln-app.sh --port
   8081`, il détecte le WAF cette fois et crée le site Nginx.
4. **Relance les mêmes payloads, cette fois contre le port Nginx** (`8081` par défaut, remplace
   `127.0.0.1:5000` par `VM_IP:8081` dans les commandes ci-dessous). Ils doivent maintenant
   renvoyer **403**.

Si étape 1 échoue → l'app n'est pas vulnérable, le test ne prouve rien.
Si étape 4 échoue → le WAF ne bloque pas, c'est un vrai problème de config à corriger.

## Payloads de test

Remplace `VM_IP` par l'IP de ta VM et `8081` par le port choisi.

```bash
BASE="http://VM_IP:8081"

# XSS réfléchi
curl -s "$BASE/search?q=<script>alert(1)</script>"

# Injection SQL (bypass d'authentification classique)
curl -s -X POST "$BASE/login" -d "username=admin' OR '1'='1&password=x"

# Path traversal / LFI
curl -s "$BASE/file?name=../../../../etc/passwd"

# Injection de commande
curl -s "$BASE/ping?host=127.0.0.1;id"

# Open redirect
curl -s -I "$BASE/redirect?url=http://evil.example.com"

# SSRF (tente d'atteindre un service interne)
curl -s "$BASE/fetch?url=http://127.0.0.1:22"

# Upload sans validation (ex: faux webshell PHP)
curl -s -F "file=@/etc/hostname;filename=shell.php" "$BASE/upload"

# XXE
curl -s -X POST "$BASE/xml" -H "Content-Type: application/xml" --data '
<?xml version="1.0"?>
<!DOCTYPE foo [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
<foo>&xxe;</foo>'
```

En mode blocage (`SecRuleEngine On`), chaque commande doit renvoyer **`403 Forbidden`**
(vérifiable avec `curl -I` ou en regardant `sudo tail -f /var/log/modsec_audit.log`).

## Nettoyage

```bash
sudo systemctl disable --now vuln-app
sudo rm -f /etc/nginx/sites-enabled/vuln-app /etc/nginx/sites-available/vuln-app
sudo systemctl reload nginx
```

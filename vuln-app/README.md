# 🎯 Vuln-App — cible de test pour valider le WAF

> ⚠️ **Application volontairement vulnérable.** Aucune sanitisation nulle part, exprès.
> Usage strictement local/lab, sur ta propre VM, jamais exposée sur Internet.
> N'écoute que sur `127.0.0.1:5000` ; seul Nginx (avec ModSecurity devant) y a accès.

## Pourquoi

Pour vérifier qu'un WAF « marche vraiment », il ne suffit pas de lire la config : il faut
l'attaquer avec de vrais payloads contre une cible réellement exploitable, et confirmer que
c'est bien **ModSecurity qui bloque (403)**, pas l'application qui se défend elle-même.

## Déploiement

Nécessite que `install-waf.sh` (à la racine du repo) ait déjà tourné.

```bash
cd vuln-app
sudo ./deploy-vuln-app.sh --port 8081
```

Ça installe Vuln-App comme service systemd (`vuln-app.service`, écoute 127.0.0.1:5000), et crée
un site Nginx dédié sur le port choisi, protégé par le **même** `main.conf` ModSecurity que le
reste du repo.

## Méthodologie de test (le principe demandé)

1. **Prouver que l'app est vraiment vulnérable** — passe ModSecurity en mode détection
   (`sudo ./install-waf.sh --detection-only`) ou attaque directement `127.0.0.1:5000` depuis la
   VM (hors WAF). Les payloads ci-dessous doivent **réussir**.
2. **Repasse en mode blocage** — `sudo ./install-waf.sh` (mode `On` par défaut).
3. **Relance les mêmes payloads contre le port Nginx** (`8081` par défaut). Ils doivent
   maintenant renvoyer **403**.

Si étape 1 échoue → l'app n'est pas vulnérable, le test ne prouve rien.
Si étape 3 échoue → le WAF ne bloque pas, c'est un vrai problème de config à corriger.

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

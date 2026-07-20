# ⚙️ Configuration détaillée — Nginx + ModSecurity v3 + OWASP CRS

> Détail étape par étape de ce que fait [`install-waf.sh`](../install-waf.sh). Utile pour
> comprendre le fonctionnement interne, débugger un problème précis, ou installer à la main.
> Pour l'usage courant, préfère le script automatique — voir [SCRIPTS.md](SCRIPTS.md).

## 📋 Environnement testé

- **OS** : Ubuntu Server 24.04
- **Nginx** : 1.24.0
- **ModSecurity** : v3.0.14
- **Connecteur** : ModSecurity-nginx v1.0.4
- **Règles** : OWASP CRS v4 (843 règles)

---

### Étape 1 — Mettre à jour et installer les dépendances

```bash
sudo apt update && sudo apt upgrade -y

# Nginx doit être installé AVANT l'étape 4 (recompilation du module),
# sinon "nginx -v" échouera car aucun Nginx n'est présent sur le système.
sudo apt install -y nginx

sudo apt install -y \
  git build-essential libpcre3 libpcre3-dev libpcre2-dev \
  libssl-dev libtool autoconf automake \
  libxml2 libxml2-dev libcurl4-openssl-dev \
  pkg-config libgeoip-dev libyajl-dev \
  libmaxminddb-dev wget curl
```

> ⚠️ `libpcre2-dev` est indispensable : les versions récentes de ModSecurity compilent contre
> PCRE2 (`#include <pcre2.h>`), pas l'ancien PCRE1. Sans lui : `fatal error: pcre2.h: No such
> file or directory` à la compilation.

> ⚠️ `automake` est indispensable : `build.sh` (étape 2) appelle `autoreconf`/`aclocal`, qui
> viennent du paquet `automake`. Sans lui, la compilation de ModSecurity échoue immédiatement.

> ⚠️ Si `libgeoip-dev` n'est pas trouvé, le dépôt `universe` n'est probablement pas activé :
> `sudo add-apt-repository universe && sudo apt update`

---

### Étape 2 — Compiler ModSecurity v3 depuis les sources

> ⚠️ Le paquet `libnginx-mod-security2` n'est pas disponible sur Ubuntu 24.04, il faut compiler depuis les sources.

```bash
cd /opt
sudo git clone --depth 1 https://github.com/SpiderLabs/ModSecurity
cd ModSecurity
sudo git submodule init
sudo git submodule update --recursive
sudo ./build.sh
sudo ./configure
sudo make -j$(nproc)
sudo make install
```

> ⚠️ Le `--recursive` est obligatoire : Mbed TLS est un sous-module imbriqué (sous-module d'un
> sous-module). Sans lui, `./configure` échoue avec `Mbed TLS was not found within ModSecurity
> source directory`.

> ⏳ La compilation prend environ 5 à 15 minutes selon les ressources de la VM.

---

### Étape 3 — Télécharger le connecteur ModSecurity-Nginx

```bash
cd /opt
sudo git clone --depth 1 https://github.com/SpiderLabs/ModSecurity-nginx
```

---

### Étape 4 — Recompiler Nginx avec le module ModSecurity

> ⚠️ **Point critique** : un module dynamique doit être compilé avec **exactement les mêmes
> arguments `configure`** que le Nginx installé, sinon Nginx refuse de le charger avec l'erreur
> `... is not binary compatible`. On récupère donc ces arguments directement depuis `nginx -V`
> au lieu de les deviner.

```bash
# Récupérer la version exacte de Nginx installée
NGINX_VERSION=$(nginx -v 2>&1 | grep -o '[0-9.]*' | head -1)
echo "Version Nginx : $NGINX_VERSION"

# Récupérer les arguments de configure utilisés pour compiler le Nginx installé
NGINX_CONFIGURE_ARGS=$(nginx -V 2>&1 | grep 'configure arguments:' | sed 's/configure arguments: //')
echo "Arguments : $NGINX_CONFIGURE_ARGS"

# Télécharger les sources Nginx correspondantes
cd /opt
sudo wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz
sudo tar -xzf nginx-${NGINX_VERSION}.tar.gz
cd nginx-${NGINX_VERSION}

# Compiler le module dynamique avec les MÊMES arguments que le Nginx installé
# (tout entre guillemets pour que "eval" ré-interprète correctement les guillemets
# imbriqués présents dans les arguments d'origine, ex: --with-cc-opt='-g -O2 ...')
eval "sudo ./configure $NGINX_CONFIGURE_ARGS --add-dynamic-module=/opt/ModSecurity-nginx"

sudo make modules
```

> 💡 Si `./configure` échoue en réclamant des en-têtes manquants (ex : `libxslt`, `libgd`,
> `libperl`, `libgeoip`), c'est que le Nginx packagé Ubuntu a été compilé avec des modules
> optionnels qui nécessitent ces librairies `-dev`. Installez celles indiquées par l'erreur, par
> exemple : `sudo apt install -y libxslt1-dev libgd-dev libperl-dev zlib1g-dev`.

---

### Étape 5 — Copier le module compilé

```bash
# Créer le dossier des modules
sudo mkdir -p /usr/lib/nginx/modules

# Copier le module
sudo cp objs/ngx_http_modsecurity_module.so /usr/lib/nginx/modules/

# Vérifier
ls -la /usr/lib/nginx/modules/
```

Résultat attendu :
```
-rwxr-xr-x 1 root root 207080 ...  ngx_http_modsecurity_module.so
```

---

### Étape 6 — Charger le module dans Nginx

Le paquet Nginx d'Ubuntu inclut déjà `include /etc/nginx/modules-enabled/*.conf;` tout en haut de
`nginx.conf` : on dépose donc simplement un fichier dans ce dossier, plus propre et plus fiable
qu'une édition manuelle de `nginx.conf`.

```bash
echo "load_module /usr/lib/nginx/modules/ngx_http_modsecurity_module.so;" \
  | sudo tee /etc/nginx/modules-enabled/50-mod-http-modsecurity.conf
```

---

### Étape 7 — Configurer ModSecurity

```bash
sudo mkdir -p /etc/modsecurity

# Copier la config et le fichier unicode
sudo cp /opt/ModSecurity/modsecurity.conf-recommended \
        /etc/modsecurity/modsecurity.conf

sudo cp /opt/ModSecurity/unicode.mapping \
        /etc/modsecurity/

# Activer le mode BLOCAGE (par défaut c'est DetectionOnly)
sudo sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' \
    /etc/modsecurity/modsecurity.conf

# Forcer le chemin du log d'audit (utilisé plus bas dans "Surveillance des logs")
sudo sed -i 's#^SecAuditLog .*#SecAuditLog /var/log/modsec_audit.log#' \
    /etc/modsecurity/modsecurity.conf
```

---

### Étape 8 — Installer les règles OWASP CRS

```bash
cd /etc/modsecurity
sudo git clone https://github.com/coreruleset/coreruleset.git
sudo cp coreruleset/crs-setup.conf.example coreruleset/crs-setup.conf

# Créer le fichier principal qui charge tout
sudo bash -c 'cat > /etc/modsecurity/main.conf << EOF
Include /etc/modsecurity/modsecurity.conf
Include /etc/modsecurity/coreruleset/crs-setup.conf
Include /etc/modsecurity/coreruleset/rules/*.conf
EOF'
```

> ℹ️ `install-waf.sh` va plus loin : il insère aussi `crs-custom.conf` (niveau de paranoia,
> régénéré à chaque run) et `local-custom.conf` (jamais écrasé, pour tes règles perso) entre
> `crs-setup.conf` et `rules/*.conf`. Voir [SCRIPTS.md](SCRIPTS.md).

---

### Étape 9 — Créer le site Nginx avec WAF activé

```bash
sudo bash -c 'cat > /etc/nginx/sites-available/waf-test << EOF
server {
    listen 80;
    server_name _;

    modsecurity on;
    modsecurity_rules_file /etc/modsecurity/main.conf;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF'

# Activer le site et désactiver celui par défaut
sudo ln -s /etc/nginx/sites-available/waf-test /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Créer une page d'accueil simple
sudo bash -c 'echo "<h1>Site protege par WAF</h1>" > /var/www/html/index.html'
```

---

### Étape 10 — Vérifier et démarrer

```bash
# Vérifier la configuration (doit afficher "syntax is ok")
sudo nginx -t

# Redémarrer Nginx (pas "start" : Nginx tourne déjà depuis l'étape 1,
# il faut un "restart" pour charger le module + le nouveau site)
sudo systemctl restart nginx
sudo systemctl enable nginx

# Vérifier le statut
sudo systemctl status nginx
```

Résultat attendu dans `nginx -t` :
```
[notice] ModSecurity-nginx v1.0.4 (rules loaded inline/local/remote: 0/843/0)
[notice] libmodsecurity3 version 3.0.14
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

---

## 🧪 Tests manuels

```bash
# ✅ Trafic normal — doit retourner 200 OK
curl -I http://localhost/

# 🚫 SQL Injection — doit retourner 403 Forbidden
curl -I "http://localhost/?id=1%27%20OR%20%271%27%3D%271"

# 🚫 XSS — doit retourner 403 Forbidden
curl -I "http://localhost/?q=<script>alert(xss)</script>"

# 🚫 Path Traversal — doit retourner 403 Forbidden
curl -I "http://localhost/?file=../../etc/passwd"
```

> 💡 Pour le SQL Injection, utiliser l'encodage URL dans curl (`%27` = `'`, `%20` = espace).

Résultat attendu :
```
$ curl -I http://localhost/
HTTP/1.1 200 OK   ← trafic normal autorisé ✅

$ curl -I "http://localhost/?id=1%27%20OR%20%271%27%3D%271"
HTTP/1.1 403 Forbidden   ← SQL Injection bloquée 🚫

$ curl -I "http://localhost/?q=<script>alert(xss)</script>"
HTTP/1.1 403 Forbidden   ← XSS bloquée 🚫

$ curl -I "http://localhost/?file=../../etc/passwd"
HTTP/1.1 403 Forbidden   ← Path Traversal bloquée 🚫
```

Pour un test contre une vraie application exploitable plutôt qu'un fichier statique, voir
[`vuln-app/README.md`](../vuln-app/README.md).

---

## 📊 Surveillance des logs

```bash
# Voir les attaques bloquées en temps réel
sudo tail -f /var/log/modsec_audit.log

# Logs Nginx
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log

# Compter le nombre d'attaques bloquées
sudo grep "Access denied" /var/log/modsec_audit.log | wc -l
```

---

## 🔧 Commandes utiles

| Action | Commande |
|--------|----------|
| Redémarrer le WAF | `sudo systemctl restart nginx` |
| Vérifier la config | `sudo nginx -t` |
| Statut du service | `sudo systemctl status nginx` |
| Voir les blocages | `sudo tail -f /var/log/modsec_audit.log` |
| Arrêter le WAF | `sudo systemctl stop nginx` |

---

## 📁 Structure des fichiers importants

```
/etc/nginx/
├── nginx.conf                          # Config principale
├── modules-enabled/
│   └── 50-mod-http-modsecurity.conf    # load_module du module ModSecurity
├── sites-available/
│   └── waf-test                        # Config du site avec WAF
└── sites-enabled/
    └── waf-test -> ../sites-available/waf-test

/etc/modsecurity/
├── modsecurity.conf                    # Config ModSecurity (SecRuleEngine On)
├── unicode.mapping                     # Mapping unicode
├── main.conf                           # Fichier principal qui inclut tout
├── crs-custom.conf                     # Niveau de paranoia (géré par install-waf.sh)
├── local-custom.conf                   # Règles perso (jamais touché par le script)
└── coreruleset/
    ├── crs-setup.conf                  # Config des règles OWASP
    └── rules/                          # 843 règles OWASP CRS v4

/usr/lib/nginx/modules/
└── ngx_http_modsecurity_module.so      # Module compilé

/var/log/
├── modsec_audit.log                    # Log des attaques détectées/bloquées
└── nginx/
    ├── access.log
    └── error.log
```

---

## 📚 Ressources

- [ModSecurity GitHub](https://github.com/SpiderLabs/ModSecurity)
- [OWASP Core Rule Set](https://github.com/coreruleset/coreruleset)
- [ModSecurity-nginx connector](https://github.com/SpiderLabs/ModSecurity-nginx)
- [OWASP Top 10](https://owasp.org/www-project-top-ten/)

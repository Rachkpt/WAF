# WAF
Waf

# 🛡️ WAF - Web Application Firewall sur VM Ubuntu

> Installation complète de ModSecurity v3 + Nginx + OWASP CRS sur Ubuntu Server (sans domaine, en VM locale)

---

## 📋 Environnement testé

- **OS** : Ubuntu Server 24.04
- **Nginx** : 1.24.0
- **ModSecurity** : v3.0.14
- **Connecteur** : ModSecurity-nginx v1.0.4
- **Règles** : OWASP CRS v4 (843 règles)

---

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

## ⚙️ Installation

### Étape 1 — Mettre à jour et installer les dépendances

```bash
sudo apt update && sudo apt upgrade -y

sudo apt install -y \
  git build-essential libpcre3 libpcre3-dev \
  libssl-dev libtool autoconf \
  libxml2 libxml2-dev libcurl4-openssl-dev \
  pkg-config libgeoip-dev libyajl-dev \
  libmaxminddb-dev wget curl
```

---

### Étape 2 — Compiler ModSecurity v3 depuis les sources

> ⚠️ Le paquet `libnginx-mod-security2` n'est pas disponible sur Ubuntu 24.04, il faut compiler depuis les sources.

```bash
cd /opt
sudo git clone --depth 1 https://github.com/SpiderLabs/ModSecurity
cd ModSecurity
sudo git submodule init
sudo git submodule update
sudo ./build.sh
sudo ./configure
sudo make -j$(nproc)
sudo make install
```

> ⏳ La compilation prend environ 5 à 15 minutes selon les ressources de la VM.

---

### Étape 3 — Télécharger le connecteur ModSecurity-Nginx

```bash
cd /opt
sudo git clone --depth 1 https://github.com/SpiderLabs/ModSecurity-nginx
```

---

### Étape 4 — Recompiler Nginx avec le module ModSecurity

```bash
# Récupérer la version exacte de Nginx installée
NGINX_VERSION=$(nginx -v 2>&1 | grep -o '[0-9.]*')
echo "Version Nginx : $NGINX_VERSION"

# Télécharger les sources Nginx correspondantes
cd /opt
sudo wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz
sudo tar -xzf nginx-${NGINX_VERSION}.tar.gz
cd nginx-${NGINX_VERSION}

# Compiler uniquement le module dynamique
sudo ./configure \
  --with-compat \
  --add-dynamic-module=/opt/ModSecurity-nginx

sudo make modules
```

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

Éditer `/etc/nginx/nginx.conf` et ajouter **tout en haut** du fichier :

```nginx
load_module /usr/lib/nginx/modules/ngx_http_modsecurity_module.so;
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

# Démarrer Nginx
sudo systemctl start nginx
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

## 🧪 Tests

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
├── nginx.conf                          # Config principale (load_module ici)
├── sites-available/
│   └── waf-test                        # Config du site avec WAF
└── sites-enabled/
    └── waf-test -> ../sites-available/waf-test

/etc/modsecurity/
├── modsecurity.conf                    # Config ModSecurity (SecRuleEngine On)
├── unicode.mapping                     # Mapping unicode
├── main.conf                           # Fichier principal qui inclut tout
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

## ✅ Résultat final

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

---

## 📚 Ressources

- [ModSecurity GitHub](https://github.com/SpiderLabs/ModSecurity)
- [OWASP Core Rule Set](https://github.com/coreruleset/coreruleset)
- [ModSecurity-nginx connector](https://github.com/SpiderLabs/ModSecurity-nginx)
- [OWASP Top 10](https://owasp.org/www-project-top-ten/)

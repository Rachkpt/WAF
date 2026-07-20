#!/usr/bin/env bash
#
# deploy-vuln-app.sh — déploie Vuln-App derrière le Nginx+ModSecurity déjà installé
# (voir install-waf.sh à la racine du repo), pour tester le WAF en conditions réelles.
#
# ⚠️ Laboratoire local uniquement. Ne jamais exposer ce port sur Internet.
#
# Usage : sudo ./deploy-vuln-app.sh [--port N]
#   --port N   port Nginx sur lequel Vuln-App est exposée (défaut: 8081)

set -euo pipefail

PORT="${PORT:-8081}"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_USER="vulnapp"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 1 ;;
  esac
done

[[ "$EUID" -eq 0 ]] || { echo "Lance ce script en root : sudo ./deploy-vuln-app.sh" >&2; exit 1; }
[[ -f /etc/modsecurity/main.conf ]] || {
  echo "install-waf.sh doit avoir tourné avant (main.conf ModSecurity introuvable)." >&2
  exit 1
}

log() { echo -e "\e[1;34m[vuln-app]\e[0m $*"; }

log "Installation des dépendances Python..."
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq python3 python3-venv python3-pip libxml2-dev libxslt1-dev iputils-ping

id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"

log "Création de l'environnement virtuel..."
python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/.venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

mkdir -p "$APP_DIR/files"
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

log "Création du service systemd vuln-app..."
cat > /etc/systemd/system/vuln-app.service <<EOF
[Unit]
Description=Vuln-App - cible de test WAF (lab local uniquement)
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/.venv/bin/python ${APP_DIR}/app.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --quiet vuln-app
systemctl restart vuln-app

log "Configuration du site Nginx (port ${PORT}, protégé par le même WAF que main.conf)..."
cat > /etc/nginx/sites-available/vuln-app <<EOF
server {
    listen ${PORT};
    server_name _;

    modsecurity on;
    modsecurity_rules_file /etc/modsecurity/main.conf;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
ln -sf /etc/nginx/sites-available/vuln-app /etc/nginx/sites-enabled/vuln-app
nginx -t
systemctl restart nginx

log "Terminé. Vuln-App est en écoute sur http://<IP_VM>:${PORT}/ (à travers le WAF)."
log "Voir vuln-app/README.md pour la liste des payloads de test."

#!/usr/bin/env bash
#
# deploy-vuln-app.sh — déploie Vuln-App (service systemd sur 127.0.0.1:5000).
# Marche dans les deux ordres :
#   - Sans WAF installé : app accessible en direct sur 127.0.0.1:5000 pour
#     prouver qu'elle est vraiment vulnérable, pas de config Nginx créée.
#   - Après install-waf.sh (main.conf présent) : ajoute aussi un site Nginx
#     protégé par ModSecurity sur le port choisi, et bascule automatiquement
#     dessus si tu relances ce script plus tard.
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
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 1 ;;
  esac
done

[[ "$EUID" -eq 0 ]] || { echo "Lance ce script en root : sudo ./deploy-vuln-app.sh" >&2; exit 1; }

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
log "Service vuln-app démarré (127.0.0.1:5000)."

if command -v nginx >/dev/null 2>&1 && [[ -f /etc/modsecurity/main.conf ]]; then
  log "WAF détecté — configuration du site Nginx (port ${PORT}, protégé par main.conf)..."
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
else
  log "Pas de WAF installé pour l'instant — aucune config Nginx créée."
  log "Teste directement en local, hors WAF, pour prouver que l'app est vulnérable :"
  log "  curl \"http://127.0.0.1:5000/search?q=<script>alert(1)</script>\""
  log "Une fois convaincu, lance 'sudo ../install-waf.sh' puis relance ce script :"
  log "il détectera le WAF et ajoutera automatiquement le site Nginx protégé sur le port ${PORT}."
fi

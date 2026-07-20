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
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/opt/vuln-app"
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
die() { echo -e "\e[1;31m[erreur]\e[0m $*" >&2; exit 1; }

log "Installation des dépendances Python..."
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq python3 python3-venv python3-pip libxml2-dev libxslt1-dev iputils-ping curl

id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"

# Déployée dans /opt (traversable par tous), pas depuis l'emplacement du clone :
# si le repo est cloné sous /root/WAF (courant en root), /root est en 700 et
# l'utilisateur non-privilégié "vulnapp" ne pourrait même pas lire son propre
# dossier de travail -> le service crash en boucle et le port n'écoute jamais.
log "Déploiement de l'app dans ${APP_DIR}..."
mkdir -p "$APP_DIR/files"
cp "$SRC_DIR/app.py" "$SRC_DIR/requirements.txt" "$APP_DIR/"

log "Création/mise à jour de l'environnement virtuel..."
[[ -d "$APP_DIR/.venv" ]] || python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/.venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

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

# Ne jamais annoncer "démarré" sans l'avoir vérifié : on attend que le port
# réponde vraiment, sinon on affiche les logs du service et on échoue.
log "Vérification que le service répond bien sur 127.0.0.1:5000..."
up=0
for _ in $(seq 1 15); do
  if curl -s -o /dev/null "http://127.0.0.1:5000/"; then
    up=1
    break
  fi
  sleep 1
done
if [[ "$up" != "1" ]]; then
  echo "--- journalctl -u vuln-app (dernières lignes) ---" >&2
  journalctl -u vuln-app --no-pager -n 40 >&2 || true
  die "Le service vuln-app ne répond pas sur 127.0.0.1:5000 (voir logs ci-dessus)."
fi
log "Service vuln-app opérationnel (127.0.0.1:5000)."

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

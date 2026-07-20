#!/usr/bin/env bash
#
# deploy-vuln-app.sh — déploie Vuln-App (service systemd, isolé sur 127.0.0.1:5000)
# derrière un site Nginx accessible via l'IP de la VM sur le port choisi.
# Marche dans les deux ordres :
#   - Sans WAF installé : simple reverse-proxy Nginx (pas de ModSecurity) —
#     pratique pour prouver que l'app est vraiment vulnérable, dans un vrai
#     navigateur, avant d'ajouter la protection.
#   - Après install-waf.sh (main.conf présent) : le même site est protégé par
#     ModSecurity. Relance ce script après avoir installé le WAF pour basculer
#     automatiquement dessus.
#
# ⚠️ Laboratoire local/réseau privé uniquement. Ne jamais exposer ce port sur
# Internet, même avec le WAF actif : c'est une cible d'entraînement, pas un
# produit durci.
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
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 1 ;;
  esac
done

[[ "$EUID" -eq 0 ]] || { echo "Lance ce script en root : sudo ./deploy-vuln-app.sh" >&2; exit 1; }

log() { echo -e "\e[1;34m[vuln-app]\e[0m $*"; }
die() { echo -e "\e[1;31m[erreur]\e[0m $*" >&2; exit 1; }

detect_os() {
  [[ -f /etc/os-release ]] || die "Impossible de détecter le système (/etc/os-release manquant)."
  . /etc/os-release
  OS_PRETTY="${PRETTY_NAME:-${ID:-inconnu} ${VERSION_ID:-}}"
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) : ;;
    *) die "Système non supporté : $OS_PRETTY. Ce script cible Debian/Ubuntu (apt-get)." ;;
  esac
  log "Système détecté : $OS_PRETTY"
}
detect_os

log "Installation des dépendances Python..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Indispensables.
apt-get install -y -qq python3 python3-venv python3-pip curl iputils-ping \
  || die "Échec d'installation des dépendances requises sur $OS_PRETTY."

# Best-effort : utiles pour compiler lxml depuis les sources si aucune roue
# précompilée n'est disponible pour cette architecture/version Python, mais
# pas indispensables sinon. Un par un pour ne jamais bloquer sur un seul nom
# de paquet absent d'une version Debian/Ubuntu donnée.
for pkg in libxml2-dev libxslt1-dev; do
  apt-get install -y -qq "$pkg" 2>/dev/null \
    || log "⚠️  $pkg indisponible sur $OS_PRETTY, ignoré (nécessaire seulement en compilation source)."
done

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

# Nginx sert TOUJOURS de façade réseau, avec ou sans WAF devant : Flask lui-même
# ne doit jamais être exposé directement (bonne pratique, même pour une app
# volontairement vulnérable). Le bloc modsecurity n'est ajouté que si le WAF
# est installé ; sinon le site reste un simple reverse-proxy, pour pouvoir
# tester dans un navigateur dès maintenant.
command -v nginx >/dev/null 2>&1 || { log "Installation de Nginx..."; apt-get install -y -qq nginx; }

WAF_ACTIVE=0
MODSEC_SNIPPET=""
if [[ -f /etc/modsecurity/main.conf ]]; then
  WAF_ACTIVE=1
  MODSEC_SNIPPET=$'    modsecurity on;\n    modsecurity_rules_file /etc/modsecurity/main.conf;\n'
fi

log "Configuration du site Nginx (port ${PORT})..."
cat > /etc/nginx/sites-available/vuln-app <<EOF
server {
    listen ${PORT};
    server_name _;

${MODSEC_SNIPPET}
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
systemctl enable --quiet nginx

log "Vérification que le site répond bien sur le port ${PORT}..."
up=0
for _ in $(seq 1 15); do
  if curl -s -o /dev/null "http://127.0.0.1:${PORT}/"; then
    up=1
    break
  fi
  sleep 1
done
if [[ "$up" != "1" ]]; then
  echo "--- nginx -T (config effective) ---" >&2
  nginx -T 2>&1 | tail -n 60 >&2 || true
  die "Nginx ne répond pas sur le port ${PORT} (voir ci-dessus)."
fi

VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$VM_IP" ]] || VM_IP="<IP_VM>"

if [[ "$WAF_ACTIVE" == "1" ]]; then
  log "Terminé. Vuln-App est protégée par le WAF : http://${VM_IP}:${PORT}/"
else
  log "Terminé. Vuln-App accessible SANS WAF pour l'instant : http://${VM_IP}:${PORT}/"
  log "Installe le WAF ('sudo ../install-waf.sh') puis relance ce script pour activer la protection."
fi
log "Voir vuln-app/README.md pour la liste des payloads de test."

#!/usr/bin/env bash
#
# install-waf.sh — installe ou met à jour un WAF Nginx + ModSecurity v3 + OWASP CRS.
# Relançable à volonté : récupère les dernières versions et ne recompile que ce qui a changé.
#
# Usage : sudo ./install-waf.sh [options]
#   --domain NAME           server_name Nginx (défaut: _)
#   --port N                port d'écoute (défaut: 80)
#   --web-root PATH         racine du site (défaut: /var/www/html)
#   --site-name NAME        nom du site Nginx (défaut: waf-test)
#   --detection-only        ModSecurity en mode détection (pas de blocage)
#   --paranoia N             niveau de paranoia OWASP CRS 1-4 (défaut: 1)
#   --crs-version TAG|latest version d'OWASP CRS à installer (défaut: latest)
#   --modsec-branch BRANCH  branche ModSecurity à suivre (défaut: v3/master)
#   --install-dir PATH      dossier des sources compilées (défaut: /opt)
#   --skip-site             ne touche pas à la config Nginx du site
#   --force-rebuild          recompile même si rien n'a changé
#   -h, --help               affiche cette aide

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (surchargeable par variables d'env ou options CLI)
# ---------------------------------------------------------------------------
SERVER_NAME="${SERVER_NAME:-_}"
LISTEN_PORT="${LISTEN_PORT:-80}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
SITE_NAME="${SITE_NAME:-waf-test}"
MODSEC_MODE="${MODSEC_MODE:-On}"          # On | DetectionOnly
PARANOIA_LEVEL="${PARANOIA_LEVEL:-1}"
CRS_VERSION="${CRS_VERSION:-latest}"
MODSEC_BRANCH="${MODSEC_BRANCH:-v3/master}"
INSTALL_DIR="${INSTALL_DIR:-/opt}"
SKIP_SITE=0
FORCE_REBUILD=0

STATE_FILE=/etc/modsecurity/.waf-install-state
LOG_FILE=/var/log/waf-install.log

# ---------------------------------------------------------------------------
# Aide / logs
# ---------------------------------------------------------------------------
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

log()  { echo -e "\e[1;34m[waf-install]\e[0m $*"; }
ok()   { echo -e "  \e[1;32m✔\e[0m $*"; }
fail() { echo -e "  \e[1;31m✘\e[0m $*"; }
die()  { echo -e "\e[1;31m[erreur]\e[0m $*" >&2; exit 1; }
trap 'die "échec à la ligne $LINENO"' ERR

# ---------------------------------------------------------------------------
# Parsing des options
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain|--server-name) SERVER_NAME="$2"; shift 2 ;;
    --port)              LISTEN_PORT="$2"; shift 2 ;;
    --web-root)           WEB_ROOT="$2"; shift 2 ;;
    --site-name)          SITE_NAME="$2"; shift 2 ;;
    --detection-only)     MODSEC_MODE="DetectionOnly"; shift ;;
    --paranoia)           PARANOIA_LEVEL="$2"; shift 2 ;;
    --crs-version)        CRS_VERSION="$2"; shift 2 ;;
    --modsec-branch)      MODSEC_BRANCH="$2"; shift 2 ;;
    --install-dir)        INSTALL_DIR="$2"; shift 2 ;;
    --skip-site)          SKIP_SITE=1; shift ;;
    --force-rebuild)      FORCE_REBUILD=1; shift ;;
    -h|--help)            usage ;;
    *) die "Option inconnue : $1 (--help pour l'aide)" ;;
  esac
done

[[ "$EUID" -eq 0 ]] || die "Lance ce script en root : sudo ./install-waf.sh"
mkdir -p /etc/modsecurity
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# Détection OS — ce script cible Debian/Ubuntu (apt). Sur autre chose, on
# s'arrête avec un message clair plutôt que d'échouer au milieu d'un apt-get.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Aide générique : clone si absent, sinon fetch + checkout de la ref demandée.
# Renvoie le commit courant dans OUT_COMMIT et CHANGED=1 si le commit a bougé.
# ---------------------------------------------------------------------------
fetch_or_update_git() {
  local dir="$1" url="$2" ref="$3" before after
  if [[ -d "$dir/.git" ]]; then
    before=$(git -C "$dir" rev-parse HEAD)
    git -C "$dir" fetch --tags --force origin >/dev/null
    git -C "$dir" checkout -q "$ref" 2>/dev/null || git -C "$dir" checkout -q "origin/$ref"
    git -C "$dir" reset -q --hard "origin/$ref" 2>/dev/null || true
  else
    log "Clonage de $url ($ref)"
    before=""
    git clone --quiet --branch "$ref" "$url" "$dir" 2>/dev/null \
      || { git clone --quiet "$url" "$dir"; git -C "$dir" checkout -q "$ref"; }
  fi
  after=$(git -C "$dir" rev-parse HEAD)
  OUT_COMMIT="$after"
  [[ "$before" != "$after" ]] && CHANGED=1 || CHANGED=0
}

get_latest_crs_tag() {
  git ls-remote --tags --refs https://github.com/coreruleset/coreruleset.git \
    | awk -F/ '{print $NF}' \
    | grep -E '^v4\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -n1
}

# ---------------------------------------------------------------------------
# Étape 1 — Dépendances système
# ---------------------------------------------------------------------------
install_dependencies() {
  detect_os
  log "Installation des dépendances système..."
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a   # évite le dialogue interactif needrestart sur Ubuntu Server
  apt-get update -qq
  apt-get upgrade -y -qq
  add-apt-repository -y universe >/dev/null 2>&1 || true
  apt-get update -qq

  # Indispensables : le script s'arrête si l'une d'elles ne s'installe pas.
  # apt-get install échoue EN BLOC si un seul paquet de la liste est introuvable
  # (dans ce cas, mieux vaut un échec net ici qu'une erreur cryptique plus tard).
  apt-get install -y -qq \
    nginx git build-essential libpcre2-dev \
    libssl-dev libtool autoconf automake \
    libxml2 libxml2-dev libcurl4-openssl-dev \
    pkg-config libyajl-dev libmaxminddb-dev wget curl \
    || die "Échec d'installation des dépendances requises sur $OS_PRETTY."

  # Best-effort : facultatives ou dont le nom/la dispo varie selon la version
  # d'Ubuntu/Debian (libgeoip-dev nécessite "universe" et est déprécié en amont,
  # libpcre3* est un reliquat PCRE1 que ModSecurity n'exige plus). Installées
  # une par une pour qu'un seul paquet manquant ne bloque jamais le reste.
  for pkg in libgeoip-dev libpcre3 libpcre3-dev; do
    if apt-get install -y -qq "$pkg" 2>/dev/null; then
      ok "$pkg installé"
    else
      log "⚠️  $pkg indisponible sur $OS_PRETTY, ignoré (fonctionnalité optionnelle)."
    fi
  done

  ok "Dépendances installées"
}

# ---------------------------------------------------------------------------
# Étape 2 — ModSecurity v3
# ---------------------------------------------------------------------------
build_modsecurity() {
  local dir="$INSTALL_DIR/ModSecurity"
  fetch_or_update_git "$dir" "https://github.com/SpiderLabs/ModSecurity" "$MODSEC_BRANCH"
  MODSEC_COMMIT="$OUT_COMMIT"
  if [[ "$CHANGED" == "1" || "$FORCE_REBUILD" == "1" || ! -f /usr/local/modsecurity/lib/libmodsecurity.so ]]; then
    log "Compilation de ModSecurity v3 (${MODSEC_COMMIT:0:8})... (5-15 min)"
    (cd "$dir" && git submodule update --init --recursive && ./build.sh && ./configure && make -j"$(nproc)" && make install)
    ok "ModSecurity compilé"
  else
    ok "ModSecurity déjà à jour, recompilation ignorée"
  fi
}

# ---------------------------------------------------------------------------
# Étape 3 — Connecteur ModSecurity-nginx
# ---------------------------------------------------------------------------
fetch_connector() {
  local dir="$INSTALL_DIR/ModSecurity-nginx"
  fetch_or_update_git "$dir" "https://github.com/SpiderLabs/ModSecurity-nginx" "master"
  CONNECTOR_COMMIT="$OUT_COMMIT"
  CONNECTOR_CHANGED="$CHANGED"
}

# ---------------------------------------------------------------------------
# Étape 4-5-6 — Module Nginx (recompilé seulement si nginx/ModSecurity/connecteur ont changé)
# ---------------------------------------------------------------------------
build_nginx_module() {
  CUR_NGINX_VERSION=$(nginx -v 2>&1 | grep -o '[0-9.]*' | head -1)
  local module_path=/usr/lib/nginx/modules/ngx_http_modsecurity_module.so

  LAST_NGINX_VERSION=""; LAST_MODSEC_COMMIT=""; LAST_CONNECTOR_COMMIT=""
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"

  if [[ "$FORCE_REBUILD" == "1" || ! -f "$module_path" \
        || "$CUR_NGINX_VERSION" != "$LAST_NGINX_VERSION" \
        || "$MODSEC_COMMIT" != "$LAST_MODSEC_COMMIT" \
        || "$CONNECTOR_COMMIT" != "$LAST_CONNECTOR_COMMIT" ]]; then

    log "Recompilation du module Nginx pour ModSecurity (Nginx $CUR_NGINX_VERSION)..."
    local args
    args=$(nginx -V 2>&1 | grep 'configure arguments:' | sed 's/configure arguments: //')

    cd "$INSTALL_DIR"
    rm -rf "nginx-${CUR_NGINX_VERSION}" "nginx-${CUR_NGINX_VERSION}.tar.gz"
    wget -q "http://nginx.org/download/nginx-${CUR_NGINX_VERSION}.tar.gz"
    tar -xzf "nginx-${CUR_NGINX_VERSION}.tar.gz"
    cd "nginx-${CUR_NGINX_VERSION}"

    eval "./configure $args --add-dynamic-module=$INSTALL_DIR/ModSecurity-nginx"
    make modules

    mkdir -p /usr/lib/nginx/modules
    cp objs/ngx_http_modsecurity_module.so /usr/lib/nginx/modules/
    ok "Module Nginx compilé et copié"
  else
    ok "Module Nginx déjà à jour, recompilation ignorée"
  fi

  echo "load_module /usr/lib/nginx/modules/ngx_http_modsecurity_module.so;" \
    > /etc/nginx/modules-enabled/50-mod-http-modsecurity.conf

  cat > "$STATE_FILE" <<EOF
LAST_NGINX_VERSION="$CUR_NGINX_VERSION"
LAST_MODSEC_COMMIT="$MODSEC_COMMIT"
LAST_CONNECTOR_COMMIT="$CONNECTOR_COMMIT"
EOF
}

# ---------------------------------------------------------------------------
# Étape 7 — Configuration ModSecurity
# ---------------------------------------------------------------------------
configure_modsecurity() {
  log "Configuration de ModSecurity (mode: $MODSEC_MODE)..."
  [[ -f /etc/modsecurity/modsecurity.conf ]] \
    || cp "$INSTALL_DIR/ModSecurity/modsecurity.conf-recommended" /etc/modsecurity/modsecurity.conf
  cp -f "$INSTALL_DIR/ModSecurity/unicode.mapping" /etc/modsecurity/

  sed -i "s/SecRuleEngine .*/SecRuleEngine ${MODSEC_MODE}/" /etc/modsecurity/modsecurity.conf
  sed -i 's#^SecAuditLog .*#SecAuditLog /var/log/modsec_audit.log#' /etc/modsecurity/modsecurity.conf
  ok "modsecurity.conf configuré"
}

# ---------------------------------------------------------------------------
# Étape 8 — Règles OWASP CRS
# ---------------------------------------------------------------------------
install_crs() {
  local dir=/etc/modsecurity/coreruleset
  local ref="$CRS_VERSION"
  if [[ "$ref" == "latest" ]]; then
    ref=$(get_latest_crs_tag)
    log "Dernière version OWASP CRS détectée : $ref"
  fi
  fetch_or_update_git "$dir" "https://github.com/coreruleset/coreruleset.git" "$ref"
  [[ -f "$dir/crs-setup.conf" ]] || cp "$dir/crs-setup.conf.example" "$dir/crs-setup.conf"
  ok "OWASP CRS $ref installé"

  # Personnalisations : ce fichier est régénéré à chaque run (niveau de paranoia).
  cat > /etc/modsecurity/crs-custom.conf <<EOF
# Généré par install-waf.sh — écrasé à chaque exécution, ne pas éditer à la main.
# Pour des règles personnelles permanentes, utilise /etc/modsecurity/local-custom.conf
SecAction \\
 "id:900130,\\
  phase:1,\\
  pass,\\
  t:none,\\
  nolog,\\
  setvar:tx.blocking_paranoia_level=${PARANOIA_LEVEL}"
SecAction \\
 "id:900131,\\
  phase:1,\\
  pass,\\
  t:none,\\
  nolog,\\
  setvar:tx.detection_paranoia_level=${PARANOIA_LEVEL}"
EOF

  # Jamais écrasé : emplacement dédié aux règles/exclusions perso de l'utilisateur.
  [[ -f /etc/modsecurity/local-custom.conf ]] || cat > /etc/modsecurity/local-custom.conf <<'EOF'
# Jamais modifié par install-waf.sh : mets ici tes règles ou exclusions personnelles.
EOF
}

write_main_conf() {
  cat > /etc/modsecurity/main.conf <<'EOF'
Include /etc/modsecurity/modsecurity.conf
Include /etc/modsecurity/coreruleset/crs-setup.conf
Include /etc/modsecurity/crs-custom.conf
Include /etc/modsecurity/coreruleset/rules/*.conf
Include /etc/modsecurity/local-custom.conf
EOF
}

# ---------------------------------------------------------------------------
# Étape 9 — Site Nginx
# ---------------------------------------------------------------------------
write_nginx_site() {
  if [[ "$SKIP_SITE" == "1" ]]; then
    log "Config du site Nginx laissée telle quelle (--skip-site)"
    return
  fi
  mkdir -p "$WEB_ROOT"
  [[ -f "$WEB_ROOT/index.html" ]] || echo "<h1>Site protege par WAF</h1>" > "$WEB_ROOT/index.html"

  cat > "/etc/nginx/sites-available/$SITE_NAME" <<EOF
server {
    listen ${LISTEN_PORT};
    server_name ${SERVER_NAME};

    modsecurity on;
    modsecurity_rules_file /etc/modsecurity/main.conf;

    root ${WEB_ROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  ln -sf "/etc/nginx/sites-available/$SITE_NAME" "/etc/nginx/sites-enabled/$SITE_NAME"
  rm -f /etc/nginx/sites-enabled/default
  ok "Site Nginx '$SITE_NAME' configuré (port $LISTEN_PORT, root $WEB_ROOT)"
}

# ---------------------------------------------------------------------------
# Étape 10 — Rechargement + tests
# ---------------------------------------------------------------------------
reload_nginx() {
  nginx -t
  systemctl restart nginx
  systemctl enable --quiet nginx
  ok "Nginx redémarré"
}

self_test() {
  log "Tests de vérification..."
  local base="http://127.0.0.1:${LISTEN_PORT}"
  check() {
    local desc="$1" url="$2" expect="$3" code
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || echo "000")
    if [[ "$code" == "$expect" ]]; then ok "$desc ($code)"; else fail "$desc (attendu $expect, reçu $code)"; fi
  }
  check "Trafic normal"  "$base/"                                        200
  check "SQL Injection"  "$base/?id=1%27%20OR%20%271%27%3D%271"          403
  check "XSS"            "$base/?q=<script>alert(1)</script>"            403
  check "Path Traversal" "$base/?file=../../etc/passwd"                  403
}

# ---------------------------------------------------------------------------
main() {
  log "Démarrage — WAF Nginx + ModSecurity v3 + OWASP CRS"
  install_dependencies
  build_modsecurity
  fetch_connector
  build_nginx_module
  configure_modsecurity
  install_crs
  write_main_conf
  write_nginx_site
  reload_nginx
  [[ "$SKIP_SITE" == "1" ]] || self_test
  log "Terminé. Log complet : $LOG_FILE"
}

main

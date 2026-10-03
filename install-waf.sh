#!/usr/bin/env bash
#
# install-waf.sh — installe ou met à jour un WAF Nginx + ModSecurity v3 + OWASP CRS.
# Relançable à volonté : récupère les dernières versions et ne recompile que ce qui a changé.
#
# USAGE_BEGIN
# Usage : sudo ./install-waf.sh [options]
#   --domain NAME           server_name Nginx (défaut: _)
#   --port N                port d'écoute (défaut: 80)
#   --web-root PATH         racine du site (défaut: /var/www/html)
#   --site-name NAME        nom du site Nginx (défaut: waf-test)
#   --detection-only        ModSecurity en mode détection (pas de blocage)
#   --paranoia N            niveau de paranoia OWASP CRS 1-4 (défaut: 1)
#   --crs-version TAG|latest version d'OWASP CRS à installer (défaut: latest)
#   --modsec-branch BRANCH  branche ModSecurity à suivre (défaut: v3/master)
#   --install-dir PATH      dossier des sources compilées (défaut: /opt)
#   --allow-ip IP[/CIDR]    IP de confiance qui ne passe pas par le WAF (répétable)
#   --skip-site             ne touche pas à la config Nginx du site
#   --force-rebuild         recompile même si rien n'a changé
#   --upgrade-system        fait aussi 'apt-get upgrade' (par défaut : non)
#   -h, --help              affiche cette aide
# USAGE_END
#
# Codes de sortie : 0 = OK, 1 = erreur (rien de cassé : la config précédente est restaurée)

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
UPGRADE_SYSTEM=0
ALLOW_IPS=()

STATE_FILE=/etc/modsecurity/.waf-install-state
LOG_FILE=/var/log/waf-install.log
AUDIT_LOG=/var/log/modsec_audit.log
BACKUP_DIR="/root/waf-backup-$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# Aide / logs
# ---------------------------------------------------------------------------
usage() { awk '/USAGE_BEGIN/{f=1;next} /USAGE_END/{f=0} f' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

log()  { echo -e "\e[1;34m[waf-install]\e[0m $*"; }
ok()   { echo -e "  \e[1;32m✔\e[0m $*"; }
fail() { echo -e "  \e[1;31m✘\e[0m $*"; }
die()  { echo -e "\e[1;31m[erreur]\e[0m $*" >&2; exit 1; }
trap 'die "échec à la ligne $LINENO (voir $LOG_FILE)"' ERR

# ---------------------------------------------------------------------------
# Parsing des options
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain|--server-name) SERVER_NAME="${2:-}"; shift 2 ;;
    --port)                 LISTEN_PORT="${2:-}"; shift 2 ;;
    --web-root)             WEB_ROOT="${2:-}"; shift 2 ;;
    --site-name)            SITE_NAME="${2:-}"; shift 2 ;;
    --detection-only)       MODSEC_MODE="DetectionOnly"; shift ;;
    --paranoia)             PARANOIA_LEVEL="${2:-}"; shift 2 ;;
    --crs-version)          CRS_VERSION="${2:-}"; shift 2 ;;
    --modsec-branch)        MODSEC_BRANCH="${2:-}"; shift 2 ;;
    --install-dir)          INSTALL_DIR="${2:-}"; shift 2 ;;
    --allow-ip)             ALLOW_IPS+=("${2:-}"); shift 2 ;;
    --skip-site)            SKIP_SITE=1; shift ;;
    --force-rebuild)        FORCE_REBUILD=1; shift ;;
    --upgrade-system)       UPGRADE_SYSTEM=1; shift ;;
    -h|--help)              usage ;;
    *) die "Option inconnue : $1 (--help pour l'aide)" ;;
  esac
done

[[ "$EUID" -eq 0 ]] || die "Lance ce script en root : sudo ./install-waf.sh"
mkdir -p /etc/modsecurity
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# Validation des options (avant toute modification du système)
# ---------------------------------------------------------------------------
valid_ipv4_or_cidr() {
  local addr="$1" ip prefix octet
  [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
  ip="${addr%%/*}"
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do (( octet <= 255 )) || return 1; done
  if [[ "$addr" == */* ]]; then
    prefix="${addr##*/}"; (( prefix <= 32 )) || return 1
  fi
  return 0
}

validate_args() {
  [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && (( LISTEN_PORT >= 1 && LISTEN_PORT <= 65535 )) \
    || die "--port invalide : '$LISTEN_PORT' (1-65535)"
  [[ "$PARANOIA_LEVEL" =~ ^[1-4]$ ]] || die "--paranoia doit être entre 1 et 4 (reçu : '$PARANOIA_LEVEL')"
  [[ "$SERVER_NAME" == "_" || "$SERVER_NAME" =~ ^[A-Za-z0-9.*_-]+$ ]] \
    || die "--domain invalide : '$SERVER_NAME'"
  [[ "$SITE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "--site-name invalide : '$SITE_NAME'"
  [[ "$WEB_ROOT" == /* ]] || die "--web-root doit être un chemin absolu (reçu : '$WEB_ROOT')"
  [[ "$CRS_VERSION" == "latest" || "$CRS_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "--crs-version invalide : '$CRS_VERSION'"
  for ip in ${ALLOW_IPS[@]+"${ALLOW_IPS[@]}"}; do
    valid_ipv4_or_cidr "$ip" || die "--allow-ip invalide : '$ip' (ex. 203.0.113.5 ou 10.0.0.0/24)"
  done
}

# ---------------------------------------------------------------------------
# Vérifications AVANT modification : le port doit être libre, sans écraser un autre site
# ---------------------------------------------------------------------------
preflight() {
  log "Vérifications préalables..."

  if command -v ss >/dev/null 2>&1; then
    local listeners
    listeners=$(ss -ltnpH "sport = :${LISTEN_PORT}" 2>/dev/null || true)
    if [[ -n "$listeners" ]] && ! grep -q 'nginx' <<< "$listeners"; then
      die "Le port $LISTEN_PORT est déjà utilisé par un autre service :
$listeners
Choisis un autre port avec --port, ou arrête ce service."
    fi
  fi

  # Un autre site Nginx écoute déjà sur ce port : on refuse plutôt que de le remplacer.
  local f
  for f in /etc/nginx/sites-enabled/*; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "$SITE_NAME" ]] && continue
    if grep -qE "^[[:space:]]*listen[[:space:]]+(\[::\]:)?${LISTEN_PORT}([[:space:];]|$)" "$f"; then
      die "Le site Nginx '$f' écoute déjà sur le port $LISTEN_PORT. Utilise --port ou --site-name différent."
    fi
  done
  ok "Port $LISTEN_PORT disponible"
}

# ---------------------------------------------------------------------------
# Détection OS — ce script cible Debian/Ubuntu (apt).
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
  if [[ "$before" != "$after" ]]; then CHANGED=1; else CHANGED=0; fi
}

get_latest_crs_tag() {
  { git ls-remote --tags --refs https://github.com/coreruleset/coreruleset.git || true; } \
    | awk -F/ '{print $NF}' \
    | grep -E '^v4\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -n1 || true
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
  if (( UPGRADE_SYSTEM )); then
    log "Mise à jour complète du système (--upgrade-system)..."
    apt-get upgrade -y -qq
  else
    log "Pas de mise à jour générale (option --upgrade-system pour l'activer)."
  fi
  add-apt-repository -y universe >/dev/null 2>&1 || true
  apt-get update -qq

  # Indispensables : le script s'arrête si l'une d'elles ne s'installe pas.
  apt-get install -y -qq \
    nginx git build-essential libpcre2-dev \
    libssl-dev libtool autoconf automake \
    libxml2 libxml2-dev libcurl4-openssl-dev \
    pkg-config libyajl-dev libmaxminddb-dev wget curl \
    || die "Échec d'installation des dépendances requises sur $OS_PRETTY."

  # Best-effort : facultatives ou dont le nom/la dispo varie selon la version.
  local pkg
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
}

# ---------------------------------------------------------------------------
# Étape 4-5-6 — Module Nginx (recompilé si Nginx, ModSecurity ou le connecteur changent)
# ---------------------------------------------------------------------------
build_nginx_module() {
  CUR_NGINX_VERSION=$(nginx -v 2>&1 | grep -o '[0-9.]*' | head -1)
  # Version du PAQUET (change aussi lors d'un correctif de sécurité, même si "1.24.0" reste affiché)
  CUR_NGINX_PKG=$(dpkg-query -W -f='${Version}' nginx 2>/dev/null || echo "?")
  # Arguments de compilation : tout changement de build impose une recompilation du module
  CUR_NGINX_ARGS=$(nginx -V 2>&1 | md5sum | cut -d' ' -f1)
  local module_path=/usr/lib/nginx/modules/ngx_http_modsecurity_module.so

  LAST_NGINX_PKG=""; LAST_NGINX_ARGS=""; LAST_MODSEC_COMMIT=""; LAST_CONNECTOR_COMMIT=""
  if [[ -f "$STATE_FILE" ]]; then source "$STATE_FILE"; fi

  if [[ "$FORCE_REBUILD" == "1" || ! -f "$module_path" \
        || "$CUR_NGINX_PKG" != "$LAST_NGINX_PKG" \
        || "$CUR_NGINX_ARGS" != "$LAST_NGINX_ARGS" \
        || "$MODSEC_COMMIT" != "$LAST_MODSEC_COMMIT" \
        || "$CONNECTOR_COMMIT" != "$LAST_CONNECTOR_COMMIT" ]]; then

    log "Recompilation du module Nginx pour ModSecurity (Nginx $CUR_NGINX_PKG)..."
    local args
    args=$(nginx -V 2>&1 | grep 'configure arguments:' | sed 's/configure arguments: //')
    # Retire les modules tiers empaquetés par Debian (chemins relatifs à leur arbre de build)
    args=$(echo "$args" | sed -E 's/--add-dynamic-module=[^ ]+//g')

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
LAST_NGINX_PKG="$CUR_NGINX_PKG"
LAST_NGINX_ARGS="$CUR_NGINX_ARGS"
LAST_MODSEC_COMMIT="$MODSEC_COMMIT"
LAST_CONNECTOR_COMMIT="$CONNECTOR_COMMIT"
EOF
}

# ---------------------------------------------------------------------------
# Étape 7 — Configuration ModSecurity
# ---------------------------------------------------------------------------
configure_modsecurity() {
  log "Configuration de ModSecurity (mode: $MODSEC_MODE)..."
  if [[ ! -f /etc/modsecurity/modsecurity.conf ]]; then
    cp "$INSTALL_DIR/ModSecurity/modsecurity.conf-recommended" /etc/modsecurity/modsecurity.conf
  fi
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
    [[ -n "$ref" ]] || die "Impossible de lire la dernière version d'OWASP CRS (réseau coupé ?). Utilise --crs-version vX.Y.Z."
    log "Dernière version OWASP CRS détectée : $ref"
  fi
  fetch_or_update_git "$dir" "https://github.com/coreruleset/coreruleset.git" "$ref"
  if [[ ! -f "$dir/crs-setup.conf" ]]; then cp "$dir/crs-setup.conf.example" "$dir/crs-setup.conf"; fi
  ok "OWASP CRS $ref installé"

  # Régénéré à chaque run (niveau de paranoia)
  cat > /etc/modsecurity/crs-custom.conf <<EOF
# Généré par install-waf.sh — écrasé à chaque exécution, ne pas éditer à la main.
# Pour des règles personnelles : local-before.conf (avant les règles) ou local-after.conf (après).
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
}

# Allowlist : IPs de confiance qui ne passent pas par le WAF (option --allow-ip).
# Régénérée à chaque run. Chargée AVANT les règles, sinon elle n'a aucun effet.
write_allowlist() {
  if (( ${#ALLOW_IPS[@]} == 0 )); then
    cat > /etc/modsecurity/allowlist.conf <<'EOF'
# Aucune IP de confiance (option --allow-ip). Fichier régénéré à chaque run.
EOF
    return
  fi
  local list
  list=$(IFS=,; echo "${ALLOW_IPS[*]}")
  cat > /etc/modsecurity/allowlist.conf <<EOF
# Généré par install-waf.sh (option --allow-ip) — régénéré à chaque run.
# ⚠️ Le trafic de ces IPs n'est PAS filtré par le WAF. Réserve-le à ton poste d'admin.
SecRule REMOTE_ADDR "@ipMatch ${list}" \\
 "id:1000100,\\
  phase:1,\\
  pass,\\
  nolog,\\
  ctl:ruleEngine=Off"
EOF
  ok "Allowlist : ${list}"
}

# Fichiers perso, jamais écrasés par le script
ensure_local_files() {
  if [[ ! -f /etc/modsecurity/local-before.conf ]]; then
    cat > /etc/modsecurity/local-before.conf <<'EOF'
# Jamais modifié par install-waf.sh. Chargé AVANT les règles OWASP.
# Ici : ctl:ruleRemoveById / ctl:ruleEngine=Off ciblés, exclusions par application.
EOF
  fi
  if [[ ! -f /etc/modsecurity/local-after.conf ]]; then
    if [[ -f /etc/modsecurity/local-custom.conf ]]; then
      cp /etc/modsecurity/local-custom.conf /etc/modsecurity/local-after.conf
      log "Ancien local-custom.conf repris dans local-after.conf (il restait chargé après les règles)."
    else
      cat > /etc/modsecurity/local-after.conf <<'EOF'
# Jamais modifié par install-waf.sh. Chargé APRÈS les règles OWASP.
# Ici : SecRuleRemoveById pour désactiver une règle précise.
EOF
    fi
  fi
}

write_main_conf() {
  # Ordre important : exclusions et allowlist AVANT les règles, SecRuleRemoveById APRÈS.
  cat > /etc/modsecurity/main.conf <<'EOF'
Include /etc/modsecurity/modsecurity.conf
Include /etc/modsecurity/coreruleset/crs-setup.conf
Include /etc/modsecurity/allowlist.conf
Include /etc/modsecurity/crs-custom.conf
Include /etc/modsecurity/local-before.conf
Include /etc/modsecurity/coreruleset/rules/*.conf
Include /etc/modsecurity/local-after.conf
EOF
}

# ---------------------------------------------------------------------------
# Étape 9 — Site Nginx (sauvegarde + retour arrière possible)
# ---------------------------------------------------------------------------
SITE_FILE=""; SITE_BACKUP=""; SITE_EXISTED=0

write_nginx_site() {
  if [[ "$SKIP_SITE" == "1" ]]; then
    log "Config du site Nginx laissée telle quelle (--skip-site)"
    return
  fi
  mkdir -p "$WEB_ROOT" "$BACKUP_DIR"
  if [[ ! -f "$WEB_ROOT/index.html" ]]; then
    echo "<h1>Site protege par WAF</h1>" > "$WEB_ROOT/index.html"
  fi

  SITE_FILE="/etc/nginx/sites-available/$SITE_NAME"
  if [[ -f "$SITE_FILE" ]]; then
    SITE_EXISTED=1
    SITE_BACKUP="$BACKUP_DIR/$SITE_NAME.before"
    cp -a "$SITE_FILE" "$SITE_BACKUP"
  fi

  cat > "$SITE_FILE" <<EOF
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
  ln -sf "$SITE_FILE" "/etc/nginx/sites-enabled/$SITE_NAME"

  # Le site par défaut d'Ubuntu n'est PAS supprimé : seul son lien est retiré (réversible).
  if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    ok "Site par défaut désactivé (sites-available/default conservé, réactivable avec ln -s)"
  elif [[ -e /etc/nginx/sites-enabled/default ]]; then
    mv /etc/nginx/sites-enabled/default "$BACKUP_DIR/default.enabled"
    ok "Site par défaut mis de côté dans $BACKUP_DIR"
  fi
  ok "Site Nginx '$SITE_NAME' configuré (port $LISTEN_PORT, root $WEB_ROOT)"
}

# Restaure le site tel qu'il était avant ce run
rollback_site() {
  [[ -n "$SITE_FILE" ]] || return 0
  if (( SITE_EXISTED )); then
    cp -a "$SITE_BACKUP" "$SITE_FILE"
  else
    rm -f "$SITE_FILE" "/etc/nginx/sites-enabled/$SITE_NAME"
  fi
}

# ---------------------------------------------------------------------------
# Étape 10 — Vérification de la config puis redémarrage (retour arrière si refusée)
# ---------------------------------------------------------------------------
reload_nginx() {
  if ! nginx -t; then
    rollback_site
    die "Configuration Nginx refusée. Ancien site restauré (nginx n'a pas été redémarré)."
  fi
  systemctl restart nginx
  systemctl enable --quiet nginx
  ok "Nginx redémarré"
}

audit_lines() {
  if [[ -f "$AUDIT_LOG" ]]; then wc -l < "$AUDIT_LOG"; else echo 0; fi
}

# Renvoie 1 si un test échoue. En mode détection, une attaque doit laisser une trace
# dans le log d'audit au lieu d'être bloquée.
self_test() {
  log "Tests de vérification (mode : $MODSEC_MODE)..."
  local base="http://127.0.0.1:${LISTEN_PORT}" failures=0 code
  check() {
    local desc="$1" url="$2" expect="$3"
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url") || true
    [[ -n "$code" ]] || code="000"
    if [[ "$code" == "$expect" ]]; then
      ok "$desc ($code)"
    else
      fail "$desc (attendu $expect, reçu $code)"
      failures=$((failures + 1))
    fi
  }

  check "Trafic normal" "$base/" 200

  if [[ "$MODSEC_MODE" == "On" ]]; then
    check "SQL Injection"  "$base/?id=1%27%20OR%20%271%27%3D%271" 403
    check "XSS"            "$base/?q=<script>alert(1)</script>"    403
    check "Path Traversal" "$base/?file=../../etc/passwd"          403
  else
    local before after
    before=$(audit_lines)
    check "SQL Injection (détection)"  "$base/?id=1%27%20OR%20%271%27%3D%271" 200
    check "XSS (détection)"            "$base/?q=<script>alert(1)</script>"    200
    check "Path Traversal (détection)" "$base/?file=../../etc/passwd"          200
    after=$(audit_lines)
    if (( after > before )); then
      ok "Attaques journalisées dans $AUDIT_LOG (+$((after - before)))"
    else
      fail "Aucune attaque journalisée dans $AUDIT_LOG"
      failures=$((failures + 1))
    fi
  fi

  (( failures == 0 ))
}

# ---------------------------------------------------------------------------
main() {
  log "Démarrage — WAF Nginx + ModSecurity v3 + OWASP CRS"
  validate_args
  preflight
  install_dependencies
  build_modsecurity
  fetch_connector
  build_nginx_module
  configure_modsecurity
  install_crs
  write_allowlist
  ensure_local_files
  write_main_conf
  write_nginx_site
  reload_nginx

  if [[ "$SKIP_SITE" != "1" ]]; then
    if ! self_test; then
      die "Des tests ont échoué : le WAF ne se comporte pas comme prévu. Voir ci-dessus et $LOG_FILE."
    fi
  fi

  # Si vuln-app a été déployée AVANT le WAF, son site n'est pas protégé : on le signale.
  if [[ -f /etc/nginx/sites-available/vuln-app ]] && ! grep -q "modsecurity on" /etc/nginx/sites-available/vuln-app; then
    log "ℹ️  Vuln-App détectée sans protection WAF — relance 'sudo vuln-app/deploy-vuln-app.sh' pour l'activer dessus."
  fi

  log "Terminé. Log complet : $LOG_FILE"
  log "Sauvegardes éventuelles : $BACKUP_DIR"
}

main

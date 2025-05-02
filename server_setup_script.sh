#!/usr/bin/env bash
###############################################################################
#  Laravel Server Bootstrap – Ubuntu 24.04
#  Installs:  Caddy • PHP • Node • PostgreSQL • Cockpit • phpPgAdmin • Chrome
#  Creates:   /var/www/<slug>/{artifacts,releases,current,bootstrap,storage}
#  Usage:     sudo ./setup.sh         # install + reboot
#             sudo ./setup.sh --dry-run  # prompts only, no changes
###############################################################################
set -euo pipefail

############## Globals ########################################################
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1 && echo '*** DRY-RUN MODE ***'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec 3>&1 4>&2      # keep raw TTY copies for whiptail

############## Helper wrappers ################################################
run()       { ((DRY_RUN)) && echo "DRY: $*" || eval "$*"; }
real()      { eval "$*"; }               # always executed (even dry-run)
ensure_file(){ [[ -f $1 ]] && return; ((DRY_RUN)) && echo "DRY: touch $1" && return
               mkdir -p "$(dirname "$1")"; touch "$1"; }
step()      { local pct=$1 msg=$2; ((DRY_RUN)) && echo "[$pct%] $msg" ||
              whiptail --gauge "$msg…" 6 60 "$pct" <<<""; }

############## Sanity check ###################################################
(( EUID != 0 )) && { echo "Run with sudo or as root"; exit 1; }

############## Minimal bootstrap (runs even in dry-run) #######################
real apt-get update -qq
real apt-get install -y whiptail software-properties-common curl wget gnupg lsb-release ca-certificates

# Ondřej PHP PPA
real add-apt-repository -y ppa:ondrej/php

# --- PGDG repository (Ubuntu 24.04) ---
# real curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
#     | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
# echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
# http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
# > /etc/apt/sources.list.d/pgdg.list

# --- PostgreSQL PGDG repository (Ubuntu 24.04) ------------------------------
# 1) binary key into /usr/share/keyrings
real curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg      # ← official name :contentReference[oaicite:0]{index=0}
# 2) repo line that points to the key
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
> /etc/apt/sources.list.d/pgdg.list


# --- Caddy stable repo ------------------------------------------------------
# real curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
#     | gpg --dearmor -o /usr/share/keyrings/caddy.gpg
# echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] \
# https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
# > /etc/apt/sources.list.d/caddy-stable.list


# --- Caddy ---
# remove obsolete list (it points at …/debian noble)
rm -f /etc/apt/sources.list.d/caddy.list 2>/dev/null

# --- Caddy stable repo ------------------------------------------------------
real curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
     | gpg --dearmor -o /usr/share/keyrings/caddy.gpg
echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] \
https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
> /etc/apt/sources.list.d/caddy-stable.list      # ← any-version is the only path Cloudsmith hosts :contentReference[oaicite:2]{index=2}


real apt-get update -qq
real apt-get install -y whiptail software-properties-common curl wget gnupg lsb-release ca-certificates

###############################################################################
############################  INTERACTIVE PROMPTS  ############################
###############################################################################
NEW_USER=$(whiptail --inputbox "New SSH user (default: deployer)" 8 60 deployer 3>&1 1>&2 2>&3)

ACME_EMAIL=$(whiptail --inputbox "ACME email for Let's Encrypt\nEx: [email protected]" 9 60 3>&1 1>&2 2>&3)

BASE_DOMAIN=$(whiptail --inputbox "Base domain (include www)\nEx: www.example.com" 9 60 3>&1 1>&2 2>&3)
DOMAIN_SLUG=$(basename "${BASE_DOMAIN#www.}" | cut -d'.' -f1)

## --- PHP VERSION + EXTENSIONS ---------------------------------------------
while true; do
    PHP_VERSION=$(whiptail --title "PHP Version" --menu "Choose PHP version:" 15 50 5 \
        8.0 "" 8.1 "" 8.2 "(LTS)" 8.3 "(latest)" 3>&1 1>&2 2>&3) || exit 1
    [[ -n $PHP_VERSION ]] && break
done

# dynamic module list from PPA + Ubuntu pool
mapfile -t ALL_EXT < <(
  { apt-cache pkgnames "php$PHP_VERSION-" && apt-cache pkgnames "php-"; } 2>/dev/null |
  grep -Ev "php($PHP_VERSION|-common|-cli|-fpm)" |
  sed -E "s/^php$PHP_VERSION-//;s/^php-//" | sort -u
)
PRESEL=(bcmath curl mbstring pgsql xml zip intl gd imagick soap sqlite3 bz2 readline opcache dev)
EXT_DIALOG=(); for e in "${ALL_EXT[@]}"; do
  [[ " ${PRESEL[*]} " =~ " $e " ]] && DEF=ON || DEF=OFF
  EXT_DIALOG+=("$e" "" "$DEF")
done
PHP_EXT_SELECTED=$(whiptail --checklist "Select PHP extensions:" 20 70 12 \
    "${EXT_DIALOG[@]}" 3>&1 1>&2 2>&3)
PHP_EXT_SELECTED=${PHP_EXT_SELECTED//\"/}

## --- DB / MISC -------------------------------------------------------------
DB_USER=$(whiptail --inputbox "PostgreSQL role (CREATEDB)" 8 60 3>&1 1>&2 2>&3)
DB_PASS=$(whiptail --passwordbox "Password for role $DB_USER" 8 60 3>&1 1>&2 2>&3)
UFW_EXTRA=$(whiptail --inputbox "Extra ports (comma-sep) or blank" 8 60 3>&1 1>&2 2>&3)
GH_EMAIL=$(whiptail --inputbox "Email tag for GitHub Actions SSH key" 8 60 3>&1 1>&2 2>&3)

## --- Confirmation ----------------------------------------------------------
whiptail --yesno "Summary\n────────\nUser: $NEW_USER\nDomain: $BASE_DOMAIN\nPHP: $PHP_VERSION\nExt: $PHP_EXT_SELECTED\nPostgres user: $DB_USER\nExtra ports: ${UFW_EXTRA:-none}\n\nProceed?" 15 60 || exit 0

##############  Start full logging  ##########################################
LOGFILE="$SCRIPT_DIR/bootstrap.log"
exec 1> >(tee -a "$LOGFILE") 2>&1

###############################################################################
##############################  MAIN INSTALL  #################################
###############################################################################
step 5  "Creating user $NEW_USER and SSH"
id "$NEW_USER" &>/dev/null || run adduser --disabled-password --gecos '' "$NEW_USER"
run usermod -aG sudo "$NEW_USER"
run mkdir -p "/home/$NEW_USER/.ssh"
run chmod 700 "/home/$NEW_USER/.ssh"
[[ -f /root/.ssh/authorized_keys ]] && run cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/"
run chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
run chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"

step 10 "Installing Caddy"
run apt-get install -y caddy
ensure_file /etc/caddy/Caddyfile
cat >/etc/caddy/Caddyfile <<EOF
{
    email $ACME_EMAIL
}
EOF

step 20 "Installing PHP $PHP_VERSION + modules"
PHP_PKGS="php$PHP_VERSION php$PHP_VERSION-fpm php$PHP_VERSION-cli php$PHP_VERSION-common"
for ext in $PHP_EXT_SELECTED; do
    if apt-cache show "php$PHP_VERSION-$ext" &>/dev/null; then
        PHP_PKGS+=" php$PHP_VERSION-$ext"
    else
        PHP_PKGS+=" php-$ext"
    fi
done
run apt-get install -y $PHP_PKGS
run systemctl enable --now "php$PHP_VERSION-fpm"

step 25 "Composer"
run curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

step 30 "Node (NVM LTS)"
if (( !DRY_RUN )); then
  sudo -u "$NEW_USER" bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
  sudo -u "$NEW_USER" bash -c "source ~/.nvm/nvm.sh && nvm install --lts && nvm alias default node"
  NODE_BIN=$(sudo -u "$NEW_USER" bash -c "source ~/.nvm/nvm.sh && command -v node")
  run ln -sf "$NODE_BIN" /usr/local/bin/node
  run ln -sf "${NODE_BIN%/node}/npm" /usr/local/bin/npm
fi

step 35 "PostgreSQL 17"
run apt-get install -y postgresql-17 postgresql-client-17
run systemctl enable --now postgresql@17-main
(( !DRY_RUN )) && sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 ||
    sudo -u postgres psql -c "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASS' NOSUPERUSER CREATEDB;"

step 40 "Cockpit + phpPgAdmin"
run apt-get install -y cockpit phppgadmin
run systemctl enable --now cockpit.socket

step 45 "Chrome (.deb)"
if (( !DRY_RUN )); then
  wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y /tmp/chrome.deb || apt-get -f install -y
  rm /tmp/chrome.deb
fi

step 50 "Web skeleton /var/www/$DOMAIN_SLUG"
BASE_PATH="/var/www/$DOMAIN_SLUG"
run mkdir -p "$BASE_PATH"/{artifacts,releases,bootstrap,storage}
run ln -sfn "$BASE_PATH/releases" "$BASE_PATH/current"
run chown -R "$NEW_USER:www-data" "$BASE_PATH"
run find "$BASE_PATH" -type d -exec chmod 2775 {} +
run find "$BASE_PATH" -type f -exec chmod 664 {} +

step 55 "Caddy site blocks"
cat >>/etc/caddy/Caddyfile <<EOF

# Laravel
$BASE_DOMAIN, ${BASE_DOMAIN#www.} {
    root * $BASE_PATH/current/public
    php_fastcgi unix//run/php/php$PHP_VERSION-fpm.sock
    encode zstd gzip
    file_server
}

# phpPgAdmin
pg.$BASE_DOMAIN {
    root * /usr/share/phppgadmin
    php_fastcgi unix//run/php/php$PHP_VERSION-fpm.sock
    file_server
}

# Cockpit
cockpit.$BASE_DOMAIN {
    reverse_proxy 127.0.0.1:9090
}
EOF
run systemctl reload caddy

step 60 "UFW firewall"
run apt-get install -y ufw
run ufw --force reset
for p in 22 80 443 9090; do run ufw allow "$p"; done
IFS=',' read -ra EXTRA <<<"$UFW_EXTRA"; for p in "${EXTRA[@]}"; do [[ -n $p ]] && run ufw allow "${p// /}"; done
run ufw --force enable

step 65 "GitHub Actions SSH key"
if (( !DRY_RUN )); then
  sudo -u "$NEW_USER" ssh-keygen -t ed25519 -q -N "" -C "$GH_EMAIL" -f "/home/$NEW_USER/.ssh/gh_actions_key"
  cat "/home/$NEW_USER/.ssh/gh_actions_key.pub" >>"/home/$NEW_USER/.ssh/authorized_keys"
  echo "=== GitHub Actions private key ==="
  cat "/home/$NEW_USER/.ssh/gh_actions_key"
fi

step 70 "Zsh + Oh-My-Zsh"
run apt-get install -y zsh git
if (( !DRY_RUN )); then
  OMZ=/opt/oh-my-zsh; [[ -d $OMZ ]] || git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git $OMZ
  for u in root "$NEW_USER"; do
    HOME_DIR=$(eval echo "~$u")
    cp -f $OMZ/templates/zshrc.zsh-template "$HOME_DIR/.zshrc"
    chown "$u:$u" "$HOME_DIR/.zshrc"
    chsh -s /usr/bin/zsh "$u"
  done
fi

step 75 "Cleanup"
run apt-get -y autoremove
run apt-get clean

echo "------------ COMPLETE ------------"
echo "Log saved to $LOGFILE"
(( DRY_RUN )) && { echo "Dry-run: no reboot."; exit 0; }
echo "Rebooting in 20 s… Ctrl-C to abort."
sleep 20 && reboot

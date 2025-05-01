#!/usr/bin/env bash
###############################################################################
#  Laravel Server Bootstrap – Ubuntu 24.04
#  Installs: Caddy + PHP + Node + PostgreSQL + Cockpit + phpPgAdmin + Chrome
#  Sets up:  /var/www/<domain-slug> skeleton, permissions, UFW, Oh-My-Zsh
#  Usage:    sudo ./setup.sh            # real run
#            sudo ./setup.sh --dry-run  # simulate only
###############################################################################
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1 && echo "*** DRY-RUN MODE ***"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# exec > >(tee -a "$LOGFILE") 2>&1
ensure_file() {
  local file=$1
  [[ -f $file ]] && return
  (( DRY_RUN )) && { echo "DRY: would create $file"; return; }
  mkdir -p "$(dirname "$file")"
  touch "$file"
}


# before the first whiptail prompt
exec 3>&1 4>&2              # save TTY handles

### Helper – run or echo ######################################################
run() { if ((DRY_RUN)); then echo "DRY: $*"; else eval "$*"; fi; }

### Helper – gauge update #####################################################
step() {
    local pct="$1" msg="$2"
    ((DRY_RUN)) && echo "[${pct}%] $msg" ||
        whiptail --gauge "$msg..." 6 60 "$pct" <<<""
}

cache_run() { eval "$@"; }

cache_run apt-get install -y software-properties-common curl wget gnupg lsb-release
cache_run add-apt-repository -y ppa:ondrej/php
cache_run apt-get update -y


### 0. Root check #############################################################
if ((EUID != 0)); then
    echo "Run as root (use sudo)"
    exit 1
fi

# PGDG
run "wget -qO /usr/share/keyrings/pgdg.gpg https://www.postgresql.org/media/keys/ACCC4CF8.asc"
echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" >/etc/apt/sources.list.d/pgdg.list

run "apt-get update -y"
run "apt-get install -y whiptail"
run "apt-get install -y software-properties-common curl wget gnupg lsb-release"

# Ondrej PHP
run "add-apt-repository -y ppa:ondrej/php"
run "apt-get update -y" 


### 1. Interactive Prompts ####################################################
NEW_USER=$(whiptail --inputbox "New SSH user (default: deployer)" 8 60 "deployer" 3>&1 1>&2 2>&3)

ACME_EMAIL=$(whiptail --inputbox "ACME email for Let's Encrypt\nExample: [email protected]" 8 60 "" 3>&1 1>&2 2>&3)

BASE_DOMAIN=$(whiptail --inputbox "Base domain (include www.)\nExample: www.mysite.com" 8 60 "" 3>&1 1>&2 2>&3)

# Strip leading www. & final TLD for folder slug
DOMAIN_SLUG=$(basename "${BASE_DOMAIN#www.}" | cut -d'.' -f1)

while true; do
   while true ; do
    PHP_VERSION=$(whiptail --title "PHP Version" --menu "Choose PHP version:" 15 50 5 \
        "8.0" "" "8.1" "" "8.2" "(LTS)" "8.3" "(latest)" 3>&1 1>&2 2>&3) || {
        echo "Cancelled."; exit 1; }
    [[ -n $PHP_VERSION ]] && break
    done

    # Build extension list dynamically
    # mapfile -t ALL_EXT < <(apt-cache pkgnames "php$PHP_VERSION-" | sed "s/php$PHP_VERSION-//" | sort)

    # mapfile -t ALL_EXT < <(
    #     apt-cache pkgnames "php$PHP_VERSION-" # version-scoped
    #     apt-cache pkgnames "php-"             # generic PECL
    # ) | grep -Ev "php($PHP_VERSION|-common|-cli|-fpm)" |
    #     sed -E "s/^php$PHP_VERSION-//;s/^php-//" | sort -u
    mapfile -t ALL_EXT < <(
        { apt-cache pkgnames "php$PHP_VERSION-" && apt-cache pkgnames "php-"; } 2>/dev/null \
        | grep -Ev "php($PHP_VERSION|-common|-cli|-fpm)" \
        | sed -E "s/^php$PHP_VERSION-//;s/^php-//" | sort -u
    )

    PRESEL=("bcmath" "curl" "mbstring" "pgsql" "xml" "zip" "intl" "gd" "imagick" "soap" "sqlite3" "bz2" "readline" "opcache" "dev")
    EXT_DIALOG=()
    for ext in "${ALL_EXT[@]}"; do
        default="OFF"
        [[ " ${PRESEL[*]} " =~ " ${ext} " ]] && default="ON"
        EXT_DIALOG+=("$ext" "" "$default")
    done
    PHP_EXT_SELECTED=$(whiptail --title "PHP $PHP_VERSION Extensions" \
        --checklist "Select extensions (space to toggle):" 20 70 10 \
        "${EXT_DIALOG[@]}" 3>&1 1>&2 2>&3) || true

    # If user picked none, warn
    if [[ -z "$PHP_EXT_SELECTED" ]]; then
        whiptail --yesno "No extensions selected. Go back?" 8 40
        [[ $? -eq 0 ]] && continue
    fi
    break
done
PHP_EXT_SELECTED=${PHP_EXT_SELECTED//\"/}

DB_USER=$(whiptail --inputbox "PostgreSQL role (CREATEDB)" 8 60 "" 3>&1 1>&2 2>&3)
DB_PASS=$(whiptail --passwordbox "PostgreSQL role password" 8 60 3>&1 1>&2 2>&3)

UFW_EXTRA=$(whiptail --inputbox "Extra ports to allow (comma-sep) or blank" 8 60 "" 3>&1 1>&2 2>&3)

GH_EMAIL=$(whiptail --inputbox "Email tag for GitHub Actions SSH key" 8 60 "" 3>&1 1>&2 2>&3)

### 2. Show summary & confirm #################################################
whiptail --yesno "=== Summary ===
User:      $NEW_USER
Domain:    $BASE_DOMAIN
DomainSlug:$DOMAIN_SLUG
PHP:       $PHP_VERSION
Ext:       $PHP_EXT_SELECTED
Postgres:  $DB_USER
ExtraPorts:$UFW_EXTRA
Reboot:    Yes (auto)
Proceed?" 15 60 || {
    echo "Cancelled."
    exit 0
}

# just AFTER the final confirmation dialog:
LOGFILE="$SCRIPT_DIR/bootstrap.log"
exec 1> >(tee -a "$LOGFILE") 2>&1

### 3. Begin installation #####################################################
step 5 "Creating user and SSH"
id "$NEW_USER" &>/dev/null || run "adduser --disabled-password --gecos '' $NEW_USER"
run "usermod -aG sudo $NEW_USER"

mkdir -p "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh"
[[ -f /root/.ssh/authorized_keys ]] &&
    run "cp /root/.ssh/authorized_keys /home/$NEW_USER/.ssh/authorized_keys"
run "chmod 600 /home/$NEW_USER/.ssh/authorized_keys"
run "chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh"

step 10 "Adding APT repos & updating"
run "apt-get update -y"
run "apt-get install -y software-properties-common curl wget gnupg lsb-release"


# Caddy
run "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy.gpg"
echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] \
  https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
  > /etc/apt/sources.list.d/caddy-stable.list


run "apt-get update -y"

step 15 "Installing Caddy"
run "apt-get install -y caddy"

# Write global email
ensure_file /etc/caddy/Caddyfile
cat >/etc/caddy/Caddyfile <<EOF
{
    email $ACME_EMAIL
}
EOF

step 20 "Installing PHP $PHP_VERSION + extensions"
PHP_PKGS="php$PHP_VERSION php$PHP_VERSION-fpm php$PHP_VERSION-cli php$PHP_VERSION-common"
for ext in $PHP_EXT_SELECTED; do
    # PHP_PKGS+=" php$PHP_VERSION-$ext"
    if apt-cache show "php$PHP_VERSION-$ext" &>/dev/null; then
        PHP_PKGS+=" php$PHP_VERSION-$ext"
    else
        PHP_PKGS+=" php-$ext"
    fi
done
run "apt-get install -y $PHP_PKGS"
run "systemctl enable --now php$PHP_VERSION-fpm"

step 25 "Installing Composer"
run "curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"

step 30 "Installing Node LTS via NVM"
if ((!DRY_RUN)); then
    sudo -u "$NEW_USER" bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
    sudo -u "$NEW_USER" bash -c "source ~/.nvm/nvm.sh && nvm install --lts && nvm alias default node"
    NODE_BIN=$(sudo -u "$NEW_USER" bash -c "source ~/.nvm/nvm.sh && command -v node")
    run "ln -sf $NODE_BIN /usr/local/bin/node"
    run "ln -sf ${NODE_BIN%/node}/npm /usr/local/bin/npm"
fi

step 35 "Installing PostgreSQL 17"
run "apt-get install -y postgresql-17 postgresql-client-17"
run "systemctl enable --now postgresql@17-main"
if ((!DRY_RUN)); then
    sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 ||
        sudo -u postgres psql -c "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASS' NOSUPERUSER CREATEDB;"
fi

step 40 "Installing Cockpit & phpPgAdmin"
run "apt-get install -y cockpit phppgadmin"
run "systemctl enable --now cockpit.socket"

step 45 "Installing Google Chrome"
if ((!DRY_RUN)); then
    wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    apt-get install -y /tmp/chrome.deb || apt-get -f install -y
    rm -f /tmp/chrome.deb
fi

step 50 "Setting folder skeleton under /var/www"
BASE_PATH="/var/www/$DOMAIN_SLUG"
for dir in artifacts releases bootstrap storage; do
    run "mkdir -p $BASE_PATH/$dir"
done
run "ln -sfn $BASE_PATH/releases $BASE_PATH/current"
run "chown -R $NEW_USER:www-data $BASE_PATH"
run "find $BASE_PATH -type d -exec chmod 2775 {} +"
run "find $BASE_PATH -type f -exec chmod 664 {} +"

step 55 "Caddy site blocks"
CADDY_CFG="/etc/caddy/Caddyfile"
cat >>"$CADDY_CFG" <<EOF

# Laravel site
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
run "systemctl reload caddy"

step 60 "UFW firewall"
run "apt-get install -y ufw"
run "ufw --force reset"
for p in 22 80 443 9090; do run "ufw allow $p"; done
IFS=',' read -ra EXTRA <<<"$UFW_EXTRA"
for p in "${EXTRA[@]}"; do [[ -n "$p" ]] && run "ufw allow ${p// /}"; done
run "ufw --force enable"

step 65 "Generate GitHub Actions key"
if ((!DRY_RUN)); then
    sudo -u "$NEW_USER" ssh-keygen -t ed25519 -C "$GH_EMAIL" -N "" -f "/home/$NEW_USER/.ssh/gh_actions_key" -q
    cat "/home/$NEW_USER/.ssh/gh_actions_key.pub" >>"/home/$NEW_USER/.ssh/authorized_keys"
    echo "=== GitHub Actions Private Key ==="
    cat "/home/$NEW_USER/.ssh/gh_actions_key"
fi

step 70 "Install Zsh & Oh-My-Zsh"
run "apt-get install -y zsh git"
if ((!DRY_RUN)); then
    OMZ=/opt/oh-my-zsh
    [[ -d $OMZ ]] || git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git $OMZ
    for usr in root "$NEW_USER"; do
        home=$(eval echo "~$usr")
        cp -f $OMZ/templates/zshrc.zsh-template "$home/.zshrc"
        chown $usr:$usr "$home/.zshrc"
        chsh -s /usr/bin/zsh "$usr"
    done
fi

step 75 "Cleanup"
run "apt-get autoremove -y"
run "apt-get clean"

echo "--------------------------------------------------"
echo "Setup complete. Log: $LOGFILE"
if ((DRY_RUN)); then
    echo "DRY-RUN finished: no changes applied, no reboot."
    exit 0
fi
echo "Server will reboot in 20 seconds..."
sleep 20
reboot

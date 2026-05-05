#!/bin/bash
###############################################################################
# Author: mews_se
# Description:
#   Unified multi-profile system bootstrap script for Debian/DietPi systems.
#
#   Profiles:
#     - x64
#     - x64-brk
#     - pi
#     - pi-brk
#
#   Features:
#     - Required package bootstrap
#     - System update & upgrade
#     - SSH hardening
#     - Passwordless sudo
#     - .bashrc recreation
#     - Interactive .bash_aliases merge/update
#     - SNMPD install (profile-aware)
#     - Docker install & removal
#     - PiVPN install + auto client configs + QR
#     - DietPi upgrade helpers
#     - Fastfetch repo clone
#     - Backup / restore helpers
#     - Health check
#     - Important paths display
#     - Profile config display
#     - Wake-on-LAN install
#     - NAS backup script generator
#     - Log file in user home
#     - Interactive menu
###############################################################################

set -euo pipefail

###############################################################################
# Trap signals for graceful exit
###############################################################################
trap 'echo "Script interrupted. Exiting..."; exit 1' SIGINT SIGTERM

###############################################################################
# Validate environment: SUDO_USER must be set
###############################################################################
if [ -z "${SUDO_USER:-}" ]; then
    echo "Error: SUDO_USER is not set. Please run this script with sudo." >&2
    exit 1
fi

###############################################################################
# Script metadata
###############################################################################
SCRIPT_VERSION="v2026.05.05"
LOG_FILE="/home/$SUDO_USER/hostctl.log"

###############################################################################
# FUNCTION: log
# Description: Timestamped log helper with optional logfile in user home
###############################################################################
log() {
    local message="$1"
    local level="${2:-INFO}"
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') - [$level] $message"

    if [ "$level" = "ERROR" ]; then
        echo "$line" >&2
    else
        echo "$line"
    fi

    touch "$LOG_FILE" 2>/dev/null || true
    chown "$SUDO_USER:$SUDO_USER" "$LOG_FILE" 2>/dev/null || true
    chmod 644 "$LOG_FILE" 2>/dev/null || true
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

###############################################################################
# FUNCTION: backup_file
# Description: Create a timestamped backup of a file if it exists
###############################################################################
backup_file() {
    local target_file="$1"
    local backup_file

    if [ ! -f "$target_file" ]; then
        return 1
    fi

    backup_file="${target_file}.bak_$(date +%F_%T)"
    sudo cp "$target_file" "$backup_file"
    echo "$backup_file"
}

###############################################################################
# FUNCTION: find_latest_backup
# Description: Return latest timestamped backup for a target file
###############################################################################
find_latest_backup() {
    local target_file="$1"

    find "$(dirname "$target_file")" -maxdepth 1 -type f \
        -name "$(basename "$target_file").bak_*" -printf '%T@ %p\n' 2>/dev/null | \
        sort -nr | head -n1 | cut -d' ' -f2-
}

###############################################################################
# FUNCTION: get_os_codename
# Description: Read VERSION_CODENAME from /etc/os-release
###############################################################################
get_os_codename() {
    local distro_codename

    if [ ! -f /etc/os-release ]; then
        return 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    distro_codename="${VERSION_CODENAME:-}"

    if [ -z "$distro_codename" ]; then
        return 1
    fi

    echo "$distro_codename"
}

###############################################################################
# FUNCTION: ssh_service_name
# Description: Detect the active SSH service name
###############################################################################
ssh_service_name() {
    if sudo systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        echo "ssh"
    elif sudo systemctl list-unit-files sshd.service >/dev/null 2>&1; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

###############################################################################
# FUNCTION: restart_ssh_service
# Description: Restart SSH service if present
###############################################################################
restart_ssh_service() {
    local service_name
    service_name="$(ssh_service_name)"

    if sudo systemctl is-enabled "$service_name" >/dev/null 2>&1 ||
       sudo systemctl is-active --quiet "$service_name"; then
        sudo systemctl restart "$service_name"
        log "SSH service '$service_name' restarted successfully."
    else
        log "SSH service '$service_name' is not active/enabled. Restart manually if needed." "WARN"
    fi
}

###############################################################################
# FUNCTION: get_allowed_ssh_users
# Description: Build AllowUsers entry from available local accounts
###############################################################################
get_allowed_ssh_users() {
    local users=()
    local candidate

    for candidate in "$SUDO_USER" dietpi mews; do
        if id "$candidate" >/dev/null 2>&1; then
            users+=("$candidate")
        fi
    done

    awk 'NF { if (!seen[$0]++) printf "%s ", $0 }' < <(printf '%s\n' "${users[@]}") | sed 's/[[:space:]]*$//'
}

###############################################################################
# FUNCTION: detect_default_profile
# Description: Detect a sensible default profile from CPU architecture
###############################################################################
detect_default_profile() {
    local arch
    arch="$(uname -m || true)"
    case "$arch" in
        arm*|aarch64) echo "pi" ;;
        *) echo "x64" ;;
    esac
}

###############################################################################
# FUNCTION: select_profile
# Description: Original interactive profile selection UI
###############################################################################
PROFILE=""

select_profile() {
    local default_profile
    default_profile="$(detect_default_profile)"

    clear
    echo "#####################################"
    echo "#         Profile Selection         #"
    echo "#####################################"
    echo "Detected default: $default_profile"
    echo ""
    echo "Select which machine type this is:"
    echo "  1) x64"
    echo "  2) x64-brk"
    echo "  3) pi"
    echo "  4) pi-brk"
    echo "  5) Use detected default ($default_profile)"
    echo ""

    read -rp "Enter your choice: " pchoice
    case "$pchoice" in
        1) PROFILE="x64" ;;
        2) PROFILE="x64-brk" ;;
        3) PROFILE="pi" ;;
        4) PROFILE="pi-brk" ;;
        5|"") PROFILE="$default_profile" ;;
        *) log "Invalid profile choice. Using detected default: $default_profile" "WARN"; PROFILE="$default_profile" ;;
    esac

    log "Profile selected: $PROFILE"
}

###############################################################################
# PROFILE VARIABLES
# Description: Variables that differ between profile types
###############################################################################
SNMP_ROCOMMUNITY=""
SNMP_HARDWARE_EXTENDS=""

###############################################################################
# FUNCTION: apply_profile_config
# Description: Apply per-profile SNMP settings
###############################################################################
apply_profile_config() {
    case "$PROFILE" in
        x64)
            SNMP_ROCOMMUNITY="martin"
            SNMP_HARDWARE_EXTENDS=$(cat <<'EOL'
#Regular Linux:
extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /sys/devices/virtual/dmi/id/product_name
extend .1.3.6.1.4.1.2021.7890.3 vendor   /bin/cat /sys/devices/virtual/dmi/id/sys_vendor
extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /sys/devices/virtual/dmi/id/product_serial
# Raspberry Pi:
#extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /proc/device-tree/model
#extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /proc/device-tree/serial-number
EOL
)
            ;;
        x64-brk)
            SNMP_ROCOMMUNITY="brk"
            SNMP_HARDWARE_EXTENDS=$(cat <<'EOL'
#Regular Linux:
extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /sys/devices/virtual/dmi/id/product_name
extend .1.3.6.1.4.1.2021.7890.3 vendor   /bin/cat /sys/devices/virtual/dmi/id/sys_vendor
extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /sys/devices/virtual/dmi/id/product_serial
# Raspberry Pi:
#extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /proc/device-tree/model
#extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /proc/device-tree/serial-number
EOL
)
            ;;
        pi)
            SNMP_ROCOMMUNITY="martin"
            SNMP_HARDWARE_EXTENDS=$(cat <<'EOL'
#Regular Linux:
#extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /sys/devices/virtual/dmi/id/product_name
#extend .1.3.6.1.4.1.2021.7890.3 vendor   /bin/cat /sys/devices/virtual/dmi/id/sys_vendor
#extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /sys/devices/virtual/dmi/id/product_serial
# Raspberry Pi:
extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /proc/device-tree/model
extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /proc/device-tree/serial-number
EOL
)
            ;;
        pi-brk)
            SNMP_ROCOMMUNITY="brk"
            SNMP_HARDWARE_EXTENDS=$(cat <<'EOL'
#Regular Linux:
#extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /sys/devices/virtual/dmi/id/product_name
#extend .1.3.6.1.4.1.2021.7890.3 vendor   /bin/cat /sys/devices/virtual/dmi/id/sys_vendor
#extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /sys/devices/virtual/dmi/id/product_serial
# Raspberry Pi:
extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /proc/device-tree/model
extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /proc/device-tree/serial-number
EOL
)
            ;;
        *)
            log "Unknown profile '$PROFILE'. Valid: x64, x64-brk, pi, pi-brk" "ERROR"
            exit 1
            ;;
    esac
}

###############################################################################
# REQUIRED COMMANDS / PACKAGE MAP
# Description: Commands to verify/install before running functions
###############################################################################
declare -A required_commands=(
    [sudo]="sudo"
    [apt-get]="apt-get"
    [sed]="sed"
    [ssh-keygen]="openssh-client"
    [systemctl]="systemd"
    [dpkg]="dpkg"
    [curl]="curl"
    [git]="git"
    [nc]="netcat-traditional"
    [script]="bsdextrautils"
)

###############################################################################
# FUNCTION: install_missing_packages
# Description: Ensure all required commands/packages are available
###############################################################################
install_missing_packages() {
    local missing_packages=()
    local failed_packages=()
    local cmd pkg

    for cmd in "${!required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_packages+=("${required_commands[$cmd]}")
        else
            log "$cmd is already installed."
        fi
    done

    if [ "${#missing_packages[@]}" -gt 0 ]; then
        log "Installing missing packages: ${missing_packages[*]}"

        if ! sudo apt-get update; then
            log "Error updating package lists. Please check your sources and network." "ERROR"
            exit 1
        fi

        if ! sudo apt-get install -y "${missing_packages[@]}"; then
            log "Bulk installation failed. Retrying packages one by one..." "WARN"
            for pkg in "${missing_packages[@]}"; do
                if ! sudo apt-get install -y "$pkg"; then
                    failed_packages+=("$pkg")
                    log "Failed to install $pkg even after retry." "ERROR"
                else
                    log "Successfully installed $pkg after retry."
                fi
            done

            if [ "${#failed_packages[@]}" -gt 0 ]; then
                log "The following packages could not be installed: ${failed_packages[*]}" "ERROR"
                exit 1
            fi
        else
            log "Missing packages installed successfully."
        fi
    else
        log "All required packages are already installed."
    fi

    for cmd in "${!required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "Critical Error: $cmd is still not available after installation attempts." "ERROR"
            exit 1
        fi
    done

    log "All required commands are now available."
}

###############################################################################
# FUNCTION: preflight_ssh
# Description: Check basic SSH prerequisites before editing sshd_config
###############################################################################
preflight_ssh() {
    if [ ! -f /etc/ssh/sshd_config ]; then
        log "/etc/ssh/sshd_config not found." "ERROR"
        return 1
    fi
    return 0
}

###############################################################################
# FUNCTION: preflight_docker
# Description: Check basic prerequisites before Docker repo installation
###############################################################################
preflight_docker() {
    if [ ! -f /etc/os-release ]; then
        log "/etc/os-release not found." "ERROR"
        return 1
    fi

    if ! get_os_codename >/dev/null; then
        log "Could not determine Debian codename." "ERROR"
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log "curl is required for Docker repository installation." "ERROR"
        return 1
    fi

    return 0
}

###############################################################################
# FUNCTION: preflight_pivpn
# Description: Check basic prerequisites before PiVPN installation
###############################################################################
preflight_pivpn() {
    if ! command -v curl >/dev/null 2>&1; then
        log "curl is required for PiVPN installation." "ERROR"
        return 1
    fi

    if ! command -v script >/dev/null 2>&1; then
        log "'script' command is required for PiVPN installer PTY handling." "ERROR"
        return 1
    fi

    return 0
}

###############################################################################
# FUNCTION: system_update_upgrade
# Description: Update package lists and perform full upgrade
###############################################################################
system_update_upgrade() {
    log "Running system update and upgrade."
    sudo apt-get update
    sudo apt-get dist-upgrade -y
    log "System update and upgrade completed successfully."
}

###############################################################################
# FUNCTION: dietpi_bullseye_to_bookworm
# Description: Run DietPi Bullseye -> Bookworm upgrade in a PTY
###############################################################################
dietpi_bullseye_to_bookworm() {
    log "DietPi upgrade: Bullseye -> Bookworm"
    script -qec "sudo bash -c \"\$(curl -sSf 'https://raw.githubusercontent.com/MichaIng/DietPi/dev/.meta/dietpi-bookworm-upgrade')\"" /dev/null
    log "DietPi upgrade Bullseye -> Bookworm finished."
}

###############################################################################
# FUNCTION: dietpi_bookworm_to_trixie
# Description: Run DietPi Bookworm -> Trixie upgrade in a PTY
###############################################################################
dietpi_bookworm_to_trixie() {
    log "DietPi upgrade: Bookworm -> Trixie"
    script -qec "sudo bash -c \"\$(curl -sSf 'https://raw.githubusercontent.com/MichaIng/DietPi/dev/.meta/dietpi-trixie-upgrade')\"" /dev/null
    log "DietPi upgrade Bookworm -> Trixie finished."
}

###############################################################################
# FUNCTION: update_sudoers
# Description: Enable passwordless sudo for the sudo group
###############################################################################
update_sudoers() {
    log "Updating sudoers."

    local sudoers_dropin="/etc/sudoers.d/99-sudo-nopasswd"
    local sudoers_content="%sudo ALL=(ALL) NOPASSWD: ALL"

    if [ -f "$sudoers_dropin" ]; then
        backup_file "$sudoers_dropin" >/dev/null || true
    fi

    printf '%s\n' "$sudoers_content" | sudo tee "$sudoers_dropin" > /dev/null
    sudo chmod 440 "$sudoers_dropin"

    if sudo visudo -cf /etc/sudoers >/dev/null 2>&1; then
        log "sudoers drop-in updated successfully at $sudoers_dropin."
    else
        sudo rm -f "$sudoers_dropin"
        log "visudo validation failed. Removed invalid sudoers drop-in." "ERROR"
        return 1
    fi
}

###############################################################################
# FUNCTION: configure_ssh
# Description: Disable root SSH login and restrict allowed users
###############################################################################
configure_ssh() {
    preflight_ssh || return 1

    log "Configuring SSH."
    local sshd_config="/etc/ssh/sshd_config"
    local allow_users
    allow_users="$(get_allowed_ssh_users)"

    backup_file "$sshd_config" >/dev/null || true

    sudo sed -E -i 's/^[#[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin no/' "$sshd_config"
    if ! sudo grep -Eq '^[[:space:]]*PermitRootLogin[[:space:]]+' "$sshd_config"; then
        printf '%s\n' 'PermitRootLogin no' | sudo tee -a "$sshd_config" > /dev/null
    fi
    log "PermitRootLogin set to no."

    if [ -n "$allow_users" ]; then
        if sudo grep -Eq '^[#[:space:]]*AllowUsers[[:space:]]+' "$sshd_config"; then
            sudo sed -E -i "s|^[#[:space:]]*AllowUsers[[:space:]]+.*|AllowUsers $allow_users|" "$sshd_config"
        else
            printf '%s\n' "AllowUsers $allow_users" | sudo tee -a "$sshd_config" > /dev/null
        fi
        log "AllowUsers set to: $allow_users"
    else
        log "No valid local users found for AllowUsers. Skipping AllowUsers update." "WARN"
    fi

    if sudo sshd -t -f "$sshd_config"; then
        restart_ssh_service
        log "SSH configuration updated successfully."
    else
        log "sshd_config validation failed. Restore the latest backup before retrying." "ERROR"
        return 1
    fi
}

###############################################################################
# FUNCTION: generate_ssh_key
# Description: Generate ed25519 SSH key for invoking sudo user
###############################################################################
generate_ssh_key() {
    log "Generating SSH key."

    local SSH_DIR="/home/$SUDO_USER/.ssh"
    local KEY_FILE="$SSH_DIR/id_ed25519"

    if [ -f "$KEY_FILE" ]; then
        log "SSH key already exists for $SUDO_USER. Skipping generation."
    else
        sudo -u "$SUDO_USER" mkdir -p "$SSH_DIR"
        sudo -u "$SUDO_USER" ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
        log "Ed25519 SSH key generated successfully."
    fi

    sudo chmod 700 "$SSH_DIR"
    sudo chmod 600 "$KEY_FILE"
    if [ -f "$KEY_FILE.pub" ]; then
        sudo chmod 644 "$KEY_FILE.pub"
    fi
}

###############################################################################
# FUNCTION: create_bashrc
# Description: Replace ~/.bashrc with curated default
###############################################################################
create_bashrc() {
    log "Creating/updating .bashrc file."

    local BASHRC_FILE="/home/$SUDO_USER/.bashrc"

    if [ -f "$BASHRC_FILE" ]; then
        sudo -u "$SUDO_USER" cp "$BASHRC_FILE" "${BASHRC_FILE}.bak_$(date +%F_%T)"
        sudo -u "$SUDO_USER" rm "$BASHRC_FILE"
        log "Removed existing .bashrc file (backup created)."
    fi

    sudo -u "$SUDO_USER" mkdir -p "$(dirname "$BASHRC_FILE")"

    cat <<'EOL' | sudo -u "$SUDO_USER" tee -a "$BASHRC_FILE" > /dev/null
case $- in
    *i*) ;;
    *) return;;
esac

HISTCONTROL=ignoreboth
shopt -s histappend
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s checkwinsize

if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
        color_prompt=yes
    else
        color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w \$\[\033[00m\] '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

if [ -f ~/.bash_aliases ]; then
    source ~/.bash_aliases
fi
EOL

    log ".bashrc file created/updated successfully for user: $SUDO_USER."
}

###############################################################################
# FUNCTION: create_bash_aliases
# Description: Merge curated aliases with optional retention of custom aliases
###############################################################################
create_bash_aliases() {
    log "Creating/updating .bash_aliases file with interactive review."

    local USER_HOME="/home/$SUDO_USER"
    local ALIASES_FILE="$USER_HOME/.bash_aliases"
    local BACKUP_FILE
    local TEMP_FILE

    BACKUP_FILE="$ALIASES_FILE.bak_$(date +%F_%T)"
    TEMP_FILE=$(sudo -u "$SUDO_USER" mktemp "$USER_HOME/.bash_aliases.tmp.XXXXXX")

    local RED GREEN YELLOW CYAN NC
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'

    if [ -f "$ALIASES_FILE" ]; then
        sudo -u "$SUDO_USER" cp "$ALIASES_FILE" "$BACKUP_FILE"
        log "Backup created at $BACKUP_FILE"
    fi

    local NEW_ALIASES
    NEW_ALIASES=$(cat <<'EOL'
alias apta="sudo apt-get update && sudo apt-get dist-upgrade -y && sudo apt-get autoremove -y && sudo apt-get clean"
alias bat="batcat"
alias brkpi="ssh dietpi@10.0.1.8"
alias dcdown="docker compose down"
alias dclog="docker compose logs -f"
alias dcpull="docker compose pull"
alias dcstop="docker compose stop"
alias dcupd="docker compose up -d"
alias dcupdlog="docker compose up -d && docker compose logs -f"
alias dellpi="ssh dietpi@10.0.0.6"
alias fa="fastfetch"
alias fanoff="sudo systemctl stop fancontrol.service"
alias fanon="sudo systemctl start fancontrol.service"
alias ff="fastfetch -c all.jsonc"
alias flight="ssh root@10.0.1.12"
alias kodipi="ssh dietpi@10.0.0.7"
alias london="ssh dietpi@london.stockzell.se"
alias mm="ssh martin@10.0.0.11"
alias nyc="ssh dietpi@newyork.stockzell.se"
alias nyc2="ssh dietpi@newyork2.stockzell.se"
alias nyc3="ssh dietpi@newyork3.stockzell.se"
alias norway="ssh dietpi@norway.stockzell.se"
alias optiplex="ssh mews@10.0.1.6"
alias pfsense="ssh -p 2221 admin@10.0.0.1"
alias pfsensebrk="ssh -p 2221 admin@10.0.1.1"
alias pizerow="ssh dietpi@10.0.0.13"
alias prox="ssh root@10.0.0.99"
alias reb="sudo reboot"
alias sen="watch -n 1 sensors"
alias tb="ssh dietpi@10.0.0.97"
alias teslamate="ssh dietpi@10.0.0.14"
alias testpi="ssh dietpi@10.0.0.8"
alias testpi5="ssh dietpi@10.0.0.17"
alias woldellpi="wakeonlan 70:b5:e8:76:12:8d"
alias wolprox="wakeonlan c0:25:a5:94:75:ee"
alias woltb7="wakeonlan a8:5e:45:cd:db:cb"
alias wolmm="wakeonlan ac:87:a3:38:d0:00"
alias wolnas="wakeonlan 90:09:d0:1f:95:b7"
EOL
)

    declare -A new_aliases
    declare -A final_aliases

    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*alias[[:space:]]+([^=]+)= ]]; then
            local name
            name="${BASH_REMATCH[1]}"
            new_aliases["$name"]="$line"
        fi
    done <<< "$NEW_ALIASES"

    local found_custom=false

    if [ -f "$ALIASES_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ ^[[:space:]]*alias[[:space:]]+([^=]+)= ]]; then
                local alias_name existing_line response
                alias_name="${BASH_REMATCH[1]}"
                existing_line="$line"
                if [[ -z "${new_aliases[$alias_name]+exists}" ]]; then
                    found_custom=true
                    echo -e "\n${YELLOW}Found alias not in script: ${CYAN}$alias_name${NC}"
                    echo -e "  ${CYAN}$existing_line${NC}"
                    echo -ne "${YELLOW}Keep this alias? [Y/n]: ${NC}" > /dev/tty
                    IFS= read -r response < /dev/tty
                    IFS= read -r -t 0.1 -n 10000 < /dev/tty 2>/dev/null || true
                    if [[ -z "$response" || "$response" =~ ^[Yy]$ ]]; then
                        final_aliases["$alias_name"]="$existing_line"
                        echo -e "${GREEN}→ Keeping: $alias_name${NC}"
                    else
                        echo -e "${RED}→ Removed: $alias_name${NC}"
                    fi
                fi
            else
                echo "$line" >> "$TEMP_FILE"
            fi
        done < "$ALIASES_FILE"
    fi

    if [ "$found_custom" = false ]; then
        log "No custom aliases found for review."
    fi

    local alias
    for alias in "${!new_aliases[@]}"; do
        final_aliases["$alias"]="${new_aliases[$alias]}"
    done

    local alias_line
    for alias_line in "${final_aliases[@]}"; do
        echo "$alias_line"
    done | sort >> "$TEMP_FILE"

    sudo mv "$TEMP_FILE" "$ALIASES_FILE"
    sudo chown "$SUDO_USER:$SUDO_USER" "$ALIASES_FILE"
    log ".bash_aliases updated successfully with interactive selections and sorted output."
}

###############################################################################
# FUNCTION: install_configure_snmpd
# Description: Install SNMPD and write profile-specific configuration
###############################################################################
install_configure_snmpd() {
    log "Installing and configuring SNMPD."

    if ! dpkg -l | grep -q "^ii.*lm-sensors"; then
        sudo apt-get install -y lm-sensors
        log "lm-sensors package installed successfully."
    else
        log "lm-sensors package is already installed. No changes needed."
    fi

    if ! dpkg -l | grep -q "^ii.*snmpd"; then
        sudo apt-get install -y snmpd
        log "snmpd package installed successfully."
    else
        log "snmpd package is already installed. No changes needed."
    fi

    local SNMPD_CONF_FILE="/etc/snmp/snmpd.conf"
    if [ -f "$SNMPD_CONF_FILE" ]; then
        sudo cp "$SNMPD_CONF_FILE" "${SNMPD_CONF_FILE}.bak_$(date +%F_%T)"
        log "Existing snmpd.conf backed up."
    fi

    local SNMPD_CONF_CONTENT
    SNMPD_CONF_CONTENT=$(cat <<EOF
sysLocation    Sitting on the Dock of the Bay
sysContact     Me <me@example.org>
sysServices    72
master  agentx
agentaddress  udp:161
view   systemonly  included   .1.3.6.1.2.1.1
view   systemonly  included   .1.3.6.1.2.1.25.1
rocommunity ${SNMP_ROCOMMUNITY}
rouser authPrivUser authpriv -V systemonly
includeAllDisks  10%
extend uptime /bin/cat /proc/uptime
extend .1.3.6.1.4.1.2021.7890.1 distro /usr/local/bin/distro
${SNMP_HARDWARE_EXTENDS}
EOF
)

    echo "$SNMPD_CONF_CONTENT" | sudo tee "$SNMPD_CONF_FILE" > /dev/null
    log "snmpd.conf file created/overwritten successfully at $SNMPD_CONF_FILE."

    sudo chown root:root "$SNMPD_CONF_FILE"
    log "Ownership of $SNMPD_CONF_FILE set to root:root."

    if sudo systemctl is-active --quiet snmpd; then
        sudo systemctl reload snmpd
        log "SNMPD service reloaded successfully."
    else
        log "SNMPD service is not active; start/restart manually if needed." "WARN"
    fi
}

###############################################################################
# FUNCTION: install_docker_repository
# Description: Add Docker official repository
###############################################################################
install_docker_repository() {
    preflight_docker || return 1

    log "Installing Docker repository."

    sudo apt-get update
    sudo apt-get install -y ca-certificates curl

    sudo install -m 0755 -d /etc/apt/keyrings

    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    local distro_codename
    distro_codename="$(get_os_codename)"

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      ${distro_codename} stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    log "Docker repository installed successfully."
}

###############################################################################
# FUNCTION: install_pivpn
# Description: Install PiVPN via PTY and optionally create default clients
###############################################################################
install_pivpn() {
    preflight_pivpn || return 1

    log "Installing PiVPN."

    local tmp
    tmp="$(mktemp)"

    curl -fsSL https://install.pivpn.io -o "$tmp"
    script -qec "sudo bash '$tmp'" /dev/null
    rm -f "$tmp"

    log "PiVPN installation completed."

    echo
    read -rp "Create PiVPN configs? [Y/n]: " ans < /dev/tty
    if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
        create_pivpn_clients
    else
        log "Skipping PiVPN client creation."
    fi
}

###############################################################################
# FUNCTION: create_pivpn_clients
# Description: Create hostname-based clients and optionally show iPhone QR code
###############################################################################
create_pivpn_clients() {
    log "Creating PiVPN client configurations."

    if ! command -v pivpn >/dev/null 2>&1; then
        log "PiVPN command not found. Install PiVPN first." "ERROR"
        return 1
    fi

    local HOST
    HOST="$(hostname -s)"

    local CLIENTS=(
        "${HOST}-tb7"
        "${HOST}-mbp"
        "${HOST}-iph"
        "${HOST}-len"
    )

    local client
    for client in "${CLIENTS[@]}"; do
        if pivpn list | grep -q "$client"; then
            log "Exists: $client"
        else
            log "Creating client: $client"
            pivpn add -n "$client" -ip auto
        fi
    done

    echo
    read -rp "Show QR for ${HOST}-iph? [Y/n]: " qr < /dev/tty
    if [[ -z "$qr" || "$qr" =~ ^[Yy]$ ]]; then
        pivpn -qr "${HOST}-iph" < /dev/tty > /dev/tty 2>/dev/tty
    fi
}

###############################################################################
# FUNCTION: install_docker_ce
# Description: Install Docker Engine and related tools
###############################################################################
install_docker_ce() {
    log "Installing Docker CE and related tools."
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
                           docker-buildx-plugin docker-compose-plugin \
                           docker-ce-rootless-extras
    sudo usermod -aG docker "$SUDO_USER"
    log "Docker CE and tools installed successfully. User added to group 'docker'."
}

###############################################################################
# FUNCTION: remove_docker_and_tools
# Description: Remove Docker packages, repo files, keys, and data directories
###############################################################################
remove_docker_and_tools() {
    log "Removing Docker CE and related tools."

    sudo apt purge -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin \
        docker-ce-rootless-extras

    sudo rm -f /etc/apt/sources.list.d/docker.sources
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /etc/apt/keyrings/docker.asc

    sudo rm -rf /var/lib/docker
    sudo rm -rf /var/lib/containerd

    log "Docker packages, repository configuration, and data directories removed."
}

###############################################################################
# FUNCTION: install_wakeonlan
# Description: Install Wake-on-LAN tools
###############################################################################
install_wakeonlan() {
    log "Installing Wake-on-LAN tools."

    if dpkg -l | grep -q "^ii.*wakeonlan"; then
        log "wakeonlan is already installed. No changes needed."
    else
        if sudo apt-get install -y wakeonlan; then
            log "wakeonlan installed successfully."
        else
            log "Failed to install wakeonlan." "ERROR"
            return 1
        fi
    fi

    if command -v wakeonlan &>/dev/null; then
        log "wakeonlan command is available."
    else
        log "wakeonlan command not found after installation." "ERROR"
        return 1
    fi

    log "Wake-on-LAN setup completed."
}

###############################################################################
# FUNCTION: create_nas_backup_script
# Description: Generate standalone NAS backup script using SMB credentials file
###############################################################################
create_nas_backup_script() {
    log "Creating NAS backup script."

    local invoking_user
    local backup_script
    local credentials_file="/root/.nas-credentials"
    local nas_username=""
    local nas_password=""

    invoking_user="${SUDO_USER:-$(id -un)}"
    backup_script="/home/$invoking_user/nas-backup.sh"

    if [ ! -f "$credentials_file" ]; then
        echo
        read -rp "Enter NAS username: " nas_username < /dev/tty
        read -rsp "Enter NAS password: " nas_password < /dev/tty
        echo

        if [ -z "$nas_username" ] || [ -z "$nas_password" ]; then
            log "NAS credentials cannot be empty." "ERROR"
            return 1
        fi

        sudo install -m 600 /dev/null "$credentials_file"
        printf 'username=%s\npassword=%s\n' "$nas_username" "$nas_password" | sudo tee "$credentials_file" > /dev/null
        sudo chmod 600 "$credentials_file"
        log "Created credentials file at $credentials_file"
    else
        sudo chmod 600 "$credentials_file"
        log "Credentials file already exists at $credentials_file"
    fi

    cat > "$backup_script" <<'EOF'
#!/usr/bin/env bash
#
# nas-backup.sh
#
# DietPi/Debian NAS backup script with local logging.
# - CIFS mount using /root/.nas-credentials
# - DietPi-like filter model
# - Includes /home and /mnt/dietpi_userdata
# - Excludes known runtime/problem paths
# - Writes the physical log file to the invoking user's home directory
# - Keeps rsync CLI behavior close to the original script
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------

NAS_HOST="10.0.0.100"
NAS_SHARE="backup"
NAS_MOUNT_POINT="/mnt/nas_backup"
NAS_BACKUP_ROOT="dietpibackup"
CREDENTIALS_FILE="/root/.nas-credentials"

HOST_NAME="$(hostname -s)"
LOCK_FILE="/var/run/nas-backup.lock"
EXCLUDES_FILE=""

# -----------------------------------------------------------------------------
# User / log path resolution
# -----------------------------------------------------------------------------

resolve_invoking_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
    else
        id -un
    fi
}

resolve_home_dir() {
    local user_name="$1"
    local home_dir

    home_dir="$(getent passwd "$user_name" | cut -d: -f6 || true)"

    if [[ -n "$home_dir" ]]; then
        printf '%s\n' "$home_dir"
        return 0
    fi

    if [[ "$user_name" == "root" ]]; then
        printf '%s\n' "/root"
        return 0
    fi

    printf '%s\n' "/home/$user_name"
}

INVOKING_USER="$(resolve_invoking_user)"
INVOKING_HOME="$(resolve_home_dir "$INVOKING_USER")"
LOCAL_LOG="${INVOKING_HOME}/nas-backup.log"

HOST_DIR="${NAS_MOUNT_POINT}/${NAS_BACKUP_ROOT}/${HOST_NAME}"
MOUNT_OPTS="credentials=${CREDENTIALS_FILE},uid=0,gid=0,file_mode=0600,dir_mode=0700,vers=3.0,mfsymlinks"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

timestamp() {
    date '+%F %T'
}

log() {
    local message="$1"
    local line="[$(timestamp)] $message"
    printf '%s\n' "$line" | tee -a "$LOCAL_LOG"
}

prepare_log_file() {
    mkdir -p "$INVOKING_HOME"
    touch "$LOCAL_LOG"

    if id "$INVOKING_USER" >/dev/null 2>&1; then
        chown "$INVOKING_USER:$INVOKING_USER" "$LOCAL_LOG" 2>/dev/null || true
    fi

    chmod 0644 "$LOCAL_LOG" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Cleanup / locking
# -----------------------------------------------------------------------------

cleanup() {
    local rc=$?

    if [ "${DIETPI_SERVICES_STOPPED:-0}" -eq 1 ] && [ -x /boot/dietpi/dietpi-services ]; then
        /boot/dietpi/dietpi-services start || true
    fi

    if mountpoint -q "$NAS_MOUNT_POINT"; then
        log "Unmounting NAS share: $NAS_MOUNT_POINT"
        umount "$NAS_MOUNT_POINT" || log "Warning: failed to unmount $NAS_MOUNT_POINT"
    fi

    if [[ -n "${EXCLUDES_FILE:-}" && -f "${EXCLUDES_FILE}" ]]; then
        rm -f "$EXCLUDES_FILE"
    fi

    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi

    if (( rc == 0 )); then
        log "NAS backup finished successfully"
    else
        log "NAS backup ended with exit code $rc"
    fi

    if id "$INVOKING_USER" >/dev/null 2>&1; then
        chown "$INVOKING_USER:$INVOKING_USER" "$LOCAL_LOG" 2>/dev/null || true
    fi

    exit "$rc"
}

acquire_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        log "Another backup appears to be running: $LOCK_FILE exists"
        exit 1
    fi
    touch "$LOCK_FILE"
}

DIETPI_SERVICES_STOPPED=0
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must be run as root." >&2
        echo "Run it with: sudo bash $0" >&2
        exit 1
    fi
}

check_requirements() {
    local cmds=(mount umount mountpoint rsync hostname awk grep tee mktemp getent cut apt-get)
    local cmd

    for cmd in "${cmds[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "Missing required command: $cmd" >&2
            exit 1
        }
    done

    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        echo "Missing credentials file: $CREDENTIALS_FILE" >&2
        exit 1
    fi

    chmod 600 "$CREDENTIALS_FILE" || true
}

# -----------------------------------------------------------------------------
# Service handling
# -----------------------------------------------------------------------------

stop_services() {
    if [ -x /boot/dietpi/dietpi-services ]; then
        log "Stopping DietPi services for backup consistency."
        /boot/dietpi/dietpi-services stop || true
        DIETPI_SERVICES_STOPPED=1
        return 0
    fi

    log "Stopping selected services before backup"
    systemctl stop cron 2>/dev/null || true
    systemctl stop crond 2>/dev/null || true
    systemctl stop snmpd 2>/dev/null || true
    systemctl stop docker 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# NAS mounting
# -----------------------------------------------------------------------------

ensure_mountpoint() {
    mkdir -p "$NAS_MOUNT_POINT"
}

mount_nas() {
    if mountpoint -q "$NAS_MOUNT_POINT"; then
        log "NAS share already mounted at $NAS_MOUNT_POINT"
        return 0
    fi

    log "Mounting //$NAS_HOST/$NAS_SHARE to $NAS_MOUNT_POINT"
    mount -t cifs "//$NAS_HOST/$NAS_SHARE" "$NAS_MOUNT_POINT" -o "$MOUNT_OPTS"
    log "NAS share mounted successfully"
}

prepare_target() {
    mkdir -p "$HOST_DIR"
    log "Backup target ready: $HOST_DIR"
}

write_metadata() {
    log "Saving metadata."

    dpkg --get-selections > "$HOST_DIR/package-list.txt" 2>/dev/null || true
    crontab -l > "$HOST_DIR/root-crontab.txt" 2>/dev/null || true
    systemctl list-unit-files > "$HOST_DIR/systemd-unit-files.txt" 2>/dev/null || true
    hostname > "$HOST_DIR/hostname.txt" 2>/dev/null || true
    uname -a > "$HOST_DIR/uname.txt" 2>/dev/null || true
    date > "$HOST_DIR/backup-date.txt" 2>/dev/null || true

    if [[ -r /etc/os-release ]]; then
        cp /etc/os-release "$HOST_DIR/os-release.txt" 2>/dev/null || true
    fi

    if command -v docker >/dev/null 2>&1; then
        docker ps -a > "$HOST_DIR/docker-ps.txt" 2>/dev/null || true
        docker images > "$HOST_DIR/docker-images.txt" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Filter file
# -----------------------------------------------------------------------------

create_excludes_file() {
    EXCLUDES_FILE="$(mktemp /tmp/nas-backup-excludes.XXXXXX)"

    cat > "$EXCLUDES_FILE" <<'EOF_EXCLUDES'
- /mnt/nas_backup/
+ /home/
+ /home/**
+ /mnt/
+ /mnt/dietpi_userdata/
+ /mnt/dietpi_userdata/**
- /mnt/*
- /media/*
- /dev/
- /proc/
- /run/
- /sys/
- /tmp/
- /var/swap
- /.swap*
- /etc/fake-hwclock.data
- /lost+found/
- /var/cache/apt/*
- /var/lib/docker/
- /var/lib/containerd/
- /var/lib/containers/
- /var/agentx/
- /var/run/*
- /var/tmp/*
- /usr/share/man/
EOF_EXCLUDES

    log "Created exclude file: $EXCLUDES_FILE"
}

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------

run_backup() {
    log "Starting rsync backup"

    rsync -aH --whole-file --inplace --numeric-ids --delete --delete-delay \
        --safe-links \
        --info=progress2 \
        --info=name0 \
        --filter="merge ${EXCLUDES_FILE}" \
        / "$HOST_DIR" 2>&1 | tee -a "$LOCAL_LOG"

    log "rsync completed"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    require_root
    check_requirements
    prepare_log_file
    acquire_lock

    log "Starting NAS backup script."

    apt-get update
    apt-get install -y cifs-utils rsync

    ensure_mountpoint
    mount_nas
    prepare_target
    create_excludes_file
    stop_services
    run_backup
    write_metadata

    log "Backup completed successfully to $HOST_DIR"
}

main "$@"
EOF

    chmod +x "$backup_script"
    chown "$invoking_user:$invoking_user" "$backup_script"

    log "NAS backup script created at $backup_script"
    echo
    echo "Created files:"
    echo "  Backup script: $backup_script"
    echo "  Credentials:   $credentials_file"
    echo "  Local log:     /home/$invoking_user/nas-backup.log"
    echo
    echo "NAS layout will be:"
    echo "  //10.0.0.100/backup/dietpibackup/<short-hostname>/"
    echo
    echo "Behavior:"
    echo "  Existing backup is updated in place"
    echo "  New files are added"
    echo "  Changed files are updated"
    echo "  Removed files are deleted from backup"
    echo
    echo "Included rules:"
    echo "  /home/"
    echo "  /mnt/dietpi_userdata/"
    echo "Excluded rules:"
    echo "  /mnt/*, /media/*, /dev/, /proc/, /run/, /sys/, /tmp/"
    echo "  /var/swap, /.swap*, /etc/fake-hwclock.data, /lost+found/"
    echo "  /var/cache/apt/*, /var/lib/docker/, /var/lib/containerd/"
    echo "  /var/lib/containers/, /var/agentx/, /var/run/*, /var/tmp/*"
    echo "  /usr/share/man/"
}

###############################################################################
# FUNCTION: clone_fastfetch_repository
# Description: Clone/update update-fastfetch and write consolidated updater script
###############################################################################
clone_fastfetch_repository() {
    log "Preparing update-fastfetch repository."

    local REPO_URL="https://github.com/mews-se/update-fastfetch.git"
    local DEST_DIR="/home/$SUDO_USER/update-fastfetch"
    local SCRIPT_PATH="$DEST_DIR/updatefastfetch.sh"

    if [ -d "$DEST_DIR/.git" ]; then
        log "Repository already exists at $DEST_DIR. Pulling latest changes."
        sudo -u "$SUDO_USER" git -C "$DEST_DIR" pull --ff-only || {
            log "Failed to update existing repository at $DEST_DIR." "ERROR"
            return 1
        }
    elif [ -d "$DEST_DIR" ]; then
        log "Directory $DEST_DIR exists but is not a git repository. Leaving it unchanged." "ERROR"
        return 1
    else
        sudo -u "$SUDO_USER" git clone "$REPO_URL" "$DEST_DIR" || {
            log "Failed to clone repository to $DEST_DIR." "ERROR"
            return 1
        }
        log "Repository cloned successfully to $DEST_DIR."
    fi

    cat > "$SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
#
# updatefastfetch.sh
#
# Consolidated Fastfetch updater for Debian/DietPi-style systems.
# - Detects the correct architecture automatically
# - Downloads the latest matching .deb package from GitHub releases
# - Can be run as a normal user; uses sudo only for installation
#

set -euo pipefail

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$1"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

detect_architecture() {
    local dpkg_arch=""
    local uname_arch=""

    if command -v dpkg >/dev/null 2>&1; then
        dpkg_arch="$(dpkg --print-architecture 2>/dev/null || true)"
    fi

    case "$dpkg_arch" in
        amd64) printf '%s\n' "linux-amd64.deb"; return 0 ;;
        arm64) printf '%s\n' "linux-aarch64.deb"; return 0 ;;
        armhf) printf '%s\n' "linux-arm7l.deb"; return 0 ;;
    esac

    uname_arch="$(uname -m)"
    case "$uname_arch" in
        x86_64) printf '%s\n' "linux-amd64.deb" ;;
        aarch64|arm64) printf '%s\n' "linux-aarch64.deb" ;;
        armv7l|armv7*|armhf|arm7l) printf '%s\n' "linux-arm7l.deb" ;;
        *)
            printf 'Unsupported architecture: %s\n' "$uname_arch" >&2
            exit 1
            ;;
    esac
}

get_release_url() {
    local asset_name="$1"

    curl -fsSL "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" | \
        grep '"browser_download_url":' | \
        grep "$asset_name" | \
        cut -d '"' -f 4 | \
        head -n 1
}

main() {
    require_cmd curl
    require_cmd grep
    require_cmd cut
    require_cmd head

    local asset_name=""
    local release_url=""
    local temp_deb=""
    local installer=""

    asset_name="$(detect_architecture)"
    log "Detected Fastfetch asset: $asset_name"

    release_url="$(get_release_url "$asset_name")"
    if [ -z "$release_url" ]; then
        printf 'Could not resolve release URL for asset: %s\n' "$asset_name" >&2
        exit 1
    fi

    log "Resolved release URL: $release_url"

    temp_deb="/tmp/fastfetch_latest_${asset_name}"
    rm -f "$temp_deb"

    log "Downloading package to $temp_deb"
    curl -fL "$release_url" -o "$temp_deb"

    if [ ! -s "$temp_deb" ]; then
        printf 'Downloaded file is empty: %s\n' "$temp_deb" >&2
        exit 1
    fi

    log "Installing package via apt-get"
    if command -v sudo >/dev/null 2>&1 && [ "${EUID}" -ne 0 ]; then
        sudo apt-get install -y "$temp_deb"
    else
        apt-get install -y "$temp_deb"
    fi

    rm -f "$temp_deb"
    log "Fastfetch install/update complete"
}

main "$@"
EOF

    chmod +x "$SCRIPT_PATH"
    chown "$SUDO_USER:$SUDO_USER" "$SCRIPT_PATH"

    log "Consolidated updatefastfetch.sh written to $SCRIPT_PATH"
}

###############################################################################
# FUNCTION: summary_report
# Description: Print completion summary for run_all_tasks
###############################################################################
summary_report() {
    log "Summary Report:"
    log "--------------"
    log "Version: $SCRIPT_VERSION"
    log "Profile: $PROFILE"
    log "System Update & Upgrade: Completed"
    log "Sudoers: Updated"
    log "SSH: Configured"
    log "SSH Key: Generated/Verified"
    log ".bashrc & .bash_aliases: Created/Updated"
    log "SNMPD: Installed/Configured"
    log "Docker: Repository Added & Docker CE Installed"
    log "Fastfetch Repo: Cloned/updated with consolidated updater script"
    log "Wake-on-LAN: Not included in Run all tasks"
    log "NAS Backup Script: Not included in Run all tasks"
    log "--------------"
    log "Not included in Run all tasks:"
    log "  - PiVPN installation"
    log "  - Docker removal"
    log "  - DietPi upgrades"
    log "  - Backup restore"
    log "  - Health check / paths display"
    log "  - Profile config display"
    log "  - Wake-on-LAN install"
    log "  - NAS backup script generation"
    log "--------------"
    log "All tasks completed."
}

###############################################################################
# FUNCTION: show_available_backups
# Description: Show latest backup files for important configuration files
###############################################################################
show_available_backups() {
    log "Showing available backups."

    local user_home="/home/$SUDO_USER"

    local files=(
        "/etc/sudoers.d/99-sudo-nopasswd"
        "/etc/ssh/sshd_config"
        "/etc/snmp/snmpd.conf"
        "$user_home/.bashrc"
        "$user_home/.bash_aliases"
    )

    local file latest_backup
    for file in "${files[@]}"; do
        echo
        echo "File: $file"
        latest_backup="$(find_latest_backup "$file" || true)"

        if [ -n "$latest_backup" ]; then
            echo "Latest backup: $latest_backup"
        else
            echo "Latest backup: None found"
        fi
    done
}

###############################################################################
# FUNCTION: restore_from_backup
# Description: Restore the latest backup of a selected file
###############################################################################
restore_from_backup() {
    log "Restore from backup selected."

    local user_home="/home/$SUDO_USER"
    local target_file latest_backup choice response

    echo "Select file to restore:"
    echo "  1) /etc/sudoers.d/99-sudo-nopasswd"
    echo "  2) /etc/ssh/sshd_config"
    echo "  3) /etc/snmp/snmpd.conf"
    echo "  4) $user_home/.bashrc"
    echo "  5) $user_home/.bash_aliases"
    echo "  6) Cancel"

    read -rp "Enter your choice: " choice

    case "$choice" in
        1) target_file="/etc/sudoers.d/99-sudo-nopasswd" ;;
        2) target_file="/etc/ssh/sshd_config" ;;
        3) target_file="/etc/snmp/snmpd.conf" ;;
        4) target_file="$user_home/.bashrc" ;;
        5) target_file="$user_home/.bash_aliases" ;;
        6)
            log "Restore cancelled."
            return 0
            ;;
        *)
            log "Invalid restore choice." "ERROR"
            return 1
            ;;
    esac

    latest_backup="$(find_latest_backup "$target_file" || true)"

    if [ -z "$latest_backup" ]; then
        log "No backup found for $target_file" "ERROR"
        return 1
    fi

    echo "Latest backup found:"
    echo "  $latest_backup"
    read -rp "Restore this backup? [y/N]: " response

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Restore aborted."
        return 0
    fi

    if [[ "$target_file" == /etc/* ]]; then
        sudo cp "$latest_backup" "$target_file"
    else
        sudo -u "$SUDO_USER" cp "$latest_backup" "$target_file"
    fi

    case "$target_file" in
        "/etc/ssh/sshd_config")
            if sudo sshd -t -f /etc/ssh/sshd_config; then
                restart_ssh_service
                log "SSH service restarted after restore."
            else
                log "Restored sshd_config failed validation. Review it before restarting SSH." "ERROR"
                return 1
            fi
            ;;
        "/etc/snmp/snmpd.conf")
            if sudo systemctl is-active --quiet snmpd; then
                sudo systemctl restart snmpd
                log "snmpd restarted after restore."
            else
                log "snmpd not active; restart manually if needed." "WARN"
            fi
            ;;
    esac

    log "Restore completed for $target_file"
}

###############################################################################
# FUNCTION: run_health_check
# Description: Verify status of important setup components
###############################################################################
run_health_check() {
    log "Running health check."

    local user_home="/home/$SUDO_USER"
    local ssh_key="$user_home/.ssh/id_ed25519"
    local ssh_pub="$user_home/.ssh/id_ed25519.pub"

    echo "Health check results:"
    echo "---------------------"

    if grep -q '^%sudo ALL=(ALL) NOPASSWD: ALL$' /etc/sudoers.d/99-sudo-nopasswd 2>/dev/null; then
        echo "[OK]    sudoers configured for passwordless sudo"
    else
        echo "[ERROR] sudoers entry missing or incorrect"
    fi

    if grep -Eq '^[#[:space:]]*PermitRootLogin[[:space:]]+no$' /etc/ssh/sshd_config 2>/dev/null; then
        echo "[OK]    SSH root login disabled"
    else
        echo "[ERROR] SSH root login not configured as expected"
    fi

    if grep -Eq '^[#[:space:]]*AllowUsers[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null; then
        echo "[OK]    AllowUsers configured"
    else
        echo "[WARN]  AllowUsers entry missing"
    fi

    local ssh_service
    ssh_service="$(ssh_service_name)"
    if sudo systemctl is-active --quiet "$ssh_service"; then
        echo "[OK]    ${ssh_service} service is active"
    else
        echo "[WARN]  ${ssh_service} service is not active"
    fi

    if [ -f "$ssh_key" ] && [ -f "$ssh_pub" ]; then
        echo "[OK]    SSH keypair exists"
    else
        echo "[WARN]  SSH keypair missing"
    fi

    if [ -f "$user_home/.bashrc" ]; then
        echo "[OK]    .bashrc exists"
    else
        echo "[WARN]  .bashrc missing"
    fi

    if [ -f "$user_home/.bash_aliases" ]; then
        echo "[OK]    .bash_aliases exists"
    else
        echo "[WARN]  .bash_aliases missing"
    fi

    if dpkg -l | grep -q "^ii.*snmpd"; then
        echo "[OK]    snmpd package installed"
    else
        echo "[WARN]  snmpd package not installed"
    fi

    if sudo systemctl is-active --quiet snmpd; then
        echo "[OK]    snmpd service is active"
    else
        echo "[WARN]  snmpd service is not active"
    fi

    if [ -f /etc/apt/sources.list.d/docker.list ]; then
        echo "[OK]    Docker repository configured"
    else
        echo "[WARN]  Docker repository not configured"
    fi

    if command -v docker >/dev/null 2>&1; then
        echo "[OK]    Docker command available"
    else
        echo "[WARN]  Docker not installed"
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "[OK]    Docker Compose plugin available"
    else
        echo "[WARN]  Docker Compose plugin unavailable"
    fi

    if id -nG "$SUDO_USER" | grep -qw docker; then
        echo "[OK]    User $SUDO_USER is in docker group"
    else
        echo "[WARN]  User $SUDO_USER is not in docker group"
    fi

    if command -v pivpn >/dev/null 2>&1; then
        echo "[OK]    PiVPN installed"
    else
        echo "[WARN]  PiVPN not installed"
    fi

    if [ -d "$user_home/update-fastfetch" ]; then
        echo "[OK]    update-fastfetch repository exists"
    else
        echo "[WARN]  update-fastfetch repository missing"
    fi

    if command -v wakeonlan >/dev/null 2>&1; then
        echo "[OK]    wakeonlan command available"
    else
        echo "[WARN]  wakeonlan command not available"
    fi

    if [ -f "$user_home/nas-backup.sh" ]; then
        echo "[OK]    NAS backup script exists"
    else
        echo "[WARN]  NAS backup script missing"
    fi

    if [ -f /root/.nas-credentials ]; then
        echo "[OK]    NAS credentials file exists"
    else
        echo "[WARN]  NAS credentials file missing"
    fi
}

###############################################################################
# FUNCTION: show_important_paths
# Description: Show important file paths, directories, and expected locations
###############################################################################
show_important_paths() {
    log "Showing important paths."

    local user_home="/home/$SUDO_USER"
    local short_host
    short_host="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"

    echo "Important paths:"
    echo "----------------"
    echo
    echo "User home:"
    echo "  $user_home"
    echo
    echo "Log file:"
    echo "  $LOG_FILE"
    echo
    echo "Shell:"
    echo "  $user_home/.bashrc"
    echo "  $user_home/.bash_aliases"
    echo
    echo "SSH:"
    echo "  $user_home/.ssh/"
    echo "  $user_home/.ssh/id_ed25519"
    echo "  $user_home/.ssh/id_ed25519.pub"
    echo
    echo "SNMP:"
    echo "  /etc/snmp/snmpd.conf"
    echo
    echo "Docker:"
    echo "  /etc/apt/sources.list.d/docker.list"
    echo "  /etc/apt/keyrings/docker.asc"
    echo "  /var/lib/docker"
    echo "  /var/lib/containerd"
    echo
    echo "PiVPN:"
    echo "  pivpn command: $(command -v pivpn 2>/dev/null || echo 'not installed')"
    echo "  Expected client names:"
    echo "    ${short_host}-tb7"
    echo "    ${short_host}-mbp"
    echo "    ${short_host}-iph"
    echo "    ${short_host}-len"
    echo "  Common config location:"
    echo "    $user_home/configs"
    echo
    echo "Fastfetch:"
    echo "  $user_home/update-fastfetch"
    echo
    echo "Wake-on-LAN:"
    echo "  $(command -v wakeonlan 2>/dev/null || echo 'not installed')"
    echo
    echo "NAS backup:"
    echo "  Script: $user_home/nas-backup.sh"
    echo "  Credentials: /root/.nas-credentials"
    echo "  Mount point: /mnt/nas_backup"
    echo "  NAS layout:"
    echo "    //10.0.0.100/backup/dietpibackup/${short_host}/"
    echo
    echo "Latest backups:"
    local files=(
        "/etc/sudoers.d/99-sudo-nopasswd"
        "/etc/ssh/sshd_config"
        "/etc/snmp/snmpd.conf"
        "$user_home/.bashrc"
        "$user_home/.bash_aliases"
    )
    local file latest_backup
    for file in "${files[@]}"; do
        latest_backup="$(find_latest_backup "$file" || true)"
        echo "  $file"
        echo "    ${latest_backup:-No backup found}"
    done
}

###############################################################################
# FUNCTION: show_current_profile_config
# Description: Show currently active profile-related configuration
###############################################################################
show_current_profile_config() {
    log "Showing current profile configuration."

    local short_host
    short_host="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"

    echo "Current profile configuration:"
    echo "------------------------------"
    echo "Version: $SCRIPT_VERSION"
    echo "Profile: $PROFILE"
    echo "Short hostname: $short_host"
    echo "SNMP community: $SNMP_ROCOMMUNITY"
    echo
    echo "Expected PiVPN client names:"
    echo "  ${short_host}-tb7"
    echo "  ${short_host}-mbp"
    echo "  ${short_host}-iph"
    echo "  ${short_host}-len"
    echo
    echo "SNMP hardware mode:"
    case "$PROFILE" in
        x64|x64-brk)
            echo "  x64 / DMI-based hardware info"
            ;;
        pi|pi-brk)
            echo "  Raspberry Pi / device-tree-based hardware info"
            ;;
        *)
            echo "  Unknown"
            ;;
    esac
}

###############################################################################
# FUNCTION: run_all_tasks
# Description: Run standard setup tasks only (excludes DietPi upgrades,
#              Docker removal, PiVPN, restore, and verification helpers)
###############################################################################
run_all_tasks() {
    system_update_upgrade
    update_sudoers
    configure_ssh
    generate_ssh_key
    create_bashrc
    create_bash_aliases
    install_configure_snmpd
    install_docker_repository
    install_docker_ce
    clone_fastfetch_repository
    summary_report
}

###############################################################################
# FUNCTION: menu
# Description: Original interactive menu layout
###############################################################################
menu() {
    while true; do
        clear
        echo "#####################################"
        echo "#   Automated System Configuration  #"
        echo "#####################################"
        echo "Version: $SCRIPT_VERSION"
        echo "Profile: $PROFILE"
        echo "-------------------------------------"
        echo "Please select an option:"
        echo "  1) System Update and Upgrade"
        echo "  2) DietPi: Bullseye -> Bookworm"
        echo "  3) DietPi: Bookworm -> Trixie"
        echo "  4) Update sudoers"
        echo "  5) Configure SSH"
        echo "  6) Generate SSH Key"
        echo "  7) Create/Update .bashrc"
        echo "  8) Create/Update .bash_aliases"
        echo "  9) Install and Configure SNMPD"
        echo "  10) Install Docker official repo"
        echo "  11) Install PiVPN"
        echo "  12) Install Docker and relevant tools"
        echo "  13) Remove Docker and relevant tools"
        echo "  14) Clone/update the update-fastfetch repo"
        echo "  15) Run all tasks"
        echo "  16) Show available backups"
        echo "  17) Restore from backup"
        echo "  18) Run health check"
        echo "  19) Show important paths"
        echo "  20) Show current profile config"
        echo "  21) Install Wake-on-LAN tools"
        echo "  22) Create NAS backup script"
        echo "  23) Exit"

        read -rp "Enter your choice: " choice

        case "$choice" in
            1) system_update_upgrade ;;
            2) dietpi_bullseye_to_bookworm ;;
            3) dietpi_bookworm_to_trixie ;;
            4) update_sudoers ;;
            5) configure_ssh ;;
            6) generate_ssh_key ;;
            7) create_bashrc ;;
            8) create_bash_aliases ;;
            9) install_configure_snmpd ;;
            10) install_docker_repository ;;
            11) install_pivpn ;;
            12) install_docker_ce ;;
            13) remove_docker_and_tools ;;
            14) clone_fastfetch_repository ;;
            15) run_all_tasks ;;
            16) show_available_backups ;;
            17) restore_from_backup ;;
            18) run_health_check ;;
            19) show_important_paths ;;
            20) show_current_profile_config ;;
            21) install_wakeonlan ;;
            22) create_nas_backup_script ;;
            23)
                log "Script execution completed."
                log "Please apply the following command manually to source both .bashrc and .bash_aliases files:"
                echo ". /home/$SUDO_USER/.bashrc && . /home/$SUDO_USER/.bash_aliases"
                echo "Alternatively, log out and log back in to start a new shell session."
                echo "Log file: $LOG_FILE"
                exit 0
                ;;
            *)
                echo "Invalid choice. Please select a valid option."
                ;;
        esac

        read -rp "Press Enter to continue..."
    done
}

###############################################################################
# START
###############################################################################
log "hostctl execution started. Version: $SCRIPT_VERSION"
select_profile
apply_profile_config
install_missing_packages
menu
###############################################################################
# Trap signals for graceful exit
###############################################################################
trap 'echo "Script interrupted. Exiting..."; exit 1' SIGINT SIGTERM

###############################################################################
# Validate environment: SUDO_USER must be set
###############################################################################
if [ -z "${SUDO_USER:-}" ]; then
    echo "Error: SUDO_USER is not set. Please run this script with sudo." >&2
    exit 1
fi

###############################################################################
# Script metadata
###############################################################################
SCRIPT_VERSION="v2026.04.01"
LOG_FILE="/home/$SUDO_USER/startchanges.log"

###############################################################################
# FUNCTION: log
# Description: Timestamped log helper with optional logfile in user home
###############################################################################
log() {
    local message="$1"
    local level="${2:-INFO}"
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') - [$level] $message"

    if [ "$level" = "ERROR" ]; then
        echo "$line" >&2
    else
        echo "$line"
    fi

    touch "$LOG_FILE" 2>/dev/null || true
    chown "$SUDO_USER:$SUDO_USER" "$LOG_FILE" 2>/dev/null || true
    chmod 644 "$LOG_FILE" 2>/dev/null || true
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

###############################################################################
# FUNCTION: backup_file
# Description: Create a timestamped backup of a file if it exists
###############################################################################
backup_file() {
    local target_file="$1"
    local backup_file

    if [ ! -f "$target_file" ]; then
        return 1
    fi

    backup_file="${target_file}.bak_$(date +%F_%T)"
    sudo cp "$target_file" "$backup_file"
    echo "$backup_file"
}

###############################################################################
# FUNCTION: find_latest_backup
# Description: Return latest timestamped backup for a target file
###############################################################################
find_latest_backup() {
    local target_file="$1"

    find "$(dirname "$target_file")" -maxdepth 1 -type f \
        -name "$(basename "$target_file").bak_*" -printf '%T@ %p\n' 2>/dev/null | \
        sort -nr | head -n1 | cut -d' ' -f2-
}

###############################################################################
# FUNCTION: get_os_codename
# Description: Read VERSION_CODENAME from /etc/os-release
###############################################################################
get_os_codename() {
    local distro_codename

    if [ ! -f /etc/os-release ]; then
        return 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    distro_codename="${VERSION_CODENAME:-}"

    if [ -z "$distro_codename" ]; then
        return 1
    fi

    echo "$distro_codename"
}

###############################################################################
# FUNCTION: ssh_service_name
# Description: Detect the active SSH service name
###############################################################################
ssh_service_name() {
    if sudo systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        echo "ssh"
    elif sudo systemctl list-unit-files sshd.service >/dev/null 2>&1; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

###############################################################################
# FUNCTION: restart_ssh_service
# Description: Restart SSH service if present
###############################################################################
restart_ssh_service() {
    local service_name
    service_name="$(ssh_service_name)"

    if sudo systemctl is-enabled "$service_name" >/dev/null 2>&1 ||
       sudo systemctl is-active --quiet "$service_name"; then
        sudo systemctl restart "$service_name"
        log "SSH service '$service_name' restarted successfully."
    else
        log "SSH service '$service_name' is not active/enabled. Restart manually if needed." "WARN"
    fi
}

###############################################################################
# FUNCTION: get_allowed_ssh_users
# Description: Build AllowUsers entry from available local accounts
###############################################################################
get_allowed_ssh_users() {
    local users=()
    local candidate

    for candidate in "$SUDO_USER" dietpi mews; do
        if id "$candidate" >/dev/null 2>&1; then
            users+=("$candidate")
        fi
    done

    awk 'NF { if (!seen[$0]++) printf "%s ", $0 }' < <(printf '%s\n' "${users[@]}") | sed 's/[[:space:]]*$//'
}

###############################################################################
# FUNCTION: detect_default_profile
# Description: Detect a sensible default profile from CPU architecture
###############################################################################
detect_default_profile() {
    local arch
    arch="$(uname -m || true)"
    case "$arch" in
        arm*|aarch64) echo "pi" ;;
        *) echo "x64" ;;
    esac
}

###############################################################################
# FUNCTION: select_profile
# Description: Original interactive profile selection UI
###############################################################################
PROFILE=""

select_profile() {
    local default_profile
    default_profile="$(detect_default_profile)"

    clear
    echo "#####################################"
    echo "#         Profile Selection         #"
    echo "#####################################"
    echo "Detected default: $default_profile"
    echo ""
    echo "Select which machine type this is:"
    echo "  1) x64"
    echo "  2) x64-brk"
    echo "  3) pi"
    echo "  4) pi-brk"
    echo "  5) Use detected default ($default_profile)"
    echo ""

    read -rp "Enter your choice: " pchoice
    case "$pchoice" in
        1) PROFILE="x64" ;;
        2) PROFILE="x64-brk" ;;
        3) PROFILE="pi" ;;
        4) PROFILE="pi-brk" ;;
        5|"") PROFILE="$default_profile" ;;
        *) log "Invalid profile choice. Using detected default: $default_profile" "WARN"; PROFILE="$default_profile" ;;
    esac

    log "Profile selected: $PROFILE"
}

###############################################################################
# PROFILE VARIABLES
# Description: Variables that differ between profile types
###############################################################################
SNMP_ROCOMMUNITY=""
SNMP_HARDWARE_EXTENDS=""

###############################################################################
# FUNCTION: apply_profile_config
# Description: Apply per-profile SNMP settings
###############################################################################
apply_profile_config() {
    case "$PROFILE" in
        x64)
            SNMP_ROCOMMUNITY="martin"
            SNMP_HARDWARE_EXTENDS=$(cat <<'EOL'
#Regular Linux:
extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /sys/devices/virtual/dmi/id/product_name
extend .1.3.6.1.4.1.2021.7890.3 vendor   /bin/cat /sys/devices/virtual/dmi/id/sys_vendor
extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /sys/devices/virtual/dmi/id/product_serial
# Raspberry Pi:
#extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /proc/device-tree/model
#extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /proc/device-tree/serial-number
EOL
)
            ;;
        x64-brk)
            SNMP_ROCOMMUNITY="brk"
            SNMP_HARDWARE_EXTENDS=$(cat <<'EOL'
#Regular Linux:
extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /sys/devices/virtual/dmi/id/product_name
extend .1.3.6.1.4.1.2021.7890.3 vendor   /bin/cat /sys/devices/virtual/dmi/id/sys_vendor
extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /sys/devices/virtual/dmi/id/product_serial
# Raspberry Pi:
#extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /proc/device-tree/model
#extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /proc/device-tree/serial-number
EOL
)
            ;;
        pi)
            SNMP_ROCOMMUNITY="martin"
            SNMP_HARDWARE_EXTENDS=$(cat <<'EOL'
#Regular Linux:
#extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /sys/devices/virtual/dmi/id/product_name
#extend .1.3.6.1.4.1.2021.7890.3 vendor   /bin/cat /sys/devices/virtual/dmi/id/sys_vendor
#extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /sys/devices/virtual/dmi/id/product_serial
# Raspberry Pi:
extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /proc/device-tree/model
extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /proc/device-tree/serial-number
EOL
)
            ;;
        pi-brk)
            SNMP_ROCOMMUNITY="brk"
            SNMP_HARDWARE_EXTENDS=$(cat <<'EOL'
#Regular Linux:
#extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /sys/devices/virtual/dmi/id/product_name
#extend .1.3.6.1.4.1.2021.7890.3 vendor   /bin/cat /sys/devices/virtual/dmi/id/sys_vendor
#extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /sys/devices/virtual/dmi/id/product_serial
# Raspberry Pi:
extend .1.3.6.1.4.1.2021.7890.2 hardware /bin/cat /proc/device-tree/model
extend .1.3.6.1.4.1.2021.7890.4 serial   /bin/cat /proc/device-tree/serial-number
EOL
)
            ;;
        *)
            log "Unknown profile '$PROFILE'. Valid: x64, x64-brk, pi, pi-brk" "ERROR"
            exit 1
            ;;
    esac
}

###############################################################################
# REQUIRED COMMANDS / PACKAGE MAP
# Description: Commands to verify/install before running functions
###############################################################################
declare -A required_commands=(
    [sudo]="sudo"
    [apt-get]="apt-get"
    [sed]="sed"
    [ssh-keygen]="openssh-client"
    [systemctl]="systemd"
    [dpkg]="dpkg"
    [curl]="curl"
    [git]="git"
    [nc]="netcat-traditional"
    [script]="bsdextrautils"
)

###############################################################################
# FUNCTION: install_missing_packages
# Description: Ensure all required commands/packages are available
###############################################################################
install_missing_packages() {
    local missing_packages=()
    local failed_packages=()
    local cmd pkg

    for cmd in "${!required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_packages+=("${required_commands[$cmd]}")
        else
            log "$cmd is already installed."
        fi
    done

    if [ "${#missing_packages[@]}" -gt 0 ]; then
        log "Installing missing packages: ${missing_packages[*]}"

        if ! sudo apt-get update; then
            log "Error updating package lists. Please check your sources and network." "ERROR"
            exit 1
        fi

        if ! sudo apt-get install -y "${missing_packages[@]}"; then
            log "Bulk installation failed. Retrying packages one by one..." "WARN"
            for pkg in "${missing_packages[@]}"; do
                if ! sudo apt-get install -y "$pkg"; then
                    failed_packages+=("$pkg")
                    log "Failed to install $pkg even after retry." "ERROR"
                else
                    log "Successfully installed $pkg after retry."
                fi
            done

            if [ "${#failed_packages[@]}" -gt 0 ]; then
                log "The following packages could not be installed: ${failed_packages[*]}" "ERROR"
                exit 1
            fi
        else
            log "Missing packages installed successfully."
        fi
    else
        log "All required packages are already installed."
    fi

    for cmd in "${!required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "Critical Error: $cmd is still not available after installation attempts." "ERROR"
            exit 1
        fi
    done

    log "All required commands are now available."
}

###############################################################################
# FUNCTION: preflight_ssh
# Description: Check basic SSH prerequisites before editing sshd_config
###############################################################################
preflight_ssh() {
    if [ ! -f /etc/ssh/sshd_config ]; then
        log "/etc/ssh/sshd_config not found." "ERROR"
        return 1
    fi
    return 0
}

###############################################################################
# FUNCTION: preflight_docker
# Description: Check basic prerequisites before Docker repo installation
###############################################################################
preflight_docker() {
    if [ ! -f /etc/os-release ]; then
        log "/etc/os-release not found." "ERROR"
        return 1
    fi

    if ! get_os_codename >/dev/null; then
        log "Could not determine Debian codename." "ERROR"
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log "curl is required for Docker repository installation." "ERROR"
        return 1
    fi

    return 0
}

###############################################################################
# FUNCTION: preflight_pivpn
# Description: Check basic prerequisites before PiVPN installation
###############################################################################
preflight_pivpn() {
    if ! command -v curl >/dev/null 2>&1; then
        log "curl is required for PiVPN installation." "ERROR"
        return 1
    fi

    if ! command -v script >/dev/null 2>&1; then
        log "'script' command is required for PiVPN installer PTY handling." "ERROR"
        return 1
    fi

    return 0
}

###############################################################################
# FUNCTION: system_update_upgrade
# Description: Update package lists and perform full upgrade
###############################################################################
system_update_upgrade() {
    log "Running system update and upgrade."
    sudo apt-get update
    sudo apt-get dist-upgrade -y
    log "System update and upgrade completed successfully."
}

###############################################################################
# FUNCTION: dietpi_bullseye_to_bookworm
# Description: Run DietPi Bullseye -> Bookworm upgrade in a PTY
###############################################################################
dietpi_bullseye_to_bookworm() {
    log "DietPi upgrade: Bullseye -> Bookworm"
    script -qec "sudo bash -c \"\$(curl -sSf 'https://raw.githubusercontent.com/MichaIng/DietPi/dev/.meta/dietpi-bookworm-upgrade')\"" /dev/null
    log "DietPi upgrade Bullseye -> Bookworm finished."
}

###############################################################################
# FUNCTION: dietpi_bookworm_to_trixie
# Description: Run DietPi Bookworm -> Trixie upgrade in a PTY
###############################################################################
dietpi_bookworm_to_trixie() {
    log "DietPi upgrade: Bookworm -> Trixie"
    script -qec "sudo bash -c \"\$(curl -sSf 'https://raw.githubusercontent.com/MichaIng/DietPi/dev/.meta/dietpi-trixie-upgrade')\"" /dev/null
    log "DietPi upgrade Bookworm -> Trixie finished."
}

###############################################################################
# FUNCTION: update_sudoers
# Description: Enable passwordless sudo for the sudo group
###############################################################################
update_sudoers() {
    log "Updating sudoers."

    local sudoers_dropin="/etc/sudoers.d/99-sudo-nopasswd"
    local sudoers_content="%sudo ALL=(ALL) NOPASSWD: ALL"

    if [ -f "$sudoers_dropin" ]; then
        backup_file "$sudoers_dropin" >/dev/null || true
    fi

    printf '%s\n' "$sudoers_content" | sudo tee "$sudoers_dropin" > /dev/null
    sudo chmod 440 "$sudoers_dropin"

    if sudo visudo -cf /etc/sudoers >/dev/null 2>&1; then
        log "sudoers drop-in updated successfully at $sudoers_dropin."
    else
        sudo rm -f "$sudoers_dropin"
        log "visudo validation failed. Removed invalid sudoers drop-in." "ERROR"
        return 1
    fi
}

###############################################################################
# FUNCTION: configure_ssh
# Description: Disable root SSH login and restrict allowed users
###############################################################################
configure_ssh() {
    preflight_ssh || return 1

    log "Configuring SSH."
    local sshd_config="/etc/ssh/sshd_config"
    local allow_users
    allow_users="$(get_allowed_ssh_users)"

    backup_file "$sshd_config" >/dev/null || true

    sudo sed -E -i 's/^[#[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin no/' "$sshd_config"
    if ! sudo grep -Eq '^[[:space:]]*PermitRootLogin[[:space:]]+' "$sshd_config"; then
        printf '%s\n' 'PermitRootLogin no' | sudo tee -a "$sshd_config" > /dev/null
    fi
    log "PermitRootLogin set to no."

    if [ -n "$allow_users" ]; then
        if sudo grep -Eq '^[#[:space:]]*AllowUsers[[:space:]]+' "$sshd_config"; then
            sudo sed -E -i "s|^[#[:space:]]*AllowUsers[[:space:]]+.*|AllowUsers $allow_users|" "$sshd_config"
        else
            printf '%s\n' "AllowUsers $allow_users" | sudo tee -a "$sshd_config" > /dev/null
        fi
        log "AllowUsers set to: $allow_users"
    else
        log "No valid local users found for AllowUsers. Skipping AllowUsers update." "WARN"
    fi

    if sudo sshd -t -f "$sshd_config"; then
        restart_ssh_service
        log "SSH configuration updated successfully."
    else
        log "sshd_config validation failed. Restore the latest backup before retrying." "ERROR"
        return 1
    fi
}

###############################################################################
# FUNCTION: generate_ssh_key
# Description: Generate ed25519 SSH key for invoking sudo user
###############################################################################
generate_ssh_key() {
    log "Generating SSH key."

    local SSH_DIR="/home/$SUDO_USER/.ssh"
    local KEY_FILE="$SSH_DIR/id_ed25519"

    if [ -f "$KEY_FILE" ]; then
        log "SSH key already exists for $SUDO_USER. Skipping generation."
    else
        sudo -u "$SUDO_USER" mkdir -p "$SSH_DIR"
        sudo -u "$SUDO_USER" ssh-keygen -t ed25519 -f "$KEY_FILE" -N ""
        log "Ed25519 SSH key generated successfully."
    fi

    sudo chmod 700 "$SSH_DIR"
    sudo chmod 600 "$KEY_FILE"
    if [ -f "$KEY_FILE.pub" ]; then
        sudo chmod 644 "$KEY_FILE.pub"
    fi
}

###############################################################################
# FUNCTION: create_bashrc
# Description: Replace ~/.bashrc with curated default
###############################################################################
create_bashrc() {
    log "Creating/updating .bashrc file."

    local BASHRC_FILE="/home/$SUDO_USER/.bashrc"

    if [ -f "$BASHRC_FILE" ]; then
        sudo -u "$SUDO_USER" cp "$BASHRC_FILE" "${BASHRC_FILE}.bak_$(date +%F_%T)"
        sudo -u "$SUDO_USER" rm "$BASHRC_FILE"
        log "Removed existing .bashrc file (backup created)."
    fi

    sudo -u "$SUDO_USER" mkdir -p "$(dirname "$BASHRC_FILE")"

    cat <<'EOL' | sudo -u "$SUDO_USER" tee -a "$BASHRC_FILE" > /dev/null
case $- in
    *i*) ;;
    *) return;;
esac

HISTCONTROL=ignoreboth
shopt -s histappend
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s checkwinsize

if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
        color_prompt=yes
    else
        color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w \$\[\033[00m\] '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

if [ -f ~/.bash_aliases ]; then
    source ~/.bash_aliases
fi
EOL

    log ".bashrc file created/updated successfully for user: $SUDO_USER."
}

###############################################################################
# FUNCTION: create_bash_aliases
# Description: Merge curated aliases with optional retention of custom aliases
###############################################################################
create_bash_aliases() {
    log "Creating/updating .bash_aliases file with interactive review."

    local USER_HOME="/home/$SUDO_USER"
    local ALIASES_FILE="$USER_HOME/.bash_aliases"
    local BACKUP_FILE
    local TEMP_FILE

    BACKUP_FILE="$ALIASES_FILE.bak_$(date +%F_%T)"
    TEMP_FILE=$(sudo -u "$SUDO_USER" mktemp "$USER_HOME/.bash_aliases.tmp.XXXXXX")

    local RED GREEN YELLOW CYAN NC
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'

    if [ -f "$ALIASES_FILE" ]; then
        sudo -u "$SUDO_USER" cp "$ALIASES_FILE" "$BACKUP_FILE"
        log "Backup created at $BACKUP_FILE"
    fi

    local NEW_ALIASES
    NEW_ALIASES=$(cat <<'EOL'
alias apta="sudo apt-get update && sudo apt-get dist-upgrade -y && sudo apt-get autoremove -y && sudo apt-get clean"
alias brkpi="ssh dietpi@10.0.1.8"
alias dcdown="docker compose down"
alias dclog="docker compose logs -f"
alias dcpull="docker compose pull"
alias dcstop="docker compose stop"
alias dcupd="docker compose up -d"
alias dcupdlog="docker compose up -d && docker compose logs -f"
alias dellpi="ssh dietpi@10.0.0.6"
alias fa="fastfetch"
alias fanoff="sudo systemctl stop fancontrol.service"
alias fanon="sudo systemctl start fancontrol.service"
alias ff="fastfetch -c all.jsonc"
alias flight="ssh root@10.0.1.12"
alias kodipi="ssh dietpi@10.0.0.7"
alias london="ssh dietpi@london.stockzell.se"
alias mm="ssh martin@10.0.0.11"
alias nyc="ssh dietpi@newyork.stockzell.se"
alias nyc2="ssh dietpi@newyork2.stockzell.se"
alias norway="ssh dietpi@norway.stockzell.se"
alias optiplex="ssh mews@10.0.1.6"
alias pfsense="ssh -p 2221 admin@10.0.0.1"
alias pfsensebrk="ssh -p 2221 admin@10.0.1.1"
alias pizerow="ssh dietpi@10.0.0.124"
alias prox="ssh root@10.0.0.99"
alias reb="sudo reboot"
alias sen="watch -n 1 sensors"
alias tb="ssh dietpi@10.0.0.97"
alias teslamate="ssh dietpi@10.0.0.14"
alias testpi="ssh dietpi@10.0.0.8"
alias testpi5="ssh dietpi@10.0.0.17"
alias woldellpi="wakeonlan 70:b5:e8:76:12:8d"
alias wolprox="wakeonlan c0:25:a5:94:75:ee"
alias woltb7="wakeonlan a8:5e:45:cd:db:cb"
alias wolmm="wakeonlan ac:87:a3:38:d0:00"
alias wolnas="wakeonlan 90:09:d0:1f:95:b7"
EOL
)

    declare -A new_aliases
    declare -A final_aliases

    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*alias[[:space:]]+([^=]+)= ]]; then
            local name
            name="${BASH_REMATCH[1]}"
            new_aliases["$name"]="$line"
        fi
    done <<< "$NEW_ALIASES"

    local found_custom=false

    if [ -f "$ALIASES_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ ^[[:space:]]*alias[[:space:]]+([^=]+)= ]]; then
                local alias_name existing_line response
                alias_name="${BASH_REMATCH[1]}"
                existing_line="$line"
                if [[ -z "${new_aliases[$alias_name]+exists}" ]]; then
                    found_custom=true
                    echo -e "\n${YELLOW}Found alias not in script: ${CYAN}$alias_name${NC}"
                    echo -e "  ${CYAN}$existing_line${NC}"
                    echo -ne "${YELLOW}Keep this alias? [Y/n]: ${NC}" > /dev/tty
                    IFS= read -r response < /dev/tty
                    IFS= read -r -t 0.1 -n 10000 < /dev/tty 2>/dev/null || true
                    if [[ -z "$response" || "$response" =~ ^[Yy]$ ]]; then
                        final_aliases["$alias_name"]="$existing_line"
                        echo -e "${GREEN}→ Keeping: $alias_name${NC}"
                    else
                        echo -e "${RED}→ Removed: $alias_name${NC}"
                    fi
                fi
            else
                echo "$line" >> "$TEMP_FILE"
            fi
        done < "$ALIASES_FILE"
    fi

    if [ "$found_custom" = false ]; then
        log "No custom aliases found for review."
    fi

    local alias
    for alias in "${!new_aliases[@]}"; do
        final_aliases["$alias"]="${new_aliases[$alias]}"
    done

    local alias_line
    for alias_line in "${final_aliases[@]}"; do
        echo "$alias_line"
    done | sort >> "$TEMP_FILE"

    sudo mv "$TEMP_FILE" "$ALIASES_FILE"
    sudo chown "$SUDO_USER:$SUDO_USER" "$ALIASES_FILE"
    log ".bash_aliases updated successfully with interactive selections and sorted output."
}

###############################################################################
# FUNCTION: install_configure_snmpd
# Description: Install SNMPD and write profile-specific configuration
###############################################################################
install_configure_snmpd() {
    log "Installing and configuring SNMPD."

    if ! dpkg -l | grep -q "^ii.*lm-sensors"; then
        sudo apt-get install -y lm-sensors
        log "lm-sensors package installed successfully."
    else
        log "lm-sensors package is already installed. No changes needed."
    fi

    if ! dpkg -l | grep -q "^ii.*snmpd"; then
        sudo apt-get install -y snmpd
        log "snmpd package installed successfully."
    else
        log "snmpd package is already installed. No changes needed."
    fi

    local SNMPD_CONF_FILE="/etc/snmp/snmpd.conf"
    if [ -f "$SNMPD_CONF_FILE" ]; then
        sudo cp "$SNMPD_CONF_FILE" "${SNMPD_CONF_FILE}.bak_$(date +%F_%T)"
        log "Existing snmpd.conf backed up."
    fi

    local SNMPD_CONF_CONTENT
    SNMPD_CONF_CONTENT=$(cat <<EOF
sysLocation    Sitting on the Dock of the Bay
sysContact     Me <me@example.org>
sysServices    72
master  agentx
agentaddress  udp:161
view   systemonly  included   .1.3.6.1.2.1.1
view   systemonly  included   .1.3.6.1.2.1.25.1
rocommunity ${SNMP_ROCOMMUNITY}
rouser authPrivUser authpriv -V systemonly
includeAllDisks  10%
extend uptime /bin/cat /proc/uptime
extend .1.3.6.1.4.1.2021.7890.1 distro /usr/local/bin/distro
${SNMP_HARDWARE_EXTENDS}
EOF
)

    echo "$SNMPD_CONF_CONTENT" | sudo tee "$SNMPD_CONF_FILE" > /dev/null
    log "snmpd.conf file created/overwritten successfully at $SNMPD_CONF_FILE."

    sudo chown root:root "$SNMPD_CONF_FILE"
    log "Ownership of $SNMPD_CONF_FILE set to root:root."

    if sudo systemctl is-active --quiet snmpd; then
        sudo systemctl reload snmpd
        log "SNMPD service reloaded successfully."
    else
        log "SNMPD service is not active; start/restart manually if needed." "WARN"
    fi
}

###############################################################################
# FUNCTION: install_docker_repository
# Description: Add Docker official repository
###############################################################################
install_docker_repository() {
    preflight_docker || return 1

    log "Installing Docker repository."

    sudo apt-get update
    sudo apt-get install -y ca-certificates curl

    sudo install -m 0755 -d /etc/apt/keyrings

    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    local distro_codename
    distro_codename="$(get_os_codename)"

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      ${distro_codename} stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    log "Docker repository installed successfully."
}

###############################################################################
# FUNCTION: install_pivpn
# Description: Install PiVPN via PTY and optionally create default clients
###############################################################################
install_pivpn() {
    preflight_pivpn || return 1

    log "Installing PiVPN."

    local tmp
    tmp="$(mktemp)"

    curl -fsSL https://install.pivpn.io -o "$tmp"
    script -qec "sudo bash '$tmp'" /dev/null
    rm -f "$tmp"

    log "PiVPN installation completed."

    echo
    read -rp "Create PiVPN configs? [Y/n]: " ans < /dev/tty
    if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
        create_pivpn_clients
    else
        log "Skipping PiVPN client creation."
    fi
}

###############################################################################
# FUNCTION: create_pivpn_clients
# Description: Create hostname-based clients and optionally show iPhone QR code
###############################################################################
create_pivpn_clients() {
    log "Creating PiVPN client configurations."

    if ! command -v pivpn >/dev/null 2>&1; then
        log "PiVPN command not found. Install PiVPN first." "ERROR"
        return 1
    fi

    local HOST
    HOST="$(hostname -s)"

    local CLIENTS=(
        "${HOST}-tb7"
        "${HOST}-mbp"
        "${HOST}-iph"
        "${HOST}-len"
    )

    local client
    for client in "${CLIENTS[@]}"; do
        if pivpn list | grep -q "$client"; then
            log "Exists: $client"
        else
            log "Creating client: $client"
            pivpn add -n "$client" -ip auto
        fi
    done

    echo
    read -rp "Show QR for ${HOST}-iph? [Y/n]: " qr < /dev/tty
    if [[ -z "$qr" || "$qr" =~ ^[Yy]$ ]]; then
        pivpn -qr "${HOST}-iph" < /dev/tty > /dev/tty 2>/dev/tty
    fi
}

###############################################################################
# FUNCTION: install_docker_ce
# Description: Install Docker Engine and related tools
###############################################################################
install_docker_ce() {
    log "Installing Docker CE and related tools."
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
                           docker-buildx-plugin docker-compose-plugin \
                           docker-ce-rootless-extras
    sudo usermod -aG docker "$SUDO_USER"
    log "Docker CE and tools installed successfully. User added to group 'docker'."
}

###############################################################################
# FUNCTION: remove_docker_and_tools
# Description: Remove Docker packages, repo files, keys, and data directories
###############################################################################
remove_docker_and_tools() {
    log "Removing Docker CE and related tools."

    sudo apt purge -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin \
        docker-ce-rootless-extras

    sudo rm -f /etc/apt/sources.list.d/docker.sources
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /etc/apt/keyrings/docker.asc

    sudo rm -rf /var/lib/docker
    sudo rm -rf /var/lib/containerd

    log "Docker packages, repository configuration, and data directories removed."
}

###############################################################################
# FUNCTION: install_wakeonlan
# Description: Install Wake-on-LAN tools
###############################################################################
install_wakeonlan() {
    log "Installing Wake-on-LAN tools."

    if dpkg -l | grep -q "^ii.*wakeonlan"; then
        log "wakeonlan is already installed. No changes needed."
    else
        if sudo apt-get install -y wakeonlan; then
            log "wakeonlan installed successfully."
        else
            log "Failed to install wakeonlan." "ERROR"
            return 1
        fi
    fi

    if command -v wakeonlan &>/dev/null; then
        log "wakeonlan command is available."
    else
        log "wakeonlan command not found after installation." "ERROR"
        return 1
    fi

    log "Wake-on-LAN setup completed."
}

###############################################################################
# FUNCTION: create_nas_backup_script
# Description: Generate standalone NAS backup script using SMB credentials file
###############################################################################
create_nas_backup_script() {
    log "Creating NAS backup script."

    local invoking_user
    local backup_script
    local credentials_file="/root/.nas-credentials"
    local nas_username=""
    local nas_password=""

    invoking_user="${SUDO_USER:-$(id -un)}"
    backup_script="/home/$invoking_user/nas-backup.sh"

    if [ ! -f "$credentials_file" ]; then
        echo
        read -rp "Enter NAS username: " nas_username < /dev/tty
        read -rsp "Enter NAS password: " nas_password < /dev/tty
        echo

        if [ -z "$nas_username" ] || [ -z "$nas_password" ]; then
            log "NAS credentials cannot be empty." "ERROR"
            return 1
        fi

        sudo install -m 600 /dev/null "$credentials_file"
        printf 'username=%s\npassword=%s\n' "$nas_username" "$nas_password" | sudo tee "$credentials_file" > /dev/null
        sudo chmod 600 "$credentials_file"
        log "Created credentials file at $credentials_file"
    else
        sudo chmod 600 "$credentials_file"
        log "Credentials file already exists at $credentials_file"
    fi

    cat > "$backup_script" <<'EOF'
#!/usr/bin/env bash
#
# nas-backup.sh
#
# DietPi/Debian NAS backup script with local logging.
# - CIFS mount using /root/.nas-credentials
# - DietPi-like filter model
# - Includes /home and /mnt/dietpi_userdata
# - Excludes known runtime/problem paths
# - Writes the physical log file to the invoking user's home directory
# - Keeps rsync CLI behavior close to the original script
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------

NAS_HOST="10.0.0.100"
NAS_SHARE="backup"
NAS_MOUNT_POINT="/mnt/nas_backup"
NAS_BACKUP_ROOT="dietpibackup"
CREDENTIALS_FILE="/root/.nas-credentials"

HOST_NAME="$(hostname -s)"
LOCK_FILE="/var/run/nas-backup.lock"
EXCLUDES_FILE=""

# -----------------------------------------------------------------------------
# User / log path resolution
# -----------------------------------------------------------------------------

resolve_invoking_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
    else
        id -un
    fi
}

resolve_home_dir() {
    local user_name="$1"
    local home_dir

    home_dir="$(getent passwd "$user_name" | cut -d: -f6 || true)"

    if [[ -n "$home_dir" ]]; then
        printf '%s\n' "$home_dir"
        return 0
    fi

    if [[ "$user_name" == "root" ]]; then
        printf '%s\n' "/root"
        return 0
    fi

    printf '%s\n' "/home/$user_name"
}

INVOKING_USER="$(resolve_invoking_user)"
INVOKING_HOME="$(resolve_home_dir "$INVOKING_USER")"
LOCAL_LOG="${INVOKING_HOME}/nas-backup.log"

HOST_DIR="${NAS_MOUNT_POINT}/${NAS_BACKUP_ROOT}/${HOST_NAME}"
MOUNT_OPTS="credentials=${CREDENTIALS_FILE},uid=0,gid=0,file_mode=0600,dir_mode=0700,vers=3.0,mfsymlinks"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

timestamp() {
    date '+%F %T'
}

log() {
    local message="$1"
    local line="[$(timestamp)] $message"
    printf '%s\n' "$line" | tee -a "$LOCAL_LOG"
}

prepare_log_file() {
    mkdir -p "$INVOKING_HOME"
    touch "$LOCAL_LOG"

    if id "$INVOKING_USER" >/dev/null 2>&1; then
        chown "$INVOKING_USER:$INVOKING_USER" "$LOCAL_LOG" 2>/dev/null || true
    fi

    chmod 0644 "$LOCAL_LOG" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Cleanup / locking
# -----------------------------------------------------------------------------

cleanup() {
    local rc=$?

    if [ "${DIETPI_SERVICES_STOPPED:-0}" -eq 1 ] && [ -x /boot/dietpi/dietpi-services ]; then
        /boot/dietpi/dietpi-services start || true
    fi

    if mountpoint -q "$NAS_MOUNT_POINT"; then
        log "Unmounting NAS share: $NAS_MOUNT_POINT"
        umount "$NAS_MOUNT_POINT" || log "Warning: failed to unmount $NAS_MOUNT_POINT"
    fi

    if [[ -n "${EXCLUDES_FILE:-}" && -f "${EXCLUDES_FILE}" ]]; then
        rm -f "$EXCLUDES_FILE"
    fi

    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi

    if (( rc == 0 )); then
        log "NAS backup finished successfully"
    else
        log "NAS backup ended with exit code $rc"
    fi

    if id "$INVOKING_USER" >/dev/null 2>&1; then
        chown "$INVOKING_USER:$INVOKING_USER" "$LOCAL_LOG" 2>/dev/null || true
    fi

    exit "$rc"
}

acquire_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        log "Another backup appears to be running: $LOCK_FILE exists"
        exit 1
    fi
    touch "$LOCK_FILE"
}

DIETPI_SERVICES_STOPPED=0
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must be run as root." >&2
        echo "Run it with: sudo bash $0" >&2
        exit 1
    fi
}

check_requirements() {
    local cmds=(mount umount mountpoint rsync hostname awk grep tee mktemp getent cut apt-get)
    local cmd

    for cmd in "${cmds[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "Missing required command: $cmd" >&2
            exit 1
        }
    done

    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        echo "Missing credentials file: $CREDENTIALS_FILE" >&2
        exit 1
    fi

    chmod 600 "$CREDENTIALS_FILE" || true
}

# -----------------------------------------------------------------------------
# Service handling
# -----------------------------------------------------------------------------

stop_services() {
    if [ -x /boot/dietpi/dietpi-services ]; then
        log "Stopping DietPi services for backup consistency."
        /boot/dietpi/dietpi-services stop || true
        DIETPI_SERVICES_STOPPED=1
        return 0
    fi

    log "Stopping selected services before backup"
    systemctl stop cron 2>/dev/null || true
    systemctl stop crond 2>/dev/null || true
    systemctl stop snmpd 2>/dev/null || true
    systemctl stop docker 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# NAS mounting
# -----------------------------------------------------------------------------

ensure_mountpoint() {
    mkdir -p "$NAS_MOUNT_POINT"
}

mount_nas() {
    if mountpoint -q "$NAS_MOUNT_POINT"; then
        log "NAS share already mounted at $NAS_MOUNT_POINT"
        return 0
    fi

    log "Mounting //$NAS_HOST/$NAS_SHARE to $NAS_MOUNT_POINT"
    mount -t cifs "//$NAS_HOST/$NAS_SHARE" "$NAS_MOUNT_POINT" -o "$MOUNT_OPTS"
    log "NAS share mounted successfully"
}

prepare_target() {
    mkdir -p "$HOST_DIR"
    log "Backup target ready: $HOST_DIR"
}

write_metadata() {
    log "Saving metadata."

    dpkg --get-selections > "$HOST_DIR/package-list.txt" 2>/dev/null || true
    crontab -l > "$HOST_DIR/root-crontab.txt" 2>/dev/null || true
    systemctl list-unit-files > "$HOST_DIR/systemd-unit-files.txt" 2>/dev/null || true
    hostname > "$HOST_DIR/hostname.txt" 2>/dev/null || true
    uname -a > "$HOST_DIR/uname.txt" 2>/dev/null || true
    date > "$HOST_DIR/backup-date.txt" 2>/dev/null || true

    if [[ -r /etc/os-release ]]; then
        cp /etc/os-release "$HOST_DIR/os-release.txt" 2>/dev/null || true
    fi

    if command -v docker >/dev/null 2>&1; then
        docker ps -a > "$HOST_DIR/docker-ps.txt" 2>/dev/null || true
        docker images > "$HOST_DIR/docker-images.txt" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Filter file
# -----------------------------------------------------------------------------

create_excludes_file() {
    EXCLUDES_FILE="$(mktemp /tmp/nas-backup-excludes.XXXXXX)"

    cat > "$EXCLUDES_FILE" <<'EOF_EXCLUDES'
- /mnt/nas_backup/
+ /home/
+ /home/**
+ /mnt/
+ /mnt/dietpi_userdata/
+ /mnt/dietpi_userdata/**
- /mnt/*
- /media/*
- /dev/
- /proc/
- /run/
- /sys/
- /tmp/
- /var/swap
- /.swap*
- /etc/fake-hwclock.data
- /lost+found/
- /var/cache/apt/*
- /var/lib/docker/
- /var/lib/containerd/
- /var/lib/containers/
- /var/agentx/
- /var/run/*
- /var/tmp/*
- /usr/share/man/
EOF_EXCLUDES

    log "Created exclude file: $EXCLUDES_FILE"
}

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------

run_backup() {
    log "Starting rsync backup"

    rsync -aH --whole-file --inplace --numeric-ids --delete --delete-delay \
        --safe-links \
        --info=progress2 \
        --info=name0 \
        --filter="merge ${EXCLUDES_FILE}" \
        / "$HOST_DIR" 2>&1 | tee -a "$LOCAL_LOG"

    log "rsync completed"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    require_root
    check_requirements
    prepare_log_file
    acquire_lock

    log "Starting NAS backup script."

    apt-get update
    apt-get install -y cifs-utils rsync

    ensure_mountpoint
    mount_nas
    prepare_target
    create_excludes_file
    stop_services
    run_backup
    write_metadata

    log "Backup completed successfully to $HOST_DIR"
}

main "$@"
EOF

    chmod +x "$backup_script"
    chown "$invoking_user:$invoking_user" "$backup_script"

    log "NAS backup script created at $backup_script"
    echo
    echo "Created files:"
    echo "  Backup script: $backup_script"
    echo "  Credentials:   $credentials_file"
    echo "  Local log:     /home/$invoking_user/nas-backup.log"
    echo
    echo "NAS layout will be:"
    echo "  //10.0.0.100/backup/dietpibackup/<short-hostname>/"
    echo
    echo "Behavior:"
    echo "  Existing backup is updated in place"
    echo "  New files are added"
    echo "  Changed files are updated"
    echo "  Removed files are deleted from backup"
    echo
    echo "Included rules:"
    echo "  /home/"
    echo "  /mnt/dietpi_userdata/"
    echo "Excluded rules:"
    echo "  /mnt/*, /media/*, /dev/, /proc/, /run/, /sys/, /tmp/"
    echo "  /var/swap, /.swap*, /etc/fake-hwclock.data, /lost+found/"
    echo "  /var/cache/apt/*, /var/lib/docker/, /var/lib/containerd/"
    echo "  /var/lib/containers/, /var/agentx/, /var/run/*, /var/tmp/*"
    echo "  /usr/share/man/"
}

###############################################################################
# FUNCTION: clone_fastfetch_repository
# Description: Clone/update update-fastfetch and write consolidated updater script
###############################################################################
clone_fastfetch_repository() {
    log "Preparing update-fastfetch repository."

    local REPO_URL="https://github.com/mews-se/update-fastfetch.git"
    local DEST_DIR="/home/$SUDO_USER/update-fastfetch"
    local SCRIPT_PATH="$DEST_DIR/updatefastfetch.sh"

    if [ -d "$DEST_DIR/.git" ]; then
        log "Repository already exists at $DEST_DIR. Pulling latest changes."
        sudo -u "$SUDO_USER" git -C "$DEST_DIR" pull --ff-only || {
            log "Failed to update existing repository at $DEST_DIR." "ERROR"
            return 1
        }
    elif [ -d "$DEST_DIR" ]; then
        log "Directory $DEST_DIR exists but is not a git repository. Leaving it unchanged." "ERROR"
        return 1
    else
        sudo -u "$SUDO_USER" git clone "$REPO_URL" "$DEST_DIR" || {
            log "Failed to clone repository to $DEST_DIR." "ERROR"
            return 1
        }
        log "Repository cloned successfully to $DEST_DIR."
    fi

    cat > "$SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
#
# updatefastfetch.sh
#
# Consolidated Fastfetch updater for Debian/DietPi-style systems.
# - Detects the correct architecture automatically
# - Downloads the latest matching .deb package from GitHub releases
# - Can be run as a normal user; uses sudo only for installation
#

set -euo pipefail

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$1"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

detect_architecture() {
    local dpkg_arch=""
    local uname_arch=""

    if command -v dpkg >/dev/null 2>&1; then
        dpkg_arch="$(dpkg --print-architecture 2>/dev/null || true)"
    fi

    case "$dpkg_arch" in
        amd64) printf '%s\n' "linux-amd64.deb"; return 0 ;;
        arm64) printf '%s\n' "linux-aarch64.deb"; return 0 ;;
        armhf) printf '%s\n' "linux-arm7l.deb"; return 0 ;;
    esac

    uname_arch="$(uname -m)"
    case "$uname_arch" in
        x86_64) printf '%s\n' "linux-amd64.deb" ;;
        aarch64|arm64) printf '%s\n' "linux-aarch64.deb" ;;
        armv7l|armv7*|armhf|arm7l) printf '%s\n' "linux-arm7l.deb" ;;
        *)
            printf 'Unsupported architecture: %s\n' "$uname_arch" >&2
            exit 1
            ;;
    esac
}

get_release_url() {
    local asset_name="$1"

    curl -fsSL "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" | \
        grep '"browser_download_url":' | \
        grep "$asset_name" | \
        cut -d '"' -f 4 | \
        head -n 1
}

main() {
    require_cmd curl
    require_cmd grep
    require_cmd cut
    require_cmd head

    local asset_name=""
    local release_url=""
    local temp_deb=""
    local installer=""

    asset_name="$(detect_architecture)"
    log "Detected Fastfetch asset: $asset_name"

    release_url="$(get_release_url "$asset_name")"
    if [ -z "$release_url" ]; then
        printf 'Could not resolve release URL for asset: %s\n' "$asset_name" >&2
        exit 1
    fi

    log "Resolved release URL: $release_url"

    temp_deb="/tmp/fastfetch_latest_${asset_name}"
    rm -f "$temp_deb"

    log "Downloading package to $temp_deb"
    curl -fL "$release_url" -o "$temp_deb"

    if [ ! -s "$temp_deb" ]; then
        printf 'Downloaded file is empty: %s\n' "$temp_deb" >&2
        exit 1
    fi

    log "Installing package via apt-get"
    if command -v sudo >/dev/null 2>&1 && [ "${EUID}" -ne 0 ]; then
        sudo apt-get install -y "$temp_deb"
    else
        apt-get install -y "$temp_deb"
    fi

    rm -f "$temp_deb"
    log "Fastfetch install/update complete"
}

main "$@"
EOF

    chmod +x "$SCRIPT_PATH"
    chown "$SUDO_USER:$SUDO_USER" "$SCRIPT_PATH"

    log "Consolidated updatefastfetch.sh written to $SCRIPT_PATH"
}

###############################################################################
# FUNCTION: summary_report
# Description: Print completion summary for run_all_tasks
###############################################################################
summary_report() {
    log "Summary Report:"
    log "--------------"
    log "Version: $SCRIPT_VERSION"
    log "Profile: $PROFILE"
    log "System Update & Upgrade: Completed"
    log "Sudoers: Updated"
    log "SSH: Configured"
    log "SSH Key: Generated/Verified"
    log ".bashrc & .bash_aliases: Created/Updated"
    log "SNMPD: Installed/Configured"
    log "Docker: Repository Added & Docker CE Installed"
    log "Fastfetch Repo: Cloned/updated with consolidated updater script"
    log "Wake-on-LAN: Not included in Run all tasks"
    log "NAS Backup Script: Not included in Run all tasks"
    log "--------------"
    log "Not included in Run all tasks:"
    log "  - PiVPN installation"
    log "  - Docker removal"
    log "  - DietPi upgrades"
    log "  - Backup restore"
    log "  - Health check / paths display"
    log "  - Profile config display"
    log "  - Wake-on-LAN install"
    log "  - NAS backup script generation"
    log "--------------"
    log "All tasks completed."
}

###############################################################################
# FUNCTION: show_available_backups
# Description: Show latest backup files for important configuration files
###############################################################################
show_available_backups() {
    log "Showing available backups."

    local user_home="/home/$SUDO_USER"

    local files=(
        "/etc/sudoers.d/99-sudo-nopasswd"
        "/etc/ssh/sshd_config"
        "/etc/snmp/snmpd.conf"
        "$user_home/.bashrc"
        "$user_home/.bash_aliases"
    )

    local file latest_backup
    for file in "${files[@]}"; do
        echo
        echo "File: $file"
        latest_backup="$(find_latest_backup "$file" || true)"

        if [ -n "$latest_backup" ]; then
            echo "Latest backup: $latest_backup"
        else
            echo "Latest backup: None found"
        fi
    done
}

###############################################################################
# FUNCTION: restore_from_backup
# Description: Restore the latest backup of a selected file
###############################################################################
restore_from_backup() {
    log "Restore from backup selected."

    local user_home="/home/$SUDO_USER"
    local target_file latest_backup choice response

    echo "Select file to restore:"
    echo "  1) /etc/sudoers.d/99-sudo-nopasswd"
    echo "  2) /etc/ssh/sshd_config"
    echo "  3) /etc/snmp/snmpd.conf"
    echo "  4) $user_home/.bashrc"
    echo "  5) $user_home/.bash_aliases"
    echo "  6) Cancel"

    read -rp "Enter your choice: " choice

    case "$choice" in
        1) target_file="/etc/sudoers.d/99-sudo-nopasswd" ;;
        2) target_file="/etc/ssh/sshd_config" ;;
        3) target_file="/etc/snmp/snmpd.conf" ;;
        4) target_file="$user_home/.bashrc" ;;
        5) target_file="$user_home/.bash_aliases" ;;
        6)
            log "Restore cancelled."
            return 0
            ;;
        *)
            log "Invalid restore choice." "ERROR"
            return 1
            ;;
    esac

    latest_backup="$(find_latest_backup "$target_file" || true)"

    if [ -z "$latest_backup" ]; then
        log "No backup found for $target_file" "ERROR"
        return 1
    fi

    echo "Latest backup found:"
    echo "  $latest_backup"
    read -rp "Restore this backup? [y/N]: " response

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Restore aborted."
        return 0
    fi

    if [[ "$target_file" == /etc/* ]]; then
        sudo cp "$latest_backup" "$target_file"
    else
        sudo -u "$SUDO_USER" cp "$latest_backup" "$target_file"
    fi

    case "$target_file" in
        "/etc/ssh/sshd_config")
            if sudo sshd -t -f /etc/ssh/sshd_config; then
                restart_ssh_service
                log "SSH service restarted after restore."
            else
                log "Restored sshd_config failed validation. Review it before restarting SSH." "ERROR"
                return 1
            fi
            ;;
        "/etc/snmp/snmpd.conf")
            if sudo systemctl is-active --quiet snmpd; then
                sudo systemctl restart snmpd
                log "snmpd restarted after restore."
            else
                log "snmpd not active; restart manually if needed." "WARN"
            fi
            ;;
    esac

    log "Restore completed for $target_file"
}

###############################################################################
# FUNCTION: run_health_check
# Description: Verify status of important setup components
###############################################################################
run_health_check() {
    log "Running health check."

    local user_home="/home/$SUDO_USER"
    local ssh_key="$user_home/.ssh/id_ed25519"
    local ssh_pub="$user_home/.ssh/id_ed25519.pub"

    echo "Health check results:"
    echo "---------------------"

    if grep -q '^%sudo ALL=(ALL) NOPASSWD: ALL$' /etc/sudoers.d/99-sudo-nopasswd 2>/dev/null; then
        echo "[OK]    sudoers configured for passwordless sudo"
    else
        echo "[ERROR] sudoers entry missing or incorrect"
    fi

    if grep -Eq '^[#[:space:]]*PermitRootLogin[[:space:]]+no$' /etc/ssh/sshd_config 2>/dev/null; then
        echo "[OK]    SSH root login disabled"
    else
        echo "[ERROR] SSH root login not configured as expected"
    fi

    if grep -Eq '^[#[:space:]]*AllowUsers[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null; then
        echo "[OK]    AllowUsers configured"
    else
        echo "[WARN]  AllowUsers entry missing"
    fi

    local ssh_service
    ssh_service="$(ssh_service_name)"
    if sudo systemctl is-active --quiet "$ssh_service"; then
        echo "[OK]    ${ssh_service} service is active"
    else
        echo "[WARN]  ${ssh_service} service is not active"
    fi

    if [ -f "$ssh_key" ] && [ -f "$ssh_pub" ]; then
        echo "[OK]    SSH keypair exists"
    else
        echo "[WARN]  SSH keypair missing"
    fi

    if [ -f "$user_home/.bashrc" ]; then
        echo "[OK]    .bashrc exists"
    else
        echo "[WARN]  .bashrc missing"
    fi

    if [ -f "$user_home/.bash_aliases" ]; then
        echo "[OK]    .bash_aliases exists"
    else
        echo "[WARN]  .bash_aliases missing"
    fi

    if dpkg -l | grep -q "^ii.*snmpd"; then
        echo "[OK]    snmpd package installed"
    else
        echo "[WARN]  snmpd package not installed"
    fi

    if sudo systemctl is-active --quiet snmpd; then
        echo "[OK]    snmpd service is active"
    else
        echo "[WARN]  snmpd service is not active"
    fi

    if [ -f /etc/apt/sources.list.d/docker.list ]; then
        echo "[OK]    Docker repository configured"
    else
        echo "[WARN]  Docker repository not configured"
    fi

    if command -v docker >/dev/null 2>&1; then
        echo "[OK]    Docker command available"
    else
        echo "[WARN]  Docker not installed"
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "[OK]    Docker Compose plugin available"
    else
        echo "[WARN]  Docker Compose plugin unavailable"
    fi

    if id -nG "$SUDO_USER" | grep -qw docker; then
        echo "[OK]    User $SUDO_USER is in docker group"
    else
        echo "[WARN]  User $SUDO_USER is not in docker group"
    fi

    if command -v pivpn >/dev/null 2>&1; then
        echo "[OK]    PiVPN installed"
    else
        echo "[WARN]  PiVPN not installed"
    fi

    if [ -d "$user_home/update-fastfetch" ]; then
        echo "[OK]    update-fastfetch repository exists"
    else
        echo "[WARN]  update-fastfetch repository missing"
    fi

    if command -v wakeonlan >/dev/null 2>&1; then
        echo "[OK]    wakeonlan command available"
    else
        echo "[WARN]  wakeonlan command not available"
    fi

    if [ -f "$user_home/nas-backup.sh" ]; then
        echo "[OK]    NAS backup script exists"
    else
        echo "[WARN]  NAS backup script missing"
    fi

    if [ -f /root/.nas-credentials ]; then
        echo "[OK]    NAS credentials file exists"
    else
        echo "[WARN]  NAS credentials file missing"
    fi
}

###############################################################################
# FUNCTION: show_important_paths
# Description: Show important file paths, directories, and expected locations
###############################################################################
show_important_paths() {
    log "Showing important paths."

    local user_home="/home/$SUDO_USER"
    local short_host
    short_host="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"

    echo "Important paths:"
    echo "----------------"
    echo
    echo "User home:"
    echo "  $user_home"
    echo
    echo "Log file:"
    echo "  $LOG_FILE"
    echo
    echo "Shell:"
    echo "  $user_home/.bashrc"
    echo "  $user_home/.bash_aliases"
    echo
    echo "SSH:"
    echo "  $user_home/.ssh/"
    echo "  $user_home/.ssh/id_ed25519"
    echo "  $user_home/.ssh/id_ed25519.pub"
    echo
    echo "SNMP:"
    echo "  /etc/snmp/snmpd.conf"
    echo
    echo "Docker:"
    echo "  /etc/apt/sources.list.d/docker.list"
    echo "  /etc/apt/keyrings/docker.asc"
    echo "  /var/lib/docker"
    echo "  /var/lib/containerd"
    echo
    echo "PiVPN:"
    echo "  pivpn command: $(command -v pivpn 2>/dev/null || echo 'not installed')"
    echo "  Expected client names:"
    echo "    ${short_host}-tb7"
    echo "    ${short_host}-mbp"
    echo "    ${short_host}-iph"
    echo "    ${short_host}-len"
    echo "  Common config location:"
    echo "    $user_home/configs"
    echo
    echo "Fastfetch:"
    echo "  $user_home/update-fastfetch"
    echo
    echo "Wake-on-LAN:"
    echo "  $(command -v wakeonlan 2>/dev/null || echo 'not installed')"
    echo
    echo "NAS backup:"
    echo "  Script: $user_home/nas-backup.sh"
    echo "  Credentials: /root/.nas-credentials"
    echo "  Mount point: /mnt/nas_backup"
    echo "  NAS layout:"
    echo "    //10.0.0.100/backup/dietpibackup/${short_host}/"
    echo
    echo "Latest backups:"
    local files=(
        "/etc/sudoers.d/99-sudo-nopasswd"
        "/etc/ssh/sshd_config"
        "/etc/snmp/snmpd.conf"
        "$user_home/.bashrc"
        "$user_home/.bash_aliases"
    )
    local file latest_backup
    for file in "${files[@]}"; do
        latest_backup="$(find_latest_backup "$file" || true)"
        echo "  $file"
        echo "    ${latest_backup:-No backup found}"
    done
}

###############################################################################
# FUNCTION: show_current_profile_config
# Description: Show currently active profile-related configuration
###############################################################################
show_current_profile_config() {
    log "Showing current profile configuration."

    local short_host
    short_host="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"

    echo "Current profile configuration:"
    echo "------------------------------"
    echo "Version: $SCRIPT_VERSION"
    echo "Profile: $PROFILE"
    echo "Short hostname: $short_host"
    echo "SNMP community: $SNMP_ROCOMMUNITY"
    echo
    echo "Expected PiVPN client names:"
    echo "  ${short_host}-tb7"
    echo "  ${short_host}-mbp"
    echo "  ${short_host}-iph"
    echo "  ${short_host}-len"
    echo
    echo "SNMP hardware mode:"
    case "$PROFILE" in
        x64|x64-brk)
            echo "  x64 / DMI-based hardware info"
            ;;
        pi|pi-brk)
            echo "  Raspberry Pi / device-tree-based hardware info"
            ;;
        *)
            echo "  Unknown"
            ;;
    esac
}

###############################################################################
# FUNCTION: run_all_tasks
# Description: Run standard setup tasks only (excludes DietPi upgrades,
#              Docker removal, PiVPN, restore, and verification helpers)
###############################################################################
run_all_tasks() {
    system_update_upgrade
    update_sudoers
    configure_ssh
    generate_ssh_key
    create_bashrc
    create_bash_aliases
    install_configure_snmpd
    install_docker_repository
    install_docker_ce
    clone_fastfetch_repository
    summary_report
}

###############################################################################
# FUNCTION: menu
# Description: Original interactive menu layout
###############################################################################
menu() {
    while true; do
        clear
        echo "#####################################"
        echo "#   Automated System Configuration  #"
        echo "#####################################"
        echo "Version: $SCRIPT_VERSION"
        echo "Profile: $PROFILE"
        echo "-------------------------------------"
        echo "Please select an option:"
        echo "  1) System Update and Upgrade"
        echo "  2) DietPi: Bullseye -> Bookworm"
        echo "  3) DietPi: Bookworm -> Trixie"
        echo "  4) Update sudoers"
        echo "  5) Configure SSH"
        echo "  6) Generate SSH Key"
        echo "  7) Create/Update .bashrc"
        echo "  8) Create/Update .bash_aliases"
        echo "  9) Install and Configure SNMPD"
        echo "  10) Install Docker official repo"
        echo "  11) Install PiVPN"
        echo "  12) Install Docker and relevant tools"
        echo "  13) Remove Docker and relevant tools"
        echo "  14) Clone/update the update-fastfetch repo"
        echo "  15) Run all tasks"
        echo "  16) Show available backups"
        echo "  17) Restore from backup"
        echo "  18) Run health check"
        echo "  19) Show important paths"
        echo "  20) Show current profile config"
        echo "  21) Install Wake-on-LAN tools"
        echo "  22) Create NAS backup script"
        echo "  23) Exit"

        read -rp "Enter your choice: " choice

        case "$choice" in
            1) system_update_upgrade ;;
            2) dietpi_bullseye_to_bookworm ;;
            3) dietpi_bookworm_to_trixie ;;
            4) update_sudoers ;;
            5) configure_ssh ;;
            6) generate_ssh_key ;;
            7) create_bashrc ;;
            8) create_bash_aliases ;;
            9) install_configure_snmpd ;;
            10) install_docker_repository ;;
            11) install_pivpn ;;
            12) install_docker_ce ;;
            13) remove_docker_and_tools ;;
            14) clone_fastfetch_repository ;;
            15) run_all_tasks ;;
            16) show_available_backups ;;
            17) restore_from_backup ;;
            18) run_health_check ;;
            19) show_important_paths ;;
            20) show_current_profile_config ;;
            21) install_wakeonlan ;;
            22) create_nas_backup_script ;;
            23)
                log "Script execution completed."
                log "Please apply the following command manually to source both .bashrc and .bash_aliases files:"
                echo ". /home/$SUDO_USER/.bashrc && . /home/$SUDO_USER/.bash_aliases"
                echo "Alternatively, log out and log back in to start a new shell session."
                echo "Log file: $LOG_FILE"
                exit 0
                ;;
            *)
                echo "Invalid choice. Please select a valid option."
                ;;
        esac

        read -rp "Press Enter to continue..."
    done
}

###############################################################################
# START
###############################################################################
log "Script execution started. Version: $SCRIPT_VERSION"
select_profile
apply_profile_config
install_missing_packages
menu

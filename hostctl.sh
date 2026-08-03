#!/bin/bash
###############################################################################
# Author: mews_se
# Script: hostctl.sh
# Description:
#   Unified system bootstrap and maintenance tool for Debian/DietPi hosts.
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
#     - APT lock detection/wait
#     - SSH hardening with automatic rollback
#     - Passwordless sudo
#     - SSH key generation
#     - SSH key distribution (ssh-copy-id)
#     - .bashrc recreation
#     - Interactive .bash_aliases merge/update
#     - SNMPD install (profile-aware) & removal
#     - Docker install & removal
#     - Docker maintenance (prune / Compose stack updates)
#     - PiVPN install + client configs + QR codes & removal
#     - DietPi upgrade helpers
#     - Fastfetch repo clone/update
#     - geodebtest repo clone/update (Debian mirror benchmark + APT mirror apply)
#     - Backup & restore helpers
#     - Health check
#     - Important paths display
#     - Profile configuration display
#     - Wake-on-LAN tools
#     - Optional UFW configuration (SSH + PiVPN/SNMP ports allowed)
#     - WiFi power save disable (persistent via systemd)
#     - Reboot-required detection
#     - Self-update from GitHub
#     - Logging to ~/hostctl.log (with rotation)
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
if [ "${EUID}" -ne 0 ]; then
    echo "Error: This script must be run as root. Please use sudo." >&2
    exit 1
fi

if [ -z "${SUDO_USER:-}" ]; then
    echo "Error: SUDO_USER is not set. Please run this script with sudo." >&2
    exit 1
fi

if ! id "$SUDO_USER" >/dev/null 2>&1; then
    echo "Error: SUDO_USER does not identify a local account: $SUDO_USER" >&2
    exit 1
fi

USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    echo "Error: Could not resolve a valid home directory for $SUDO_USER." >&2
    exit 1
fi

###############################################################################
# Script metadata
###############################################################################
SCRIPT_VERSION="v2026.08.03"
LOG_FILE="$USER_HOME/hostctl.log"

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

    # The log belongs in the invoking user's home and is always created and
    # appended as that user. This prevents a user-controlled path from
    # redirecting privileged root writes through a symbolic link.
    if [ -L "$LOG_FILE" ] || { [ -e "$LOG_FILE" ] && [ ! -f "$LOG_FILE" ]; }; then
        echo "Refusing to write hostctl log through a symbolic link: $LOG_FILE" >&2
        return 0
    fi

    if [ ! -e "$LOG_FILE" ]; then
        sudo -u "$SUDO_USER" install -m 0644 /dev/null "$LOG_FILE" 2>/dev/null || return 0
    fi
    printf '%s\n' "$line" | sudo -u "$SUDO_USER" tee -a "$LOG_FILE" >/dev/null 2>&1 || true
}

###############################################################################
# FUNCTION: rotate_log_file
# Description: Keep hostctl.log from growing forever. When it exceeds 1 MB the
#              current log is moved aside to hostctl.log.old (one generation).
###############################################################################
rotate_log_file() {
    local max_size=1048576
    local size

    if [ ! -f "$LOG_FILE" ] || [ -L "$LOG_FILE" ]; then
        return 0
    fi

    size="$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)"
    if [ "$size" -gt "$max_size" ]; then
        sudo -u "$SUDO_USER" mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || return 0
    fi
}

###############################################################################
# FUNCTION: run_menu_action
# Description: Run an interactive menu action without letting set -e terminate
#              the whole script on recoverable/action-level failures.
###############################################################################
run_menu_action() {
    local label="$1"
    local rc
    shift

    # A function invoked directly as an `if` condition runs with errexit
    # suppressed throughout its body. Run the action in a subshell instead:
    # errexit remains effective there, while this wrapper can safely capture
    # the action's status and return control to the menu.
    set +e
    (
        set -euo pipefail
        "$@"
    )
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        return 0
    fi

    log "Menu action failed or was cancelled: $label (exit code: $rc). Returning to menu." "ERROR"
    return 0
}

###############################################################################
# FUNCTION: wait_for_apt
# Description: Wait for background apt/dpkg processes to release locks before
#              running apt-get. This avoids failures when apt-daily or another
#              package operation is already active.
###############################################################################
wait_for_apt() {
    # fuser is supplied by psmisc. If it is missing, skip the lock wait rather
    # than failing before bootstrap packages can be installed.
    if ! command -v fuser >/dev/null 2>&1; then
        return 0
    fi

    # Wait on the common apt/dpkg lock files used during update, install,
    # upgrade, and package archive operations. Give up after max_wait seconds
    # rather than looping forever on a stuck lock.
    local waited=0
    local max_wait=300
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [ "$waited" -ge "$max_wait" ]; then
            log "Gave up waiting for apt/dpkg lock after ${max_wait}s. Investigate the stuck process manually." "ERROR"
            return 1
        fi
        log "Waiting for background apt/dpkg process to release lock..." "WARN"
        sleep 5
        waited=$((waited + 5))
    done
}

###############################################################################
# FUNCTION: mark_apt_lists_fresh
# Description: Record a successful apt-get update in the standard Debian stamp
#              file. The list files themselves keep their old mtimes when the
#              mirrors respond 304 Not Modified, so a dedicated stamp is the
#              only reliable freshness signal.
###############################################################################
APT_UPDATE_STAMP="/var/lib/apt/periodic/update-success-stamp"

mark_apt_lists_fresh() {
    sudo mkdir -p "$(dirname "$APT_UPDATE_STAMP")" 2>/dev/null || return 0
    sudo touch "$APT_UPDATE_STAMP" 2>/dev/null || true
}

###############################################################################
# FUNCTION: refresh_apt_package_lists
# Description: Refresh APT package indexes once during startup, before dependency
#              checks/installations. This intentionally does not upgrade packages.
#              The refresh is skipped when the indexes are already fresh, so
#              restarting the script does not rerun apt-get update every time.
###############################################################################
refresh_apt_package_lists() {
    local max_age_minutes=60

    # Fresh means either our own stamp from a recent successful update, or a
    # recently written list file (covers updates done by apt-daily or other
    # tools). If neither can tell, fall through to the update.
    if find "$APT_UPDATE_STAMP" -mmin "-${max_age_minutes}" 2>/dev/null | grep -q . || \
       find /var/lib/apt/lists -maxdepth 1 -type f -mmin "-${max_age_minutes}" 2>/dev/null | grep -q .; then
        log "APT package indexes were refreshed within the last ${max_age_minutes} minutes. Skipping update."
        return 0
    fi

    log "Refreshing APT package indexes."
    wait_for_apt
    if sudo apt-get update; then
        mark_apt_lists_fresh
        log "APT package indexes refreshed successfully."
    else
        log "Failed to refresh APT package indexes. Check network and APT sources." "ERROR"
        exit 1
    fi
}

###############################################################################
# FUNCTION: check_reboot_required
# Description: Report whether Debian/DietPi has flagged the system for reboot.
#              This is informational only; the script never reboots by itself.
###############################################################################
check_reboot_required() {
    # Debian-family systems create this marker after updates that need a reboot.
    if [ -f /var/run/reboot-required ]; then
        log "Reboot required: yes" "WARN"
        if [ -s /var/run/reboot-required.pkgs ]; then
            echo "Packages requesting reboot:"
            sed 's/^/  - /' /var/run/reboot-required.pkgs
        fi
        return 0
    fi

    log "Reboot required: no"
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

    backup_file="${target_file}.bak_$(date +%F_%H-%M-%S)"
    if ! sudo cp --preserve=mode,ownership,timestamps "$target_file" "$backup_file"; then
        return 1
    fi
    prune_old_backups "$target_file"
    printf '%s\n' "$backup_file"
}

###############################################################################
# FUNCTION: prune_old_backups
# Description: Keep only the newest timestamped backups for a target file so
#              .bak_* copies do not accumulate forever.
###############################################################################
prune_old_backups() {
    local target_file="$1"
    local keep=5
    local old_backup

    find "$(dirname "$target_file")" -maxdepth 1 -type f \
        -name "$(basename "$target_file").bak_*" -printf '%T@ %p\n' 2>/dev/null | \
        sort -nr | tail -n +"$((keep + 1))" | cut -d' ' -f2- | \
        while IFS= read -r old_backup; do
            sudo rm -f -- "$old_backup"
        done
}

###############################################################################
# FUNCTION: find_latest_backup
# Description: Return latest timestamped backup for a target file. Backups are
#              searched next to the file by default; an explicit directory can
#              be given for tools that keep their backups elsewhere (geodebtest
#              stores its APT source backups under ~/geodebtest/backups).
###############################################################################
find_latest_backup() {
    local target_file="$1"
    local search_dir="${2:-$(dirname "$target_file")}"

    find "$search_dir" -maxdepth 1 -type f \
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
        if ! sudo systemctl restart "$service_name"; then
            log "Failed to restart SSH service '$service_name'." "ERROR"
            return 1
        fi
        log "SSH service '$service_name' restarted successfully."
    else
        log "SSH service '$service_name' is not active/enabled. Restart manually if needed." "WARN"
        return 1
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

    read -rp "Enter your choice: " pchoice < /dev/tty
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
    [script]="bsdutils"
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

        wait_for_apt
        if ! sudo apt-get update; then
            log "Error updating package lists. Please check your sources and network." "ERROR"
            exit 1
        fi

        wait_for_apt
        if ! sudo apt-get install -y "${missing_packages[@]}"; then
            log "Bulk installation failed. Retrying packages one by one..." "WARN"
            for pkg in "${missing_packages[@]}"; do
                wait_for_apt
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

    wait_for_apt
    if ! sudo apt-get update; then
        log "System update failed. Check network and APT sources." "ERROR"
        return 1
    fi
    mark_apt_lists_fresh

    wait_for_apt
    if ! sudo apt-get dist-upgrade -y; then
        log "System upgrade failed." "ERROR"
        return 1
    fi

    log "System update and upgrade completed successfully."
    check_reboot_required
}

###############################################################################
# FUNCTION: run_remote_root_script
# Description: Download a remote installer to a temporary file, validate Bash
#              syntax, show its digest, and require confirmation before running.
###############################################################################
run_remote_root_script() {
    local label="$1"
    local url="$2"
    local tmp
    local digest
    local response
    local quoted_tmp

    tmp="$(mktemp)"
    if ! curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$tmp"; then
        rm -f "$tmp"
        log "Failed to download $label." "ERROR"
        return 1
    fi

    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        log "Downloaded $label script failed Bash syntax validation." "ERROR"
        return 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum "$tmp" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        digest="$(shasum -a 256 "$tmp" | awk '{print $1}')"
    else
        rm -f "$tmp"
        log "No SHA-256 utility is available to inspect $label." "ERROR"
        return 1
    fi

    echo
    echo "$label was downloaded from:"
    echo "  $url"
    echo "SHA-256:"
    echo "  $digest"
    read -rp "Run this downloaded script as root? [y/N]: " response < /dev/tty
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        rm -f "$tmp"
        log "$label cancelled before execution."
        return 1
    fi

    printf -v quoted_tmp '%q' "$tmp"
    if ! script -qec "bash $quoted_tmp" /dev/null; then
        rm -f "$tmp"
        log "$label failed or was cancelled." "ERROR"
        return 1
    fi

    rm -f "$tmp"
}

###############################################################################
# FUNCTION: dietpi_bullseye_to_bookworm
# Description: Run DietPi Bullseye -> Bookworm upgrade in a PTY
###############################################################################
dietpi_bullseye_to_bookworm() {
    log "DietPi upgrade: Bullseye -> Bookworm"
    if run_remote_root_script \
        "DietPi Bullseye -> Bookworm upgrade" \
        "https://raw.githubusercontent.com/MichaIng/DietPi/dev/.meta/dietpi-bookworm-upgrade"; then
        log "DietPi upgrade Bullseye -> Bookworm finished."
    else
        log "DietPi upgrade Bullseye -> Bookworm failed or was cancelled." "ERROR"
        return 1
    fi
}

###############################################################################
# FUNCTION: dietpi_bookworm_to_trixie
# Description: Run DietPi Bookworm -> Trixie upgrade in a PTY
###############################################################################
dietpi_bookworm_to_trixie() {
    log "DietPi upgrade: Bookworm -> Trixie"
    if run_remote_root_script \
        "DietPi Bookworm -> Trixie upgrade" \
        "https://raw.githubusercontent.com/MichaIng/DietPi/dev/.meta/dietpi-trixie-upgrade"; then
        log "DietPi upgrade Bookworm -> Trixie finished."
    else
        log "DietPi upgrade Bookworm -> Trixie failed or was cancelled." "ERROR"
        return 1
    fi
}

###############################################################################
# FUNCTION: self_update
# Description: Fetch the latest hostctl.sh from GitHub, validate it, show the
#              version change, and replace this script after confirmation. The
#              replacement is an atomic rename, so the running instance keeps
#              executing from the old inode and is unaffected until restarted.
###############################################################################
self_update() {
    local update_url="https://raw.githubusercontent.com/mews-se/hostctl/main/hostctl.sh"
    local script_path tmp new_version response cache_buster

    script_path="$(readlink -f "${BASH_SOURCE[0]}")"
    if [ ! -f "$script_path" ]; then
        log "Could not resolve the running script path." "ERROR"
        return 1
    fi

    log "Checking for a newer hostctl.sh at GitHub (main branch)."

    # raw.githubusercontent.com is served through a CDN that caches responses
    # for several minutes. A unique query string per request bypasses the
    # cache, so an update run right after a merge still sees the new version.
    cache_buster="$(date +%s)"

    tmp="$(mktemp "$(dirname "$script_path")/.hostctl-update.XXXXXX")"
    if ! curl --proto '=https' --tlsv1.2 -fsSL "${update_url}?${cache_buster}" -o "$tmp"; then
        rm -f "$tmp"
        log "Failed to download the latest hostctl.sh." "ERROR"
        return 1
    fi

    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        log "Downloaded script failed Bash syntax validation." "ERROR"
        return 1
    fi

    new_version="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)"
    if [ -z "$new_version" ]; then
        rm -f "$tmp"
        log "Downloaded file does not look like hostctl.sh (no SCRIPT_VERSION found)." "ERROR"
        return 1
    fi

    if cmp -s "$tmp" "$script_path"; then
        rm -f "$tmp"
        log "hostctl is already up to date ($SCRIPT_VERSION)."
        return 0
    fi

    echo
    echo "Current version: $SCRIPT_VERSION"
    echo "New version:     $new_version"
    echo "Target file:     $script_path"
    read -rp "Replace the script with the downloaded version? [y/N]: " response < /dev/tty
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        rm -f "$tmp"
        log "Self-update cancelled."
        return 0
    fi

    chown --reference="$script_path" "$tmp" 2>/dev/null || true
    chmod --reference="$script_path" "$tmp" 2>/dev/null || chmod 0755 "$tmp"
    if ! mv -f "$tmp" "$script_path"; then
        rm -f "$tmp"
        log "Failed to install the updated script." "ERROR"
        return 1
    fi

    log "hostctl updated to $new_version. Exit and restart the script to use the new version."
}

###############################################################################
# FUNCTION: update_sudoers
# Description: Enable passwordless sudo for the sudo group
###############################################################################
update_sudoers() {
    log "Updating sudoers."

    local sudoers_dropin="/etc/sudoers.d/99-sudo-nopasswd"
    local sudoers_content="%sudo ALL=(ALL) NOPASSWD: ALL"
    local sudoers_tmp
    local backup_path=""

    sudoers_tmp="$(sudo mktemp /etc/sudoers.d/.hostctl-sudoers.XXXXXX)"
    if ! printf '%s\n' "$sudoers_content" | sudo tee "$sudoers_tmp" >/dev/null; then
        sudo rm -f "$sudoers_tmp"
        log "Failed to write temporary sudoers file." "ERROR"
        return 1
    fi
    sudo chmod 0440 "$sudoers_tmp"

    if ! sudo visudo -cf "$sudoers_tmp" >/dev/null 2>&1; then
        sudo rm -f "$sudoers_tmp"
        log "Temporary sudoers file failed validation; existing configuration was not changed." "ERROR"
        return 1
    fi

    if [ -f "$sudoers_dropin" ]; then
        backup_path="$(backup_file "$sudoers_dropin")" || {
            sudo rm -f "$sudoers_tmp"
            log "Could not back up the existing sudoers drop-in." "ERROR"
            return 1
        }
    fi

    if ! sudo install -o root -g root -m 0440 "$sudoers_tmp" "$sudoers_dropin"; then
        sudo rm -f "$sudoers_tmp"
        log "Failed to install sudoers drop-in." "ERROR"
        return 1
    fi
    sudo rm -f "$sudoers_tmp"

    if ! sudo visudo -cf /etc/sudoers >/dev/null 2>&1; then
        if [ -n "$backup_path" ] && [ -f "$backup_path" ]; then
            sudo cp --preserve=mode,ownership,timestamps "$backup_path" "$sudoers_dropin"
        else
            sudo rm -f "$sudoers_dropin"
        fi
        log "Full sudoers validation failed; the previous state was restored." "ERROR"
        return 1
    fi

    log "sudoers drop-in updated successfully at $sudoers_dropin."
}

###############################################################################
# FUNCTION: configure_ssh
# Description: Disable root SSH login and restrict allowed users. The original
#              sshd_config is backed up first; failed validation or restart
#              triggers an automatic rollback.
###############################################################################
configure_ssh() {
    preflight_ssh || return 1

    log "Configuring SSH."
    local sshd_config="/etc/ssh/sshd_config"
    local sshd_tmp
    local allow_users
    local backup_path=""
    local effective_ssh_config
    local effective_allow_users
    local expected_user
    allow_users="$(get_allowed_ssh_users)"

    sshd_tmp="$(sudo mktemp /etc/ssh/.hostctl-sshd_config.XXXXXX)"
    if ! sudo awk -v allow_users="$allow_users" '
        function emit_hostctl_settings() {
            print "PermitRootLogin no"
            if (allow_users != "") {
                print "AllowUsers " allow_users
            }
            print ""
            inserted = 1
        }

        BEGIN {
            inserted = 0
            in_match = 0
        }

        # Insert before the first active directive. On Debian this places the
        # hostctl policy before Include, so an included drop-in cannot win by
        # supplying an earlier value for PermitRootLogin or AllowUsers.
        !inserted && $0 !~ /^[[:space:]]*(#|$)/ {
            emit_hostctl_settings()
        }

        /^[[:space:]]*Match([[:space:]]|$)/ {
            in_match = 1
        }

        # Remove old global settings from the main file, but preserve values
        # inside Match blocks where they may intentionally be connection-specific.
        !in_match && /^[#[:space:]]*(PermitRootLogin|AllowUsers)[[:space:]]+/ {
            next
        }

        { print }

        END {
            if (!inserted) {
                emit_hostctl_settings()
            }
        }
    ' "$sshd_config" | sudo tee "$sshd_tmp" >/dev/null; then
        sudo rm -f "$sshd_tmp"
        log "Failed to create temporary SSH configuration." "ERROR"
        return 1
    fi

    rollback_ssh_config() {
        if [ -n "$backup_path" ] && [ -f "$backup_path" ]; then
            sudo cp --preserve=mode,ownership,timestamps "$backup_path" "$sshd_config"
            log "Rolled back SSH config from: $backup_path" "WARN"
        else
            log "No SSH backup available for rollback." "ERROR"
        fi
    }

    # Validate the candidate before replacing the live file.
    if ! sudo sshd -t -f "$sshd_tmp"; then
        sudo rm -f "$sshd_tmp"
        log "Candidate sshd_config failed validation; existing configuration was not changed." "ERROR"
        return 1
    fi

    # Syntax validation alone cannot detect an earlier value from an Include.
    # Confirm that the effective configuration contains the intended settings.
    effective_ssh_config="$(sudo sshd -T -f "$sshd_tmp")"
    if ! grep -q '^permitrootlogin no$' <<< "$effective_ssh_config"; then
        sudo rm -f "$sshd_tmp"
        log "Candidate SSH configuration does not effectively disable root login." "ERROR"
        return 1
    fi
    effective_allow_users="$(
        awk '$1 == "allowusers" {
            for (field = 2; field <= NF; field++) {
                print $field
            }
        }' <<< "$effective_ssh_config"
    )"
    for expected_user in $allow_users; do
        if ! grep -Fqx -- "$expected_user" <<< "$effective_allow_users"; then
            sudo rm -f "$sshd_tmp"
            log "Candidate SSH configuration is missing expected AllowUsers account: $expected_user" "ERROR"
            return 1
        fi
    done

    backup_path="$(backup_file "$sshd_config")" || {
        sudo rm -f "$sshd_tmp"
        log "Failed to back up the existing SSH configuration." "ERROR"
        return 1
    }
    log "SSH config backup created: $backup_path"

    if ! sudo install -o root -g root -m 0644 "$sshd_tmp" "$sshd_config"; then
        sudo rm -f "$sshd_tmp"
        log "Failed to install validated SSH configuration." "ERROR"
        return 1
    fi
    sudo rm -f "$sshd_tmp"

    # If restart fails despite a valid config, restore the previous known-good
    # file and try to bring SSH back with that version.
    if ! restart_ssh_service; then
        log "SSH restart failed. Rolling back." "ERROR"
        rollback_ssh_config
        restart_ssh_service || log "SSH restart failed after rollback. Manual intervention required." "ERROR"
        return 1
    fi

    log "SSH configuration updated successfully."
}
###############################################################################
# FUNCTION: generate_ssh_key
# Description: Generate ed25519 SSH key for invoking sudo user
###############################################################################
generate_ssh_key() {
    log "Generating SSH key."

    local SSH_DIR="$USER_HOME/.ssh"
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
# FUNCTION: distribute_ssh_key
# Description: Copy the invoking user's public key to one or more remote hosts
#              with ssh-copy-id. Targets can be picked from the ssh aliases in
#              ~/.bash_aliases (including any -p port) or entered manually as
#              user@host. Each transfer may prompt for the remote password.
###############################################################################
distribute_ssh_key() {
    log "Distributing SSH public key."

    local pub_key="$USER_HOME/.ssh/id_ed25519.pub"
    local aliases_file="$USER_HOME/.bash_aliases"
    local targets target response

    if [ ! -f "$pub_key" ]; then
        log "No public key found at $pub_key." "WARN"
        read -rp "Generate one now? [Y/n]: " response < /dev/tty
        if [[ -z "$response" || "$response" =~ ^[Yy]$ ]]; then
            generate_ssh_key
        else
            log "SSH key distribution cancelled."
            return 0
        fi
    fi

    if ! command -v ssh-copy-id >/dev/null 2>&1; then
        log "ssh-copy-id is not available (openssh-client)." "ERROR"
        return 1
    fi

    # Collect ssh targets from .bash_aliases. Only aliases whose command is
    # ssh are considered; a -p port is picked up when present.
    local -a alias_names=() alias_targets=() alias_ports=()
    local alias_re="^[[:space:]]*alias[[:space:]]+([^=]+)=[\"']ssh[[:space:]]+([^\"']+)[\"']"
    local line word
    if [ -f "$aliases_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ $alias_re ]]; then
                local a_name="${BASH_REMATCH[1]}"
                local a_cmd="${BASH_REMATCH[2]}"
                local a_target="" a_port="" expect_port=0
                for word in $a_cmd; do
                    if [ "$expect_port" -eq 1 ]; then
                        a_port="$word"
                        expect_port=0
                    elif [ "$word" = "-p" ]; then
                        expect_port=1
                    elif [[ "$word" == *@* ]]; then
                        a_target="$word"
                    fi
                done
                if [ -n "$a_target" ]; then
                    alias_names+=("$a_name")
                    alias_targets+=("$a_target")
                    alias_ports+=("$a_port")
                fi
            fi
        done < "$aliases_file"
    fi

    local -a chosen_targets=() chosen_ports=()
    local selection sel i

    if [ "${#alias_names[@]}" -gt 0 ]; then
        echo
        echo "SSH targets found in .bash_aliases:"
        for i in "${!alias_names[@]}"; do
            if [ -n "${alias_ports[$i]}" ]; then
                printf '  %2d) %-12s %s (port %s)\n' "$((i + 1))" "${alias_names[$i]}" "${alias_targets[$i]}" "${alias_ports[$i]}"
            else
                printf '  %2d) %-12s %s\n' "$((i + 1))" "${alias_names[$i]}" "${alias_targets[$i]}"
            fi
        done
        echo
        echo "Enter numbers separated by spaces, 'a' for all, or 'm' for manual entry."
        read -rp "Selection: " selection < /dev/tty
    else
        log "No ssh aliases found in $aliases_file. Falling back to manual entry."
        selection="m"
    fi

    case "$selection" in
        "")
            log "Nothing selected. SSH key distribution cancelled."
            return 0
            ;;
        [Aa])
            for i in "${!alias_targets[@]}"; do
                chosen_targets+=("${alias_targets[$i]}")
                chosen_ports+=("${alias_ports[$i]}")
            done
            ;;
        [Mm])
            echo
            echo "Enter one or more targets (user@host), separated by spaces."
            echo "Example: dietpi@10.0.0.8 martin@10.0.0.11"
            read -rp "Targets: " targets < /dev/tty
            if [ -z "$targets" ]; then
                log "No targets given. Nothing to do."
                return 0
            fi
            for target in $targets; do
                chosen_targets+=("$target")
                chosen_ports+=("")
            done
            ;;
        *)
            for sel in $selection; do
                if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#alias_targets[@]}" ]; then
                    chosen_targets+=("${alias_targets[$((sel - 1))]}")
                    chosen_ports+=("${alias_ports[$((sel - 1))]}")
                else
                    log "Ignoring invalid selection: $sel" "WARN"
                fi
            done
            ;;
    esac

    if [ "${#chosen_targets[@]}" -eq 0 ]; then
        log "No valid targets selected. Nothing to do."
        return 0
    fi

    local failed=()
    local port
    for i in "${!chosen_targets[@]}"; do
        target="${chosen_targets[$i]}"
        port="${chosen_ports[$i]}"
        log "Copying public key to $target${port:+ (port $port)}"
        if sudo -u "$SUDO_USER" ssh-copy-id -i "$pub_key" ${port:+-p "$port"} "$target" < /dev/tty; then
            log "Key installed on $target"
        else
            failed+=("$target")
            log "Failed to install key on $target" "WARN"
        fi
    done

    if [ "${#failed[@]}" -gt 0 ]; then
        log "Key distribution failed for: ${failed[*]}" "ERROR"
        return 1
    fi

    log "SSH key distribution completed."
}

###############################################################################
# FUNCTION: create_bashrc
# Description: Replace ~/.bashrc with curated default
###############################################################################
create_bashrc() {
    log "Creating/updating .bashrc file."

    local BASHRC_FILE="$USER_HOME/.bashrc"
    local BASHRC_TEMP

    sudo -u "$SUDO_USER" mkdir -p "$(dirname "$BASHRC_FILE")"
    BASHRC_TEMP="$(sudo -u "$SUDO_USER" mktemp "$USER_HOME/.bashrc.tmp.XXXXXX")"

    if [ -f "$BASHRC_FILE" ]; then
        if ! backup_file "$BASHRC_FILE" >/dev/null; then
            sudo rm -f "$BASHRC_TEMP"
            log "Failed to back up the existing .bashrc." "ERROR"
            return 1
        fi
        log "Existing .bashrc backup created."
    fi

    if ! cat <<'EOL' | sudo -u "$SUDO_USER" tee "$BASHRC_TEMP" > /dev/null
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
    then
        sudo rm -f "$BASHRC_TEMP"
        log "Failed to write the new .bashrc." "ERROR"
        return 1
    fi

    if ! sudo -u "$SUDO_USER" mv "$BASHRC_TEMP" "$BASHRC_FILE"; then
        sudo rm -f "$BASHRC_TEMP"
        log "Failed to install the new .bashrc." "ERROR"
        return 1
    fi

    log ".bashrc file created/updated successfully for user: $SUDO_USER."
}

###############################################################################
# FUNCTION: create_bash_aliases
# Description: Merge curated aliases with optional retention of custom aliases
###############################################################################
create_bash_aliases() {
    log "Creating/updating .bash_aliases file with interactive review."

    local ALIASES_FILE="$USER_HOME/.bash_aliases"
    local BACKUP_FILE
    local TEMP_FILE

    BACKUP_FILE="$ALIASES_FILE.bak_$(date +%F_%H-%M-%S)"
    TEMP_FILE="$(sudo -u "$SUDO_USER" mktemp "$USER_HOME/.bash_aliases.tmp.XXXXXX")"

    local RED GREEN YELLOW CYAN NC
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'

    if [ -f "$ALIASES_FILE" ]; then
        sudo -u "$SUDO_USER" cp "$ALIASES_FILE" "$BACKUP_FILE"
        prune_old_backups "$ALIASES_FILE"
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
alias hostctl="rm -rf ~/hostctl ~/startchanges && git clone https://github.com/mews-se/hostctl.git ~/hostctl"
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

    if ! dpkg-query -W -f='${db:Status-Abbrev}' lm-sensors 2>/dev/null | grep -q '^i'; then
        wait_for_apt
        if sudo apt-get install -y lm-sensors; then
            log "lm-sensors package installed successfully."
        else
            log "Failed to install lm-sensors." "ERROR"
            return 1
        fi
    else
        log "lm-sensors package is already installed. No changes needed."
    fi

    if ! dpkg-query -W -f='${db:Status-Abbrev}' snmpd 2>/dev/null | grep -q '^i'; then
        wait_for_apt
        if sudo apt-get install -y snmpd; then
            log "snmpd package installed successfully."
        else
            log "Failed to install snmpd." "ERROR"
            return 1
        fi
    else
        log "snmpd package is already installed. No changes needed."
    fi

    local SNMPD_CONF_FILE="/etc/snmp/snmpd.conf"
    local SNMPD_CONF_TMP
    local SNMPD_BACKUP=""
    SNMPD_CONF_TMP="$(sudo mktemp /etc/snmp/.hostctl-snmpd.XXXXXX)"

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

    if ! printf '%s\n' "$SNMPD_CONF_CONTENT" | sudo tee "$SNMPD_CONF_TMP" >/dev/null; then
        sudo rm -f "$SNMPD_CONF_TMP"
        log "Failed to write temporary SNMPD configuration." "ERROR"
        return 1
    fi
    sudo chown root:root "$SNMPD_CONF_TMP"
    sudo chmod 0600 "$SNMPD_CONF_TMP"

    if [ -f "$SNMPD_CONF_FILE" ]; then
        SNMPD_BACKUP="$(backup_file "$SNMPD_CONF_FILE")" || {
            sudo rm -f "$SNMPD_CONF_TMP"
            log "Failed to back up existing snmpd.conf." "ERROR"
            return 1
        }
        log "Existing snmpd.conf backed up to $SNMPD_BACKUP."
    fi

    if ! sudo install -o root -g root -m 0600 "$SNMPD_CONF_TMP" "$SNMPD_CONF_FILE"; then
        sudo rm -f "$SNMPD_CONF_TMP"
        log "Failed to install SNMPD configuration." "ERROR"
        return 1
    fi
    sudo rm -f "$SNMPD_CONF_TMP"
    log "snmpd.conf file created/overwritten successfully at $SNMPD_CONF_FILE."

    if sudo systemctl is-active --quiet snmpd; then
        if ! sudo systemctl reload snmpd; then
            if [ -n "$SNMPD_BACKUP" ] && [ -f "$SNMPD_BACKUP" ]; then
                sudo cp --preserve=mode,ownership,timestamps "$SNMPD_BACKUP" "$SNMPD_CONF_FILE"
                sudo systemctl restart snmpd || true
            fi
            log "SNMPD reload failed; previous configuration restored." "ERROR"
            return 1
        fi
        log "SNMPD service reloaded successfully."
    else
        log "SNMPD service is not active; start/restart manually if needed." "WARN"
    fi
}

###############################################################################
# FUNCTION: remove_snmpd
# Description: Stop, disable, and purge SNMPD. Configuration is removed by the
#              purge, but timestamped .bak_* backups of snmpd.conf are kept so
#              a reinstall can be restored. lm-sensors is left installed.
###############################################################################
remove_snmpd() {
    log "Removing SNMPD."

    if ! dpkg-query -W -f='${db:Status-Abbrev}' snmpd 2>/dev/null | grep -q '^i'; then
        log "snmpd is not installed. Nothing to remove."
        return 0
    fi

    local confirmation
    echo
    echo "WARNING: This removes the snmpd package and purges its configuration"
    echo "         (/etc/snmp/snmpd.conf). Timestamped .bak_* backups are kept."
    echo "         lm-sensors is left installed."
    read -rp "Remove SNMPD? [y/N]: " confirmation < /dev/tty
    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        log "SNMPD removal cancelled."
        return 0
    fi

    if sudo systemctl is-active --quiet snmpd; then
        sudo systemctl stop snmpd || log "Could not stop snmpd before removal." "WARN"
    fi
    sudo systemctl disable snmpd >/dev/null 2>&1 || true

    wait_for_apt
    if ! sudo apt-get purge -y snmpd; then
        log "Failed to purge snmpd." "ERROR"
        return 1
    fi

    wait_for_apt
    if ! sudo apt-get autoremove -y; then
        log "apt-get autoremove failed during SNMPD cleanup." "WARN"
    fi

    log "SNMPD removed successfully."
}

###############################################################################
# FUNCTION: install_docker_repository
# Description: Add Docker official repository
###############################################################################
install_docker_repository() {
    preflight_docker || return 1

    log "Installing Docker repository."

    wait_for_apt
    if ! sudo apt-get update; then
        log "Failed to update package lists before Docker repository setup." "ERROR"
        return 1
    fi

    wait_for_apt
    if ! sudo apt-get install -y ca-certificates curl; then
        log "Failed to install Docker repository prerequisites." "ERROR"
        return 1
    fi

    if ! sudo install -m 0755 -d /etc/apt/keyrings; then
        log "Failed to create /etc/apt/keyrings." "ERROR"
        return 1
    fi

    if ! sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; then
        log "Failed to download Docker GPG key." "ERROR"
        return 1
    fi

    if ! sudo chmod a+r /etc/apt/keyrings/docker.asc; then
        log "Failed to set permissions on Docker GPG key." "ERROR"
        return 1
    fi

    local distro_codename
    distro_codename="$(get_os_codename)"

    if ! echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      ${distro_codename} stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null; then
        log "Failed to write Docker APT source list." "ERROR"
        return 1
    fi

    wait_for_apt
    if ! sudo apt-get update; then
        log "Docker repository was written, but apt-get update failed." "ERROR"
        return 1
    fi

    log "Docker repository installed successfully."
}

###############################################################################
# FUNCTION: install_pivpn
# Description: Install PiVPN via PTY and optionally create default clients
###############################################################################
install_pivpn() {
    preflight_pivpn || return 1

    log "Installing PiVPN."

    if ! run_remote_root_script "PiVPN installer" "https://install.pivpn.io"; then
        log "PiVPN installation failed or was cancelled." "ERROR"
        return 1
    fi

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
        # Match the client name as a whole field. grep -w is not enough here:
        # hyphens count as word boundaries, so "host-iph" would still match
        # an existing "host-iph-old" client.
        if pivpn list | grep -Eq "(^|[[:space:]])${client}([[:space:]]|$)"; then
            log "Exists: $client"
        else
            log "Creating client: $client"
            if ! pivpn add -n "$client" -ip auto; then
                log "Failed to create PiVPN client: $client" "WARN"
            fi
        fi
    done

    echo
    read -rp "Show QR for ${HOST}-iph? [Y/n]: " qr < /dev/tty
    if [[ -z "$qr" || "$qr" =~ ^[Yy]$ ]]; then
        pivpn -qr "${HOST}-iph" < /dev/tty > /dev/tty 2>/dev/tty || \
            log "Failed to display PiVPN QR code for ${HOST}-iph." "WARN"
    fi
}

###############################################################################
# FUNCTION: remove_pivpn
# Description: Run PiVPN's own uninstaller (pivpn -u) in a PTY. The uninstaller
#              is interactive, like the installer: it asks which dependencies
#              to remove and deletes the VPN server configuration.
###############################################################################
remove_pivpn() {
    log "Removing PiVPN."

    if ! command -v pivpn >/dev/null 2>&1; then
        log "PiVPN is not installed. Nothing to remove."
        return 0
    fi

    if ! command -v script >/dev/null 2>&1; then
        log "'script' command is required for PiVPN uninstaller PTY handling." "ERROR"
        return 1
    fi

    echo
    echo "This runs PiVPN's own uninstaller (pivpn -u)."
    echo "It will ask which dependencies to remove and deletes the VPN server"
    echo "configuration. Client configs may also be removed."
    read -rp "Run the PiVPN uninstaller? [y/N]: " response < /dev/tty
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "PiVPN removal cancelled."
        return 0
    fi

    # The uninstaller draws whiptail dialogs and prompts per dependency, so it
    # gets the same PTY treatment as the installer.
    if ! script -qec "pivpn -u" /dev/null; then
        log "PiVPN uninstaller failed or was cancelled." "ERROR"
        return 1
    fi

    if command -v pivpn >/dev/null 2>&1; then
        log "pivpn command is still present after the uninstaller ran; check manually." "WARN"
        return 1
    fi

    log "PiVPN removed successfully."
}

###############################################################################
# FUNCTION: install_docker_ce
# Description: Install Docker Engine and related tools
###############################################################################
install_docker_ce() {
    log "Installing Docker CE and related tools."

    local docker_packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
        docker-ce-rootless-extras
    )

    # Ensure package indexes are current and check whether Docker packages are
    # actually available before running apt-get install. This avoids a hard menu
    # exit when the Docker repository has not been added yet or apt sources are
    # out of date.
    wait_for_apt
    if ! sudo apt-get update; then
        log "Failed to update package lists before Docker installation." "ERROR"
        return 1
    fi

    # A package that is completely unknown to apt produces no "Candidate:" line
    # at all, so an empty result must be treated the same as "(none)".
    local missing_candidates=()
    local package candidate
    for package in "${docker_packages[@]}"; do
        candidate="$(apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2}')"
        if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
            missing_candidates+=("$package")
        fi
    done

    if [ "${#missing_candidates[@]}" -gt 0 ]; then
        log "Docker packages are not available from current APT sources: ${missing_candidates[*]}" "WARN"
        log "Attempting to install/refresh the official Docker repository first."
        if ! install_docker_repository; then
            log "Docker repository setup failed. Docker CE installation skipped." "ERROR"
            return 1
        fi

        missing_candidates=()
        for package in "${docker_packages[@]}"; do
            candidate="$(apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2}')"
            if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
                missing_candidates+=("$package")
            fi
        done

        if [ "${#missing_candidates[@]}" -gt 0 ]; then
            log "Docker packages are still unavailable after repository setup: ${missing_candidates[*]}" "ERROR"
            log "Check Debian/DietPi codename, architecture, network access, and Docker repository support." "ERROR"
            return 1
        fi
    fi

    wait_for_apt
    if ! sudo apt-get install -y "${docker_packages[@]}"; then
        log "Docker CE installation failed. Returning to menu." "ERROR"
        return 1
    fi

    if getent group docker >/dev/null 2>&1; then
        if sudo usermod -aG docker "$SUDO_USER"; then
            log "Docker CE and tools installed successfully. User added to group 'docker'."
        else
            log "Docker was installed, but adding user '$SUDO_USER' to group 'docker' failed." "WARN"
            return 1
        fi
    else
        log "Docker installed, but group 'docker' was not found." "WARN"
        return 1
    fi
}

###############################################################################
# FUNCTION: docker_maintenance
# Description: Docker housekeeping submenu: prune unused data and/or pull and
#              restart all discovered Docker Compose stacks.
###############################################################################
docker_maintenance() {
    if ! command -v docker >/dev/null 2>&1; then
        log "Docker is not installed." "ERROR"
        return 1
    fi

    local choice
    echo
    echo "Docker maintenance:"
    echo "  1) Prune unused data (stopped containers, networks, dangling images, build cache)"
    echo "  2) Update all Docker Compose stacks (pull + up -d)"
    echo "  3) Cancel"
    read -rp "Enter your choice: " choice < /dev/tty

    case "$choice" in
        1) docker_prune ;;
        2) docker_compose_update ;;
        3|"") log "Docker maintenance cancelled." ;;
        *)
            log "Invalid Docker maintenance choice." "ERROR"
            return 1
            ;;
    esac
}

###############################################################################
# FUNCTION: docker_prune
# Description: Show current Docker disk usage and prune unused data after
#              confirmation. Optionally also removes all unused images (-a).
###############################################################################
docker_prune() {
    echo
    echo "Current Docker disk usage:"
    sudo docker system df || true
    echo

    local include_images response
    read -rp "Also remove ALL unused images, not only dangling ones? [y/N]: " include_images < /dev/tty
    read -rp "Proceed with prune? [y/N]: " response < /dev/tty
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Docker prune cancelled."
        return 0
    fi

    if [[ "$include_images" =~ ^[Yy]$ ]]; then
        sudo docker system prune -af
    else
        sudo docker system prune -f
    fi

    log "Docker prune completed."
}

###############################################################################
# FUNCTION: docker_compose_update
# Description: Discover Docker Compose files under common locations and, after
#              confirmation, pull images and restart each stack.
###############################################################################
docker_compose_update() {
    if ! sudo docker compose version >/dev/null 2>&1; then
        log "Docker Compose plugin is not available." "ERROR"
        return 1
    fi

    local search_dirs=("$USER_HOME" /opt /srv)
    local compose_files=()
    local dir file

    while IFS= read -r file; do
        compose_files+=("$file")
    done < <(
        for dir in "${search_dirs[@]}"; do
            [ -d "$dir" ] || continue
            find "$dir" -maxdepth 3 -type f \
                \( -name docker-compose.yml -o -name docker-compose.yaml \
                   -o -name compose.yml -o -name compose.yaml \) 2>/dev/null
        done | sort -u
    )

    if [ "${#compose_files[@]}" -eq 0 ]; then
        log "No Docker Compose files found under: ${search_dirs[*]} (max depth 3)." "WARN"
        return 0
    fi

    echo
    echo "Found Docker Compose stacks:"
    printf '  %s\n' "${compose_files[@]}"
    local response
    read -rp "Pull images and restart all of these stacks? [y/N]: " response < /dev/tty
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Compose stack update cancelled."
        return 0
    fi

    local failed=()
    for file in "${compose_files[@]}"; do
        log "Updating stack: $file"
        if sudo docker compose -f "$file" pull && sudo docker compose -f "$file" up -d; then
            log "Stack updated: $file"
        else
            failed+=("$file")
            log "Failed to update stack: $file" "WARN"
        fi
    done

    if [ "${#failed[@]}" -gt 0 ]; then
        log "Stacks with errors: ${failed[*]}" "ERROR"
        return 1
    fi

    log "All Compose stacks updated successfully."
}

###############################################################################
# FUNCTION: remove_docker_and_tools
# Description: Remove Docker packages, repo files, keys, and data directories
###############################################################################
remove_docker_and_tools() {
    log "Removing Docker CE and related tools."

    local docker_packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
        docker-ce-rootless-extras
    )
    local installed_packages=()
    local package

    # apt-get purge exits with an error when asked to remove package names that
    # are unknown to the configured repositories. Build a purge list from packages
    # that are actually installed so this action remains safe on hosts without Docker.
    for package in "${docker_packages[@]}"; do
        if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^i'; then
            installed_packages+=("$package")
        fi
    done

    local has_data=0
    if [ -d /var/lib/docker ] || [ -d /var/lib/containerd ]; then
        has_data=1
    fi

    # Only demand the typed REMOVE confirmation when something destructive is
    # actually about to happen. On a host where the packages and data are
    # already gone, this action just cleans up leftovers (APT repository
    # files, the docker group and its memberships) and a plain yes suffices.
    local confirmation
    if [ "${#installed_packages[@]}" -eq 0 ] && [ "$has_data" -eq 0 ]; then
        echo
        echo "Docker is not installed and no data directories remain."
        echo "This cleans up leftovers: Docker APT repository files, the docker"
        echo "group, and its group memberships."
        read -rp "Clean up Docker leftovers? [y/N]: " confirmation < /dev/tty
        if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
            log "Docker removal cancelled."
            return 0
        fi
    else
        echo
        echo "WARNING: This permanently removes Docker packages and deletes:"
        echo "  /var/lib/docker"
        echo "  /var/lib/containerd"
        echo "This includes local containers, images, volumes, and build data."
        read -rp "Type REMOVE to continue: " confirmation < /dev/tty
        if [ "$confirmation" != "REMOVE" ]; then
            log "Docker removal cancelled."
            return 0
        fi
    fi

    if [ "${#installed_packages[@]}" -gt 0 ]; then
        wait_for_apt
        if ! sudo apt-get purge -y "${installed_packages[@]}"; then
            log "Docker package purge failed; data directories were not removed." "ERROR"
            return 1
        fi
    else
        log "No Docker packages are installed. Skipping package purge."
    fi

    wait_for_apt
    if ! sudo apt-get autoremove -y; then
        log "apt-get autoremove failed during Docker cleanup; continuing with file/group cleanup." "WARN"
    fi

    sudo rm -f -- /etc/apt/sources.list.d/docker.sources
    sudo rm -f -- /etc/apt/sources.list.d/docker.list
    sudo rm -f -- /etc/apt/keyrings/docker.asc

    sudo rm -rf --one-file-system -- /var/lib/docker
    sudo rm -rf --one-file-system -- /var/lib/containerd

    # Remove all supplementary users from the docker group before deleting it.
    # This does not delete user accounts; it only removes docker group membership.
    if getent group docker >/dev/null 2>&1; then
        local docker_members
        docker_members="$(getent group docker | awk -F: '{print $4}')"

        if [ -n "$docker_members" ]; then
            IFS=',' read -ra members <<< "$docker_members"
            for member in "${members[@]}"; do
                if [ -n "$member" ]; then
                    if sudo gpasswd -d "$member" docker >/dev/null 2>&1; then
                        log "Removed user '$member' from docker group."
                    else
                        log "Could not remove user '$member' from docker group." "WARN"
                    fi
                fi
            done
        fi

        if sudo groupdel docker >/dev/null 2>&1; then
            log "Removed docker group."
        else
            log "Could not remove docker group. It may be a primary group for one or more users." "WARN"
        fi
    else
        log "Docker group does not exist. No group cleanup needed."
    fi

    log "Docker packages, group memberships, repository configuration, and data directories removed."
}

###############################################################################
# FUNCTION: install_wakeonlan
# Description: Install Wake-on-LAN tools
###############################################################################
install_wakeonlan() {
    log "Installing Wake-on-LAN tools."

    if dpkg-query -W -f='${db:Status-Abbrev}' wakeonlan 2>/dev/null | grep -q '^i'; then
        log "wakeonlan is already installed. No changes needed."
    else
        wait_for_apt
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
# FUNCTION: clone_fastfetch_repository
# Description: Clone/update the update-fastfetch repository and optionally run
#              the updater. The repository's own updatefastfetch.sh is the
#              source of truth; earlier hostctl versions overwrote it with an
#              embedded copy, so any such local changes are discarded before
#              updating.
###############################################################################
clone_fastfetch_repository() {
    log "Preparing update-fastfetch repository."

    local REPO_URL="https://github.com/mews-se/update-fastfetch.git"
    local DEST_DIR="$USER_HOME/update-fastfetch"
    local SCRIPT_PATH="$DEST_DIR/updatefastfetch.sh"
    local response

    if [ -d "$DEST_DIR/.git" ]; then
        log "Repository already exists at $DEST_DIR. Updating."
        # Discard local modifications (earlier hostctl versions wrote over
        # updatefastfetch.sh, which makes a plain pull abort).
        sudo -u "$SUDO_USER" git -C "$DEST_DIR" checkout -- . 2>/dev/null || true
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

    if [ ! -f "$SCRIPT_PATH" ]; then
        log "updatefastfetch.sh not found in the repository." "ERROR"
        return 1
    fi
    sudo -u "$SUDO_USER" chmod 0750 "$SCRIPT_PATH"

    log "update-fastfetch ready at $SCRIPT_PATH"

    echo
    read -rp "Run the fastfetch updater now? [y/N]: " response < /dev/tty
    if [[ "$response" =~ ^[Yy]$ ]]; then
        if ! bash "$SCRIPT_PATH" < /dev/tty; then
            log "Fastfetch updater run failed." "ERROR"
            return 1
        fi
        log "Fastfetch updater completed."
    fi
}

###############################################################################
# FUNCTION: clone_geodebtest_repository
# Description: Clone/update the geodebtest repo (Debian mirror benchmark:
#              autodetects country, fetches the official mirror list, ranks by
#              ping/TTFB/download speed) and optionally run it right away.
#              Since v2026.07.31-2 the benchmark can also apply the chosen
#              mirror to the APT sources, with its own backup and rollback.
###############################################################################
clone_geodebtest_repository() {
    log "Preparing geodebtest repository."

    local REPO_URL="https://github.com/mews-se/geodebtest.git"
    local DEST_DIR="$USER_HOME/geodebtest"
    local SCRIPT_PATH="$DEST_DIR/geodebtest.sh"
    local response

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

    if [ ! -f "$SCRIPT_PATH" ]; then
        log "geodebtest.sh not found in the repository." "ERROR"
        return 1
    fi
    sudo -u "$SUDO_USER" chmod 0750 "$SCRIPT_PATH"

    log "geodebtest ready at $SCRIPT_PATH"

    echo
    echo "After the benchmark, geodebtest offers to apply the mirror you pick"
    echo "to the APT sources (press Enter at its prompt to skip). It backs up"
    echo "and validates the sources itself, and rolls back on failure."
    read -rp "Run the Debian mirror benchmark now? [y/N]: " response < /dev/tty
    if [[ "$response" =~ ^[Yy]$ ]]; then
        # Run as root: the measurement itself is read-only, but the optional
        # apply-to-APT step at the end requires root to edit the sources.
        if ! bash "$SCRIPT_PATH" < /dev/tty; then
            log "geodebtest run failed." "ERROR"
            return 1
        fi
        log "geodebtest benchmark completed."
    fi
}

###############################################################################
# FUNCTION: show_available_backups
# Description: Show latest backup files for important configuration files
###############################################################################
show_available_backups() {
    log "Showing available backups."

    local user_home="$USER_HOME"

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

    # APT sources are backed up by geodebtest into its own directory.
    local apt_backup_dir="$user_home/geodebtest/backups"
    local apt_files=(
        "/etc/apt/sources.list"
        "/etc/apt/sources.list.d/debian.sources"
    )
    for file in "${apt_files[@]}"; do
        echo
        echo "File: $file (backups in $apt_backup_dir)"
        latest_backup="$(find_latest_backup "$file" "$apt_backup_dir" || true)"

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

    local user_home="$USER_HOME"
    local target_file latest_backup choice response
    local current_backup=""
    # geodebtest keeps its APT source backups in its own directory, because
    # APT complains about unknown files inside sources.list.d.
    local apt_backup_dir=""
    local geodebtest_backups="$user_home/geodebtest/backups"

    echo "Select file to restore:"
    echo "  1) /etc/sudoers.d/99-sudo-nopasswd"
    echo "  2) /etc/ssh/sshd_config"
    echo "  3) /etc/snmp/snmpd.conf"
    echo "  4) $user_home/.bashrc"
    echo "  5) $user_home/.bash_aliases"
    echo "  6) /etc/apt/sources.list (geodebtest backup)"
    echo "  7) /etc/apt/sources.list.d/debian.sources (geodebtest backup)"
    echo "  8) Cancel"

    read -rp "Enter your choice: " choice < /dev/tty

    case "$choice" in
        1) target_file="/etc/sudoers.d/99-sudo-nopasswd" ;;
        2) target_file="/etc/ssh/sshd_config" ;;
        3) target_file="/etc/snmp/snmpd.conf" ;;
        4) target_file="$user_home/.bashrc" ;;
        5) target_file="$user_home/.bash_aliases" ;;
        6)
            target_file="/etc/apt/sources.list"
            apt_backup_dir="$geodebtest_backups"
            ;;
        7)
            target_file="/etc/apt/sources.list.d/debian.sources"
            apt_backup_dir="$geodebtest_backups"
            ;;
        8)
            log "Restore cancelled."
            return 0
            ;;
        *)
            log "Invalid restore choice." "ERROR"
            return 1
            ;;
    esac

    latest_backup="$(find_latest_backup "$target_file" ${apt_backup_dir:+"$apt_backup_dir"} || true)"

    if [ -z "$latest_backup" ]; then
        log "No backup found for $target_file" "ERROR"
        return 1
    fi

    echo "Latest backup found:"
    echo "  $latest_backup"
    read -rp "Restore this backup? [y/N]: " response < /dev/tty

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Restore aborted."
        return 0
    fi

    # Validate security-sensitive backups before touching the live files.
    case "$target_file" in
        "/etc/sudoers.d/99-sudo-nopasswd")
            if ! sudo visudo -cf "$latest_backup" >/dev/null 2>&1; then
                log "Selected sudoers backup failed validation; nothing was changed." "ERROR"
                return 1
            fi
            ;;
        "/etc/ssh/sshd_config")
            if ! sudo sshd -t -f "$latest_backup"; then
                log "Selected SSH backup failed validation; nothing was changed." "ERROR"
                return 1
            fi
            ;;
    esac

    if [ -f "$target_file" ]; then
        if [ -n "$apt_backup_dir" ]; then
            # The pre-restore copy of an APT source must not live next to the
            # file (APT scans sources.list.d), so use geodebtest's backup
            # directory and naming; geodebtest prunes it on its next apply.
            sudo mkdir -p "$apt_backup_dir"
            current_backup="${apt_backup_dir}/$(basename "$target_file").bak_$(date +%Y%m%d_%H%M%S)"
            if ! sudo cp -p "$target_file" "$current_backup"; then
                log "Could not preserve the current file before restore: $target_file" "ERROR"
                return 1
            fi
        else
            current_backup="$(backup_file "$target_file")" || {
                log "Could not preserve the current file before restore: $target_file" "ERROR"
                return 1
            }
        fi
    fi

    rollback_restored_file() {
        if [ -n "$current_backup" ] && [ -f "$current_backup" ]; then
            sudo cp --preserve=mode,ownership,timestamps "$current_backup" "$target_file"
            log "Restore rolled back to the pre-restore file: $current_backup" "WARN"
        fi
    }

    if [[ "$target_file" == /etc/* ]]; then
        sudo cp --preserve=mode,ownership,timestamps "$latest_backup" "$target_file"
    else
        sudo -u "$SUDO_USER" cp "$latest_backup" "$target_file"
    fi

    case "$target_file" in
        "/etc/sudoers.d/99-sudo-nopasswd")
            if ! sudo visudo -cf /etc/sudoers >/dev/null 2>&1; then
                rollback_restored_file
                log "Full sudoers validation failed after restore; previous file restored." "ERROR"
                return 1
            fi
            ;;
        "/etc/ssh/sshd_config")
            if ! restart_ssh_service; then
                rollback_restored_file
                restart_ssh_service || log "SSH restart failed after restore rollback. Manual intervention required." "ERROR"
                log "SSH restart failed after restore; previous file restored." "ERROR"
                return 1
            fi
            log "SSH service restarted after restore."
            ;;
        "/etc/snmp/snmpd.conf")
            if sudo systemctl is-active --quiet snmpd; then
                if sudo systemctl restart snmpd; then
                    log "snmpd restarted after restore."
                else
                    rollback_restored_file
                    sudo systemctl restart snmpd ||
                        log "snmpd failed to restart after restore rollback. Manual intervention required." "ERROR"
                    log "Failed to restart snmpd after restore; previous file restored." "ERROR"
                    return 1
                fi
            else
                log "snmpd not active; restart manually if needed." "WARN"
            fi
            ;;
        "/etc/apt/sources.list"|"/etc/apt/sources.list.d/debian.sources")
            wait_for_apt
            if ! sudo apt-get update; then
                rollback_restored_file
                wait_for_apt
                sudo apt-get update ||
                    log "apt-get update failed even after rollback. Manual intervention required." "ERROR"
                log "apt-get update failed with the restored sources; previous file restored." "ERROR"
                return 1
            fi
            mark_apt_lists_fresh
            log "APT sources restored and package lists refreshed."
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

    local user_home="$USER_HOME"
    local ssh_key="$user_home/.ssh/id_ed25519"
    local ssh_pub="$user_home/.ssh/id_ed25519.pub"

    echo "Health check results:"
    echo "---------------------"

    if grep -q '^%sudo ALL=(ALL) NOPASSWD: ALL$' /etc/sudoers.d/99-sudo-nopasswd 2>/dev/null; then
        echo "[OK]    sudoers configured for passwordless sudo"
    else
        echo "[ERROR] sudoers entry missing or incorrect"
    fi

    # Check the effective sshd configuration (including Include drop-ins)
    # rather than grepping the raw file, where a commented-out line would
    # otherwise produce a false [OK].
    local effective_sshd=""
    effective_sshd="$(sudo sshd -T 2>/dev/null || true)"

    if grep -q '^permitrootlogin no$' <<< "$effective_sshd"; then
        echo "[OK]    SSH root login disabled"
    else
        echo "[ERROR] SSH root login not configured as expected"
    fi

    if grep -q '^allowusers ' <<< "$effective_sshd"; then
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

    if dpkg-query -W -f='${db:Status-Abbrev}' snmpd 2>/dev/null | grep -q '^i'; then
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

    if [ -d "$user_home/geodebtest" ]; then
        echo "[OK]    geodebtest repository exists"
    else
        echo "[WARN]  geodebtest repository missing"
    fi

    if command -v wakeonlan >/dev/null 2>&1; then
        echo "[OK]    wakeonlan command available"
    else
        echo "[WARN]  wakeonlan command not available"
    fi

    # Root filesystem usage
    local disk_pct
    disk_pct="$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9')"
    if [ -n "$disk_pct" ]; then
        if [ "$disk_pct" -ge 85 ]; then
            echo "[WARN]  Root filesystem usage: ${disk_pct}%"
        else
            echo "[OK]    Root filesystem usage: ${disk_pct}%"
        fi
    else
        echo "[WARN]  Could not determine root filesystem usage"
    fi

    # Failed systemd units
    local failed_units
    failed_units="$(sudo systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
    if [ -z "$failed_units" ]; then
        echo "[OK]    No failed systemd units"
    else
        echo "[WARN]  Failed systemd units:"
        sed 's/^/          /' <<< "$failed_units"
    fi

    # CPU temperature (thermal zone 0 where available)
    local temp_raw temp_c
    if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        temp_raw="$(cat /sys/class/thermal/thermal_zone0/temp)"
        temp_c=$((temp_raw / 1000))
        if [ "$temp_c" -ge 75 ]; then
            echo "[WARN]  CPU temperature: ${temp_c}C"
        else
            echo "[OK]    CPU temperature: ${temp_c}C"
        fi
    else
        echo "[INFO]  CPU temperature not available on this platform"
    fi

    # WiFi power save makes a host miss broadcast ARP requests and become
    # unreachable from the LAN, so surface it per wireless interface.
    local wifi_dir wifi_iface ps_state
    for wifi_dir in /sys/class/net/*/wireless; do
        [ -d "$wifi_dir" ] || continue
        wifi_iface="$(basename "$(dirname "$wifi_dir")")"
        ps_state="$(iw dev "$wifi_iface" get power_save 2>/dev/null | awk -F': ' '{print $2}')"
        if [ "$ps_state" = "on" ]; then
            echo "[WARN]  WiFi power save is on for ${wifi_iface} (host can become unreachable from LAN)"
        elif [ "$ps_state" = "off" ]; then
            echo "[OK]    WiFi power save is off for ${wifi_iface}"
        fi
    done

    # Pending package updates, based on the current package lists. The count
    # is only as fresh as the last apt-get update (run at script startup).
    local pending_updates
    pending_updates="$(apt-get -s dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)"
    if [ "$pending_updates" -eq 0 ]; then
        echo "[OK]    No pending package updates"
    else
        echo "[WARN]  Pending package updates: $pending_updates"
    fi
}

###############################################################################
# FUNCTION: show_important_paths
# Description: Show important file paths, directories, and expected locations
###############################################################################
show_important_paths() {
    log "Showing important paths."

    local user_home="$USER_HOME"
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
    echo "geodebtest:"
    echo "  $user_home/geodebtest"
    echo
    echo "Wake-on-LAN:"
    echo "  $(command -v wakeonlan 2>/dev/null || echo 'not installed')"
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
# FUNCTION: configure_ufw
# Description: Optionally install and configure a conservative UFW baseline:
#              deny inbound traffic, allow outbound traffic, and keep SSH open.
#              When PiVPN or SNMPD is configured on the host, their ports are
#              allowed as well.
###############################################################################
configure_ufw() {
    log "Configuring UFW firewall."

    if ! command -v ufw >/dev/null 2>&1; then
        wait_for_apt
        if ! sudo apt-get install -y ufw; then
            log "Failed to install ufw." "ERROR"
            return 1
        fi
    fi

    # Baseline rules are intentionally minimal. SSH is allowed before enabling
    # the firewall to avoid locking out the current administration session.
    if ! sudo ufw default deny incoming; then
        log "Failed to set UFW default incoming policy." "ERROR"
        return 1
    fi

    if ! sudo ufw default allow outgoing; then
        log "Failed to set UFW default outgoing policy." "ERROR"
        return 1
    fi

    if ! sudo ufw allow OpenSSH; then
        if ! sudo ufw allow ssh; then
            log "Failed to add SSH allow rule to UFW." "ERROR"
            return 1
        fi
    fi

    # Allow the PiVPN VPN port when PiVPN is configured on this host. The
    # port and protocol are read from PiVPN's own setupVars.conf instead of
    # being hardcoded (WireGuard default is 51820/udp, OpenVPN 1194/udp).
    # The port only admits handshakes; forwarded client traffic falls under
    # ufw's separate routed policy, so the VPN interface needs a route rule.
    local pivpn_setupvars pivpn_port pivpn_proto pivpn_dev pivpn_rule=""
    local pivpn_net pivpn_mask pivpn_lan_dev
    for pivpn_setupvars in /etc/pivpn/wireguard/setupVars.conf /etc/pivpn/openvpn/setupVars.conf; do
        [ -f "$pivpn_setupvars" ] || continue
        pivpn_port="$(grep -m1 '^pivpnPORT=' "$pivpn_setupvars" | cut -d= -f2- | tr -dc '0-9')"
        pivpn_proto="$(grep -m1 '^pivpnPROTO=' "$pivpn_setupvars" | cut -d= -f2- | tr -dc 'a-z')"
        pivpn_proto="${pivpn_proto:-udp}"
        pivpn_dev="$(grep -m1 '^pivpnDEV=' "$pivpn_setupvars" | cut -d= -f2- | tr -dc 'a-z0-9')"
        case "$pivpn_setupvars" in
            */wireguard/*) pivpn_dev="${pivpn_dev:-wg0}" ;;
            */openvpn/*) pivpn_dev="${pivpn_dev:-tun0}" ;;
        esac
        if [ -n "$pivpn_port" ]; then
            if sudo ufw allow "${pivpn_port}/${pivpn_proto}"; then
                pivpn_rule="${pivpn_port}/${pivpn_proto}"
                log "UFW allow rule added for PiVPN: $pivpn_rule"
            else
                log "Failed to add UFW rule for PiVPN port ${pivpn_port}/${pivpn_proto}." "WARN"
            fi
        fi
        if sudo ufw route allow in on "$pivpn_dev"; then
            log "UFW route rule added: forwarded traffic from $pivpn_dev allowed."
        else
            log "Failed to add UFW route rule for $pivpn_dev; VPN clients may lack internet." "WARN"
        fi
        # pivpn adds its own subnet-scoped route rule when it sees ufw; the
        # generic rule above covers it, so drop the duplicate if present.
        pivpn_net="$(grep -m1 '^pivpnNET=' "$pivpn_setupvars" | cut -d= -f2- | tr -dc '0-9.')"
        pivpn_mask="$(grep -m1 '^subnetClass=' "$pivpn_setupvars" | cut -d= -f2- | tr -dc '0-9')"
        pivpn_lan_dev="$(grep -m1 '^IPv4dev=' "$pivpn_setupvars" | cut -d= -f2- | tr -dc 'a-z0-9')"
        if [ -n "$pivpn_net" ] && [ -n "$pivpn_mask" ] && [ -n "$pivpn_lan_dev" ]; then
            if sudo ufw route delete allow in on "$pivpn_dev" from "${pivpn_net}/${pivpn_mask}" out on "$pivpn_lan_dev" to any 2>/dev/null | grep -q "Rule deleted"; then
                log "Removed PiVPN's subnet-scoped duplicate forward rule."
            fi
        fi
    done
    if [ -z "$pivpn_rule" ] && command -v pivpn >/dev/null 2>&1; then
        log "PiVPN is installed but its port could not be determined; add the UFW rule manually." "WARN"
    fi

    # Allow SNMP when snmpd is installed on this host, so monitoring polls
    # are not cut off by the baseline. The port is read from the agentaddress
    # line in snmpd.conf when possible (the hostctl default is udp:161).
    local snmp_rule=""
    if dpkg-query -W -f='${db:Status-Abbrev}' snmpd 2>/dev/null | grep -q '^i'; then
        local snmp_port
        snmp_port="$(awk '$1 == "agentaddress" {print $2}' /etc/snmp/snmpd.conf 2>/dev/null | \
            grep -oE '[0-9]+$' | head -n1)"
        snmp_port="${snmp_port:-161}"
        if sudo ufw allow "${snmp_port}/udp"; then
            snmp_rule="${snmp_port}/udp"
            log "UFW allow rule added for SNMP: $snmp_rule"
        else
            log "Failed to add UFW rule for SNMP port ${snmp_port}/udp." "WARN"
        fi
    fi

    local extras=""
    if [ -n "$pivpn_rule" ]; then
        extras+=", allow PiVPN ($pivpn_rule + forwarding via $pivpn_dev)"
    fi
    if [ -n "$snmp_rule" ]; then
        extras+=", allow SNMP ($snmp_rule)"
    fi

    echo
    echo "UFW baseline is ready: deny incoming, allow outgoing, allow SSH${extras}."
    read -rp "Enable UFW now? [y/N]: " enable_ufw < /dev/tty
    if [[ "$enable_ufw" =~ ^[Yy]$ ]]; then
        if sudo ufw --force enable; then
            log "UFW enabled."
        else
            log "Failed to enable UFW." "ERROR"
            return 1
        fi
    else
        log "UFW configured but not enabled." "WARN"
    fi

    sudo ufw status verbose || log "Could not read UFW status." "WARN"
}

###############################################################################
# FUNCTION: disable_wifi_powersave
# Description: Disable WiFi power management on all wireless interfaces, now
#              and persistently via a systemd oneshot service. Power save on
#              Raspberry Pi WiFi makes the host miss broadcast ARP requests,
#              leaving it unreachable from the LAN while its own outbound
#              traffic keeps working.
###############################################################################
disable_wifi_powersave() {
    log "Disabling WiFi power save."

    local -a wifi_ifaces=()
    local wifi_dir iface
    for wifi_dir in /sys/class/net/*/wireless; do
        [ -d "$wifi_dir" ] && wifi_ifaces+=("$(basename "$(dirname "$wifi_dir")")")
    done

    if [ "${#wifi_ifaces[@]}" -eq 0 ]; then
        log "No wireless interfaces found on this host. Nothing to do."
        return 0
    fi

    if ! command -v iw >/dev/null 2>&1; then
        wait_for_apt
        if ! sudo apt-get install -y iw; then
            log "Failed to install iw." "ERROR"
            return 1
        fi
    fi

    for iface in "${wifi_ifaces[@]}"; do
        if sudo iw dev "$iface" set power_save off 2>/dev/null; then
            log "Power save disabled on $iface (current session)."
        else
            log "Could not disable power save on $iface (interface down?)." "WARN"
        fi
    done

    # Persist across reboots with a oneshot service covering every wireless
    # interface present at boot.
    local unit_file="/etc/systemd/system/wifi-powersave-off.service"
    local unit_tmp
    unit_tmp="$(sudo mktemp /etc/systemd/system/.hostctl-wifi-powersave.XXXXXX)"
    if ! cat <<'EOF' | sudo tee "$unit_tmp" >/dev/null
[Unit]
Description=Disable WiFi power save on all wireless interfaces
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for d in /sys/class/net/*/wireless; do [ -d "$d" ] || continue; i="${d%/wireless}"; iw dev "${i##*/}" set power_save off || true; done'

[Install]
WantedBy=multi-user.target
EOF
    then
        sudo rm -f "$unit_tmp"
        log "Failed to write the systemd unit." "ERROR"
        return 1
    fi

    if ! sudo install -o root -g root -m 0644 "$unit_tmp" "$unit_file"; then
        sudo rm -f "$unit_tmp"
        log "Failed to install $unit_file." "ERROR"
        return 1
    fi
    sudo rm -f "$unit_tmp"

    if ! sudo systemctl daemon-reload; then
        log "systemctl daemon-reload failed." "ERROR"
        return 1
    fi
    if ! sudo systemctl enable wifi-powersave-off.service >/dev/null 2>&1; then
        log "Failed to enable wifi-powersave-off.service." "ERROR"
        return 1
    fi
    sudo systemctl start wifi-powersave-off.service 2>/dev/null || true

    log "WiFi power save disabled persistently via wifi-powersave-off.service."
}

###############################################################################
# FUNCTION: menu
# Description: Interactive menu exposing standard setup, optional operations,
#              verification helpers, and exit handling.
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
        echo ""
        echo "System:"
        echo "   1) System update and upgrade"
        echo "   2) Check if reboot is required"
        echo "   3) DietPi: Bullseye -> Bookworm"
        echo "   4) DietPi: Bookworm -> Trixie"
        echo "   5) Self-update hostctl"
        echo ""
        echo "Setup and configuration:"
        echo "   6) Update sudoers"
        echo "   7) Configure SSH"
        echo "   8) Generate SSH key"
        echo "   9) Distribute SSH key to other hosts"
        echo "  10) Create/Update .bashrc"
        echo "  11) Create/Update .bash_aliases"
        echo "  12) Configure UFW firewall"
        echo "  13) Disable WiFi power save"
        echo ""
        echo "Services and applications:"
        echo "  14) Install and configure SNMPD"
        echo "  15) Remove SNMPD"
        echo "  16) Install Docker official repo"
        echo "  17) Install Docker and relevant tools"
        echo "  18) Docker maintenance (prune / Compose update)"
        echo "  19) Remove Docker and relevant tools"
        echo "  20) Install PiVPN"
        echo "  21) Remove PiVPN"
        echo "  22) Install Wake-on-LAN tools"
        echo "  23) Clone/update the update-fastfetch repo"
        echo "  24) Clone/update geodebtest (Debian mirror benchmark)"
        echo ""
        echo "Status and recovery:"
        echo "  25) Run health check"
        echo "  26) Show important paths"
        echo "  27) Show current profile config"
        echo "  28) Show available backups"
        echo "  29) Restore from backup"
        echo ""
        echo "   0) Exit"

        read -rp "Enter your choice: " choice < /dev/tty

        case "$choice" in
            1) run_menu_action "System update and upgrade" system_update_upgrade ;;
            2) run_menu_action "Check if reboot is required" check_reboot_required ;;
            3) run_menu_action "DietPi: Bullseye -> Bookworm" dietpi_bullseye_to_bookworm ;;
            4) run_menu_action "DietPi: Bookworm -> Trixie" dietpi_bookworm_to_trixie ;;
            5) run_menu_action "Self-update hostctl" self_update ;;
            6) run_menu_action "Update sudoers" update_sudoers ;;
            7) run_menu_action "Configure SSH" configure_ssh ;;
            8) run_menu_action "Generate SSH key" generate_ssh_key ;;
            9) run_menu_action "Distribute SSH key to other hosts" distribute_ssh_key ;;
            10) run_menu_action "Create/Update .bashrc" create_bashrc ;;
            11) run_menu_action "Create/Update .bash_aliases" create_bash_aliases ;;
            12) run_menu_action "Configure UFW firewall" configure_ufw ;;
            13) run_menu_action "Disable WiFi power save" disable_wifi_powersave ;;
            14) run_menu_action "Install and configure SNMPD" install_configure_snmpd ;;
            15) run_menu_action "Remove SNMPD" remove_snmpd ;;
            16) run_menu_action "Install Docker official repo" install_docker_repository ;;
            17) run_menu_action "Install Docker and relevant tools" install_docker_ce ;;
            18) run_menu_action "Docker maintenance" docker_maintenance ;;
            19) run_menu_action "Remove Docker and relevant tools" remove_docker_and_tools ;;
            20) run_menu_action "Install PiVPN" install_pivpn ;;
            21) run_menu_action "Remove PiVPN" remove_pivpn ;;
            22) run_menu_action "Install Wake-on-LAN tools" install_wakeonlan ;;
            23) run_menu_action "Clone/update the update-fastfetch repo" clone_fastfetch_repository ;;
            24) run_menu_action "Clone/update geodebtest" clone_geodebtest_repository ;;
            25) run_menu_action "Run health check" run_health_check ;;
            26) run_menu_action "Show important paths" show_important_paths ;;
            27) run_menu_action "Show current profile config" show_current_profile_config ;;
            28) run_menu_action "Show available backups" show_available_backups ;;
            29) run_menu_action "Restore from backup" restore_from_backup ;;
            0)
                log "Script execution completed."
                log "Please apply the following command manually to source both .bashrc and .bash_aliases files:"
                echo ". $USER_HOME/.bashrc && . $USER_HOME/.bash_aliases"
                echo "Alternatively, log out and log back in to start a new shell session."
                echo "Log file: $LOG_FILE"
                exit 0
                ;;
            *)
                echo "Invalid choice. Please select a valid option."
                ;;
        esac

        read -rp "Press Enter to continue..." < /dev/tty
    done
}

###############################################################################
# START
###############################################################################
rotate_log_file
log "hostctl execution started. Version: $SCRIPT_VERSION"
select_profile
apply_profile_config
refresh_apt_package_lists
install_missing_packages
menu

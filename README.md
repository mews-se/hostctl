# Automated System Configuration Script

![Version](https://img.shields.io/badge/version-v2026.08.01-informational)
[![ShellCheck](https://github.com/mews-se/hostctl/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mews-se/hostctl/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Platform](https://img.shields.io/badge/platform-Debian%2FDietPi-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-blue)

`hostctl.sh` is an interactive Bash utility for post-install configuration and
maintenance of Debian, DietPi, Raspberry Pi, and home-lab systems.

It provides repeatable setup tasks while validating security-sensitive changes
and returning failed actions safely to the menu.

## Features

### System
- System update and distribution upgrade
- Reboot-required detection
- DietPi distribution upgrade helpers (Bullseye → Bookworm, Bookworm → Trixie)
- Self-update from GitHub with syntax validation and confirmation

### Setup and configuration
- Passwordless sudo configuration with `visudo` validation
- SSH hardening with effective-configuration validation and rollback
- Ed25519 SSH key generation
- SSH key distribution to other hosts via `ssh-copy-id`
- Atomic `.bashrc` recreation and interactive `.bash_aliases` merge
- UFW firewall baseline (SSH allowed; PiVPN port auto-allowed when configured)

### Services and applications
- Profile-based SNMPD installation, configuration, and removal
- Docker repository, installation, and removal tools
- Docker maintenance: prune unused data and update Docker Compose stacks
- PiVPN installation, client generation, and removal
- Wake-on-LAN tools
- Fastfetch repository and updater integration
- geodebtest integration: Debian mirror benchmark (clone/update and run; can apply the chosen mirror to the APT sources)

### Status and recovery
- Health check: configuration state, services, disk usage, failed systemd
  units, CPU temperature, and pending package updates
- Configuration backup and restore helpers with automatic pruning
- Profile information and important-path reporting

The interactive menu is grouped into these four sections, with recoverable
action failures and logging to the invoking user's `~/hostctl.log`.

## Profiles

A profile is selected when the script starts:

- `x64`
- `x64-brk`
- `pi`
- `pi-brk`

Profiles control SNMP community settings, hardware-information sources, and
other environment-specific defaults.

## Requirements

- Debian or DietPi
- Bash
- systemd
- An interactive terminal
- Network access for package installation and remote installers
- A normal local user with sudo access

The script installs its required Debian packages during startup. Run it through
`sudo` from the account that should receive the shell files, SSH key, generated
scripts, and log file.

## Installation and usage

```bash
git clone https://github.com/mews-se/hostctl.git
cd hostctl
sudo ./hostctl.sh
```

Select the appropriate profile, then choose individual actions from the
sectioned menu. Each action is self-contained and can be run independently;
a failed or cancelled action returns to the menu without terminating the
script.

## Safety behavior

### Configuration changes

Security-sensitive configuration is backed up before replacement.

- Sudoers candidates are validated before installation.
- SSH candidates are checked with both `sshd -t` and `sshd -T`.
- A failed SSH restart restores the previous configuration.
- Failed SNMP reloads restore the previous configuration.
- Restore operations validate supported configuration files before replacing
  the live version.

Timestamped backups are stored beside their corresponding files. The five
newest backups are kept per file; older ones are pruned automatically.

### Remote installers

DietPi upgrade helpers and the PiVPN installer are downloaded to secure
temporary files instead of being piped directly into Bash.

Before execution, the script:

1. Verifies Bash syntax.
2. Displays the download URL.
3. Displays the SHA-256 digest.
4. Requests confirmation before running the file as root.

### Self-update

The self-update action downloads the latest `hostctl.sh` from the `main`
branch, verifies Bash syntax, shows the current and new version, and requires
confirmation. The replacement is an atomic rename, so the running instance is
unaffected until restarted.

### Docker removal

Docker removal purges the Docker packages and permanently deletes:

```text
/var/lib/docker
/var/lib/containerd
```

The action requires typing `REMOVE` before deletion begins.

### SNMPD removal

SNMPD removal stops and disables the service and purges the package and its
configuration after confirmation. Timestamped `snmpd.conf` backups are kept,
and `lm-sensors` is left installed.

### PiVPN removal

PiVPN removal runs PiVPN's own interactive uninstaller (`pivpn -u`) in a
pseudo-terminal, the same way the installer is run. The uninstaller asks
which dependencies to remove and deletes the VPN server configuration.

## Docker maintenance

The Docker maintenance action offers:

- **Prune**: shows current Docker disk usage, then removes stopped containers,
  unused networks, dangling images, and build cache. Optionally also removes
  all unused images.
- **Compose stack update**: discovers Docker Compose files under the user's
  home directory, `/opt`, and `/srv`, then pulls images and restarts each
  stack after confirmation.

## Logs

The main script writes its log to:

```text
~/hostctl.log
```

The file is created and appended as the invoking user rather than as root.
When the log exceeds 1 MB it is rotated to `~/hostctl.log.old`, keeping one
previous generation.

## After running

- Start a new shell session after changing `.bashrc` or `.bash_aliases`.
- Log out and back in after joining the `docker` group.
- Review the reboot-required result after system upgrades.
- Test SSH access in a second session before closing the current connection.
- Restart the script after a self-update to run the new version.

## Validation

The main script is checked with:

```bash
bash -n hostctl.sh
shellcheck hostctl.sh
```

System-changing operations should still be tested on the intended Debian or
DietPi host before broad deployment.

## License

MIT License

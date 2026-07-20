# Automated System Configuration Script

![Version](https://img.shields.io/badge/version-v2026.07.20-informational)
![License](https://img.shields.io/badge/license-Unlicense-blue.svg)
![Platform](https://img.shields.io/badge/platform-Debian%2FDietPi-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-blue)

`hostctl.sh` is an interactive Bash utility for post-install configuration and
maintenance of Debian, DietPi, Raspberry Pi, and home-lab systems.

It provides repeatable setup tasks while validating security-sensitive changes
and returning failed actions safely to the menu.

## Features

- System update and distribution upgrade
- SSH hardening with effective-configuration validation and rollback
- Passwordless sudo configuration with `visudo` validation
- Ed25519 SSH key generation
- Atomic `.bashrc` recreation and interactive `.bash_aliases` merge
- Profile-based SNMPD installation and configuration
- Docker repository, installation, and removal tools
- PiVPN installation and client generation
- DietPi distribution upgrade helpers
- Fastfetch repository and updater integration
- Wake-on-LAN tools
- NAS backup script generation using rsync over CIFS
- Configuration backup and restore helpers
- UFW firewall baseline
- Health checks, profile information, and important-path reporting
- Reboot-required detection
- Interactive menu with recoverable action failures
- Logging to the invoking user's `~/hostctl.log`

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

Select the appropriate profile and then choose an individual action or **Run all
tasks** from the menu.

The **Run all tasks** option performs the standard provisioning workflow. It
does not run destructive or highly optional operations such as Docker removal,
PiVPN installation, DietPi release upgrades, backup restoration, or UFW
activation.

## Safety behavior

### Configuration changes

Security-sensitive configuration is backed up before replacement.

- Sudoers candidates are validated before installation.
- SSH candidates are checked with both `sshd -t` and `sshd -T`.
- A failed SSH restart restores the previous configuration.
- Failed SNMP reloads restore the previous configuration.
- Restore operations validate supported configuration files before replacing
  the live version.

Timestamped backups are stored beside their corresponding files.

### Remote installers

DietPi upgrade helpers and the PiVPN installer are downloaded to secure
temporary files instead of being piped directly into Bash.

Before execution, the script:

1. Verifies Bash syntax.
2. Displays the download URL.
3. Displays the SHA-256 digest.
4. Requests confirmation before running the file as root.

### Docker removal

Docker removal purges the Docker packages and permanently deletes:

```text
/var/lib/docker
/var/lib/containerd
```

The action requires typing `REMOVE` before deletion begins.

## NAS backup

The NAS backup action generates:

```text
~/nas-backup.sh
```

Credentials are stored with root-only permissions at:

```text
/root/.nas-credentials
```

The generated script:

- Mounts the configured CIFS share.
- Mirrors the host with rsync.
- Includes `/home` and `/mnt/dietpi_userdata`.
- Applies DietPi-style exclusions.
- Uses `flock` to prevent concurrent backups.
- Rejects an unexpected mount at the configured mount point.
- Only unmounts a share mounted by the current backup run.
- Stops selected services for consistency and restarts services that were
  previously active.
- Writes its local log to the invoking user's home directory.

The NAS host, share, mount point, backup root, and rsync exclusions can be
adjusted in the generated `nas-backup.sh`.

## Logs

The main script writes its log to:

```text
~/hostctl.log
```

The file is created and appended as the invoking user rather than as root.

The generated NAS backup script writes:

```text
~/nas-backup.log
```

## After running

- Start a new shell session after changing `.bashrc` or `.bash_aliases`.
- Log out and back in after joining the `docker` group.
- Review the reboot-required result after system upgrades.
- Test SSH access in a second session before closing the current connection.
- Review generated scripts and environment-specific configuration before
  scheduling unattended execution.

## Validation

The main script and both generated scripts are checked with:

```bash
bash -n hostctl.sh
shellcheck hostctl.sh
```

System-changing operations should still be tested on the intended Debian or
DietPi host before broad deployment.

## License

The Unlicense

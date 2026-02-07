# Debian Dynamic MOTD

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/language-Bash-green.svg)](https://www.gnu.org/software/bash/)

## What this script does
- Installs Ubuntu-like dynamic MOTD scripts under `/etc/update-motd.d/`.
- Installs `/usr/local/bin/update-motd` and `/usr/local/bin/motd-refresh`.
- Creates systemd units:
  - `/etc/systemd/system/motd-refresh.service`
  - `/etc/systemd/system/motd-refresh.timer`
- Updates:
  - `/etc/pam.d/sshd` (adds a managed dynamic MOTD block)
  - `/etc/ssh/sshd_config` (`UsePAM yes`, `PrintLastLog yes`, `PrintMotd no`)
- Validates `sshd_config` before restarting SSH and auto-rolls back on failure.

## Key safety design
- Uses timestamped backups for `sshd_config` and `pam.d/sshd`.
- Writes files atomically (`mktemp` + `mv`).
- Validates sshd syntax (`sshd -t -f /etc/ssh/sshd_config`) before service reload.
- Rolls back SSH-related files if validation/restart fails.
- Handles missing `needrestart` gracefully.

## Usage
```bash
sudo bash install-motd.sh
```

Optional:
```bash
sudo bash install-motd.sh --no-restart
sudo bash install-motd.sh --version
sudo bash install-motd.sh --help
```

## Verification on target Debian host
```bash
sudo /usr/local/bin/motd-refresh
sudo /usr/local/bin/update-motd
systemctl status motd-refresh.timer
sshd -t -f /etc/ssh/sshd_config
```

Then open a new SSH session to verify MOTD output.

## Rollback (manual)
The script creates timestamped backups:
- `/etc/pam.d/sshd.bak.<timestamp>`
- `/etc/ssh/sshd_config.bak.<timestamp>`

Restore example:
```bash
sudo cp -a /etc/pam.d/sshd.bak.<timestamp> /etc/pam.d/sshd
sudo cp -a /etc/ssh/sshd_config.bak.<timestamp> /etc/ssh/sshd_config
sudo sshd -t -f /etc/ssh/sshd_config
sudo systemctl restart ssh || sudo systemctl restart sshd
```


#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2026.02.07"
SCRIPT_NAME="$(basename "$0")"

UPDATE_DIR="/etc/update-motd.d"
GEN_BIN="/usr/local/bin/update-motd"
REFRESH_BIN="/usr/local/bin/motd-refresh"

PAM_SSHD="/etc/pam.d/sshd"
SSHD_CONFIG="/etc/ssh/sshd_config"

CACHE_DIR="/var/cache/motd"
UPD_META="${CACHE_DIR}/updates.meta"
SEC_LIST="${CACHE_DIR}/security-updates.list"
NR_META="${CACHE_DIR}/needrestart.meta"
NR_SVCS="${CACHE_DIR}/needrestart.services"

SRV_UNIT="/etc/systemd/system/motd-refresh.service"
TMR_UNIT="/etc/systemd/system/motd-refresh.timer"

MARK_BEGIN="# BEGIN MOTD-UBUNTUISH"
MARK_END="# END MOTD-UBUNTUISH"
BACKUP_SUFFIX=".bak.$(date +%Y%m%d%H%M%S)"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root. Example: sudo bash $0"
  fi
}

backup_file() {
  local path="$1"
  local backup=""

  if [[ -f "$path" ]]; then
    backup="${path}${BACKUP_SUFFIX}"
    cp -a -- "$path" "$backup"
    log "Backup created: $backup" >&2
  fi
  printf '%s\n' "$backup"
}

restore_file() {
  local backup="$1"
  local target="$2"
  if [[ -n "$backup" && -f "$backup" ]]; then
    cp -a -- "$backup" "$target"
    log "Restored from backup: $target"
  fi
}

write_owned_file_from_func() {
  local path="$1"
  local mode="$2"
  local content_func="$3"
  local tmp=""

  install -d -m 0755 "$(dirname "$path")"
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  "$content_func" > "$tmp"
  chmod "$mode" "$tmp"
  mv -f -- "$tmp" "$path"
  log "Wrote: $path"
}

try_install_needrestart() {
  if have_cmd needrestart; then
    return 0
  fi
  if ! have_cmd apt-get; then
    warn "apt-get is unavailable. Skip needrestart installation."
    return 1
  fi

  log "needrestart not found. Attempting install."
  if DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 -qq update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install needrestart >/dev/null; then
    log "needrestart installed."
    return 0
  fi

  warn "Failed to install needrestart. MOTD restart hints may be limited."
  return 1
}

content_10_header() {
  cat <<'EOF_10_HEADER'
#!/usr/bin/env bash
set -u

os_pretty="Linux"
if [[ -r /etc/os-release ]]; then
  os_pretty="$(
    . /etc/os-release
    printf '%s' "${PRETTY_NAME:-Linux}"
  )"
fi

kernel="$(uname -srmo 2>/dev/null || uname -sr 2>/dev/null || printf 'unknown')"
arch="$(uname -m 2>/dev/null || printf 'unknown')"
date_str="$(date 2>/dev/null || printf 'unknown')"

echo
echo "Welcome to ${os_pretty} (GNU/Linux ${kernel} ${arch})"
echo
echo " * Documentation:  https://www.debian.org/doc/"
echo " * Support:        https://www.debian.org/support"
echo
echo " System information as of ${date_str}"
echo
EOF_10_HEADER
}

content_50_sysinfo() {
  cat <<'EOF_50_SYSINFO'
#!/usr/bin/env bash
set -u

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

load="N/A"
if [[ -r /proc/loadavg ]]; then
  load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || printf 'N/A')"
fi

procs="$(ps -e --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
users="$(who 2>/dev/null | wc -l | tr -d '[:space:]')"
is_uint "$procs" || procs="0"
is_uint "$users" || users="0"

disk_line="$(df -hP / 2>/dev/null | awk 'NR==2{printf "%s of %s", $5, $2}')"
[[ -n "$disk_line" ]] || disk_line="N/A"

mem_pct="N/A"
swap_pct="N/A"
if have_cmd free; then
  mem_pct="$(free 2>/dev/null | awk '/^Mem:/ { if ($2>0) printf "%d%%", ($3/$2)*100; else print "0%" }')"
  swap_pct="$(free 2>/dev/null | awk '/^Swap:/ { if ($2>0) printf "%d%%", ($3/$2)*100; else print "0%" }')"
  [[ -n "$mem_pct" ]] || mem_pct="N/A"
  [[ -n "$swap_pct" ]] || swap_pct="N/A"
fi

iface=""
if have_cmd ip; then
  iface="$(ip route show default 2>/dev/null | awk 'NR==1{print $5; exit}')"
fi
if [[ -z "${iface}" && -r /proc/net/route ]]; then
  iface="$(awk '$2=="00000000" {print $1; exit}' /proc/net/route 2>/dev/null || true)"
fi
[[ -n "$iface" ]] || iface="unknown"

ipv4="N/A"
ipv6="N/A"
if have_cmd ip && [[ "$iface" != "unknown" ]]; then
  ipv4="$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
  ipv6="$(ip -6 addr show "$iface" scope global 2>/dev/null | awk '/inet6 /{print $2; exit}' | cut -d/ -f1)"
  [[ -n "$ipv4" ]] || ipv4="N/A"
  [[ -n "$ipv6" ]] || ipv6="N/A"
fi

echo
printf "  System load:  %-16s Processes:             %s\n" "$load" "$procs"
printf "  Usage of /:   %-16s Users logged in:       %s\n" "$disk_line" "$users"
printf "  Memory usage: %-16s IPv4 address for %s: %s\n" "$mem_pct" "$iface" "$ipv4"
printf "  Swap usage:   %-16s IPv6 address for %s: %s\n" "$swap_pct" "$iface" "$ipv6"
echo
EOF_50_SYSINFO
}

content_60_updates() {
  cat <<'EOF_60_UPDATES'
#!/usr/bin/env bash
set -u

meta="/var/cache/motd/updates.meta"
nr_meta="/var/cache/motd/needrestart.meta"
nr_svcs="/var/cache/motd/needrestart.services"
max_age=$((3 * 24 * 3600))

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

read_kv() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1==k {print $2; exit}' "$file" 2>/dev/null || true
}

mtime_epoch() {
  local file="$1"
  stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0
}

is_fresh() {
  local file="$1"
  local now age epoch
  [[ -f "$file" ]] || return 1
  now="$(date +%s)"
  epoch="$(read_kv "$file" generated_epoch)"
  if is_uint "$epoch"; then
    age=$((now - epoch))
  else
    epoch="$(mtime_epoch "$file")"
    is_uint "$epoch" || return 1
    age=$((now - epoch))
  fi
  (( age >= 0 && age <= max_age ))
}

if is_fresh "$meta"; then
  total="$(read_kv "$meta" total)"
  sec="$(read_kv "$meta" security)"
  is_uint "$total" || total="0"
  is_uint "$sec" || sec="0"

  if (( total > 0 )); then
    echo "${total} update(s) can be applied immediately."
    if (( sec > 0 )); then
      echo "${sec} of these updates are security updates."
    fi
    echo "To see these additional updates run: apt list --upgradable"
    echo
  fi
fi

if is_fresh "$nr_meta"; then
  ksta="$(read_kv "$nr_meta" ksta)"
  is_uint "$ksta" || ksta="0"

  if (( ksta == 3 )); then
    echo "*** System restart required ***"
    echo
  elif (( ksta == 2 )); then
    echo "System restart recommended."
    echo
  fi

  if [[ -s "$nr_svcs" ]]; then
    n="$(wc -l < "$nr_svcs" | tr -d '[:space:]')"
    is_uint "$n" || n="0"
    echo "Service restart required: ${n} service(s) should be restarted."
    echo "Services:"
    sed 's/^/  - /' "$nr_svcs" | head -n 12
    (( n > 12 )) && echo "  - (and more...)"
    echo
  fi
fi
EOF_60_UPDATES
}

content_80_reboot_required() {
  cat <<'EOF_80_REBOOT'
#!/usr/bin/env bash
set -u

nr_meta="/var/cache/motd/needrestart.meta"
ksta="0"
if [[ -f "$nr_meta" ]]; then
  ksta="$(awk -F= '$1=="ksta" {print $2; exit}' "$nr_meta" 2>/dev/null || echo 0)"
fi
[[ "$ksta" =~ ^[0-9]+$ ]] || ksta="0"

if [[ "$ksta" == "3" ]]; then
  exit 0
fi

req=""
pkgs=""
if [[ -f /run/reboot-required ]]; then
  req="/run/reboot-required"
  [[ -f /run/reboot-required.pkgs ]] && pkgs="/run/reboot-required.pkgs"
elif [[ -f /var/run/reboot-required ]]; then
  req="/var/run/reboot-required"
  [[ -f /var/run/reboot-required.pkgs ]] && pkgs="/var/run/reboot-required.pkgs"
fi

if [[ -n "$req" ]]; then
  echo "*** System restart required ***"
  if [[ -n "$pkgs" ]]; then
    echo "Packages requiring reboot:"
    sed 's/^/  - /' "$pkgs" | head -n 20
  fi
  echo
fi
EOF_80_REBOOT
}

content_update_motd() {
  cat <<'EOF_UPDATE_MOTD'
#!/usr/bin/env bash
set -Eeuo pipefail

out="/run/motd.dynamic"
tmp="$(mktemp "${out}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

LC_ALL=C
for f in /etc/update-motd.d/*; do
  [[ -x "$f" && -f "$f" ]] || continue
  "$f" >> "$tmp" 2>/dev/null || true
done

chmod 0644 "$tmp"
mv -f -- "$tmp" "$out"
trap - EXIT
EOF_UPDATE_MOTD
}

content_motd_refresh() {
  cat <<'EOF_REFRESH'
#!/usr/bin/env bash
set -Eeuo pipefail

cache_dir="/var/cache/motd"
upd_meta="${cache_dir}/updates.meta"
sec_list="${cache_dir}/security-updates.list"
nr_meta="${cache_dir}/needrestart.meta"
nr_svcs="${cache_dir}/needrestart.services"

meta_tmp="$(mktemp)"
seclist_tmp="$(mktemp)"
nrmeta_tmp="$(mktemp)"
nrsvcs_tmp="$(mktemp)"
cleanup() {
  rm -f "$meta_tmp" "$seclist_tmp" "$nrmeta_tmp" "$nrsvcs_tmp"
}
trap cleanup EXIT

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

mkdir -p "$cache_dir"
chmod 0755 "$cache_dir"

if command -v apt-get >/dev/null 2>&1; then
  apt_opts=(
    "-o" "Acquire::Retries=3"
    "-o" "DPkg::Lock::Timeout=30"
    "-qq"
  )
  if DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" update; then
    sim="$(DEBIAN_FRONTEND=noninteractive apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null || true)"

    total="$(printf '%s\n' "$sim" | awk '/^Inst /{c++} END{print c+0}')"
    security="$(printf '%s\n' "$sim" | awk '/^Inst / && tolower($0) ~ /security/{c++} END{print c+0}')"
    is_uint "$total" || total="0"
    is_uint "$security" || security="0"

    printf '%s\n' "$sim" | awk '/^Inst / && tolower($0) ~ /security/{print $2}' | sort -u > "$seclist_tmp" || true
    {
      echo "total=${total}"
      echo "security=${security}"
      echo "generated=$(date -Is)"
      echo "generated_epoch=$(date +%s)"
    } > "$meta_tmp"
    chmod 0644 "$meta_tmp" "$seclist_tmp"
    mv -f -- "$meta_tmp" "$upd_meta"
    mv -f -- "$seclist_tmp" "$sec_list"
  fi
fi

out=""
if command -v needrestart >/dev/null 2>&1; then
  out="$(needrestart -b -r l 2>/dev/null || true)"
fi

ksta="$(printf '%s\n' "$out" | awk -F': *' '/^NEEDRESTART-KSTA:/{print $2; exit}' | tr -d '\r')"
kcur="$(printf '%s\n' "$out" | awk -F': *' '/^NEEDRESTART-KCUR:/{print $2; exit}' | tr -d '\r')"
kexp="$(printf '%s\n' "$out" | awk -F': *' '/^NEEDRESTART-KEXP:/{print $2; exit}' | tr -d '\r')"
is_uint "$ksta" || ksta="0"

printf '%s\n' "$out" | awk -F': *' '/^NEEDRESTART-SVC:/{print $2}' | tr -d '\r' | sort -u > "$nrsvcs_tmp" || true
{
  echo "ksta=${ksta}"
  [[ -n "${kcur:-}" ]] && echo "kcur=${kcur}"
  [[ -n "${kexp:-}" ]] && echo "kexp=${kexp}"
  echo "generated=$(date -Is)"
  echo "generated_epoch=$(date +%s)"
} > "$nrmeta_tmp"

chmod 0644 "$nrmeta_tmp" "$nrsvcs_tmp"
mv -f -- "$nrmeta_tmp" "$nr_meta"
mv -f -- "$nrsvcs_tmp" "$nr_svcs"
EOF_REFRESH
}

content_motd_service_unit() {
  cat <<'EOF_MOTD_SERVICE'
[Unit]
Description=Refresh MOTD caches (updates + needrestart)
Wants=network-online.target
After=network-online.target
ConditionPathExists=/usr/local/bin/motd-refresh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/motd-refresh
Nice=10
EOF_MOTD_SERVICE
}

content_motd_timer_unit() {
  cat <<'EOF_MOTD_TIMER'
[Unit]
Description=Periodic refresh of MOTD caches

[Timer]
OnBootSec=5min
OnUnitActiveSec=12h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF_MOTD_TIMER
}

patch_pam_sshd() {
  local tmp
  tmp="$(mktemp "${PAM_SSHD}.tmp.XXXXXX")"

  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    BEGIN { skip=0 }
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    skip == 1 { next }
    ($0 ~ /pam_exec\.so/ && $0 ~ /\/usr\/local\/bin\/update-motd/) { next }
    ($0 ~ /pam_motd\.so/ && $0 ~ /motd=\/run\/motd\.dynamic/) { next }
    { print }
  ' "$PAM_SSHD" > "$tmp"

  cat >> "$tmp" <<EOF_PAM_BLOCK

${MARK_BEGIN}
# Dynamic MOTD generated by /usr/local/bin/update-motd
session optional pam_exec.so /usr/local/bin/update-motd
session optional pam_motd.so motd=/run/motd.dynamic
${MARK_END}
EOF_PAM_BLOCK

  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$PAM_SSHD"
  log "Updated: $PAM_SSHD"
}

upsert_sshd_global_option() {
  local key="$1"
  local val="$2"
  local tmp=""

  tmp="$(mktemp "${SSHD_CONFIG}.tmp.XXXXXX")"
  awk -v key="$key" -v val="$val" '
    BEGIN { in_match=0; done=0 }
    /^[[:space:]]*Match([[:space:]]|$)/ {
      if (!done) {
        print key " " val
        done=1
      }
      in_match=1
      print
      next
    }
    {
      if (!in_match && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]+") {
        if (!done) {
          print key " " val
          done=1
        }
        next
      }
      print
    }
    END {
      if (!done) {
        print key " " val
      }
    }
  ' "$SSHD_CONFIG" > "$tmp"

  mv -f -- "$tmp" "$SSHD_CONFIG"
  log "Set sshd global option: ${key} ${val}"
}

validate_sshd_config() {
  local sshd_bin=""
  if [[ -x /usr/sbin/sshd ]]; then
    sshd_bin="/usr/sbin/sshd"
  elif have_cmd sshd; then
    sshd_bin="$(command -v sshd)"
  else
    warn "sshd binary not found. Skipping sshd_config syntax validation."
    return 0
  fi

  "$sshd_bin" -t -f "$SSHD_CONFIG" >/dev/null 2>&1
}

restart_ssh_service() {
  local svc
  if ! have_cmd systemctl || [[ ! -d /run/systemd/system ]]; then
    warn "systemd is unavailable. Skip SSH service reload."
    return 0
  fi

  for svc in ssh sshd ssh.service sshd.service; do
    if systemctl reload "$svc" >/dev/null 2>&1 || systemctl restart "$svc" >/dev/null 2>&1; then
      log "SSH service reloaded/restarted via: $svc"
      return 0
    fi
  done

  return 1
}

configure_motd_timer() {
  if ! have_cmd systemctl || [[ ! -d /run/systemd/system ]]; then
    warn "systemd is unavailable. Timer was written but not enabled."
    return 0
  fi

  systemctl daemon-reload
  systemctl enable --now motd-refresh.timer
  log "Enabled timer: motd-refresh.timer"
}

write_managed_files() {
  install -d -m 0755 "$UPDATE_DIR"
  install -d -m 0755 "$CACHE_DIR"

  write_owned_file_from_func "$UPDATE_DIR/10-header" 0755 content_10_header
  write_owned_file_from_func "$UPDATE_DIR/50-sysinfo" 0755 content_50_sysinfo
  write_owned_file_from_func "$UPDATE_DIR/60-updates" 0755 content_60_updates
  write_owned_file_from_func "$UPDATE_DIR/80-reboot-required" 0755 content_80_reboot_required
  write_owned_file_from_func "$GEN_BIN" 0755 content_update_motd
  write_owned_file_from_func "$REFRESH_BIN" 0755 content_motd_refresh

  write_owned_file_from_func "$SRV_UNIT" 0644 content_motd_service_unit
  write_owned_file_from_func "$TMR_UNIT" 0644 content_motd_timer_unit
}

run_refresh_now() {
  if [[ -x "$REFRESH_BIN" ]]; then
    if "$REFRESH_BIN"; then
      log "Refreshed MOTD caches once."
    else
      warn "Initial cache refresh failed. Existing caches (if any) were kept."
    fi
  fi
}

usage() {
  cat <<EOF_USAGE
Usage:
  ${SCRIPT_NAME} [--no-restart] [--version] [--help]

Options:
  --no-restart  Do not reload/restart SSH service at the end.
  --version     Print script version.
  --help        Show this help.
EOF_USAGE
}

main() {
  local no_restart=0
  local sshd_backup=""
  local pam_backup=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-restart)
        no_restart=1
        shift
        ;;
      --version)
        echo "$VERSION"
        exit 0
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  require_root

  [[ -f "$PAM_SSHD" ]] || die "Missing file: $PAM_SSHD"
  [[ -f "$SSHD_CONFIG" ]] || die "Missing file: $SSHD_CONFIG"

  log "Starting MOTD installation (version ${VERSION})"
  try_install_needrestart || true

  write_managed_files
  configure_motd_timer || warn "Could not enable motd-refresh.timer."
  run_refresh_now

  pam_backup="$(backup_file "$PAM_SSHD")"
  sshd_backup="$(backup_file "$SSHD_CONFIG")"

  patch_pam_sshd
  upsert_sshd_global_option "UsePAM" "yes"
  upsert_sshd_global_option "PrintLastLog" "yes"
  upsert_sshd_global_option "PrintMotd" "no"

  if ! validate_sshd_config; then
    warn "sshd config validation failed. Rolling back SSH-related files."
    restore_file "$pam_backup" "$PAM_SSHD"
    restore_file "$sshd_backup" "$SSHD_CONFIG"
    die "Aborted due to invalid sshd configuration."
  fi

  if [[ "$no_restart" -eq 0 ]]; then
    if ! restart_ssh_service; then
      warn "SSH reload/restart failed. Rolling back SSH-related files."
      restore_file "$pam_backup" "$PAM_SSHD"
      restore_file "$sshd_backup" "$SSHD_CONFIG"
      restart_ssh_service || true
      die "Aborted because SSH service could not be reloaded safely."
    fi
  else
    log "Skipped SSH restart because --no-restart is set."
  fi

  cat <<EOF_DONE

Completed.
- Managed scripts: ${UPDATE_DIR}/10-header ${UPDATE_DIR}/50-sysinfo ${UPDATE_DIR}/60-updates ${UPDATE_DIR}/80-reboot-required
- Generator: ${GEN_BIN}
- Refresh script: ${REFRESH_BIN}
- Cache files: ${UPD_META} ${SEC_LIST} ${NR_META} ${NR_SVCS}
- Timer: motd-refresh.timer

Next: open a new SSH session to verify output.
EOF_DONE
}

main "$@"

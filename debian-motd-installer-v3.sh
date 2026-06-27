#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL

VERSION="2026.06.25-refactored"
SCRIPT_NAME="${0##*/}"

TARGET_ROOT="/"
ACTION="install"
SKIP_SSH_RELOAD=0
SKIP_REFRESH=0
INSTALL_NEEDRESTART=0
ENABLE_TIMER=1
ALLOW_SSH_RESTART=0

UPDATE_DIR=""
GEN_BIN=""
REFRESH_BIN=""
PAM_SSHD=""
SSHD_CONFIG=""
CACHE_DIR=""
SRV_UNIT=""
TMR_UNIT=""

MARK_BEGIN="# BEGIN MOTD-UBUNTUISH"
MARK_END="# END MOTD-UBUNTUISH"
FILE_MARKER="Managed by debian-motd-installer-refactored"

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

is_real_root_install() {
  [[ "$TARGET_ROOT" == "/" ]]
}

require_root_for_real_install() {
  if is_real_root_install && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root for real installation. Example: sudo ./${SCRIPT_NAME}"
  fi
}

target_path() {
  local path="$1"
  if [[ "$TARGET_ROOT" == "/" ]]; then
    printf '%s\n' "$path"
  else
    printf '%s%s\n' "${TARGET_ROOT%/}" "$path"
  fi
}

init_paths() {
  UPDATE_DIR="$(target_path /etc/update-motd.d)"
  GEN_BIN="$(target_path /usr/local/bin/update-motd)"
  REFRESH_BIN="$(target_path /usr/local/bin/motd-refresh)"
  PAM_SSHD="$(target_path /etc/pam.d/sshd)"
  SSHD_CONFIG="$(target_path /etc/ssh/sshd_config)"
  CACHE_DIR="$(target_path /var/cache/motd)"
  SRV_UNIT="$(target_path /etc/systemd/system/motd-refresh.service)"
  TMR_UNIT="$(target_path /etc/systemd/system/motd-refresh.timer)"
}

require_cmds() {
  local missing=0 cmd
  for cmd in awk sed grep sort wc head date mktemp install chmod cp mv dirname rm; do
    if ! have_cmd "$cmd"; then
      warn "Missing required command: $cmd"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "Required command check failed."
}

backup_file() {
  local path="$1"
  local backup=""

  if [[ -f "$path" ]]; then
    backup="${path}.bak.$(date +%Y%m%d%H%M%S).$$"
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

apply_file_attrs() {
  local reference="$1"
  local target="$2"
  local fallback_mode="$3"

  if [[ -f "$reference" ]]; then
    chmod --reference="$reference" "$target" 2>/dev/null || chmod "$fallback_mode" "$target"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      chown --reference="$reference" "$target" 2>/dev/null || true
    fi
  else
    chmod "$fallback_mode" "$target"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      chown 0:0 "$target" 2>/dev/null || true
    fi
  fi
}

atomic_write_from_func() {
  local path="$1"
  local mode="$2"
  local content_func="$3"
  local dir base tmp

  dir="$(dirname "$path")"
  base="${path##*/}"
  install -d -m 0755 "$dir"
  tmp="$(mktemp "${dir}/.${base}.tmp.XXXXXX")"

  if ! "$content_func" > "$tmp"; then
    rm -f -- "$tmp"
    die "Failed to render file content: $path"
  fi

  apply_file_attrs "$path" "$tmp" "$mode"
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    die "Failed to install file: $path"
  fi
  log "Wrote: $path"
}

patch_file_with_tmp() {
  local path="$1"
  local mode="$2"
  local render_func="$3"
  local dir base tmp

  dir="$(dirname "$path")"
  base="${path##*/}"
  tmp="$(mktemp "${dir}/.${base}.tmp.XXXXXX")"

  if ! "$render_func" > "$tmp"; then
    rm -f -- "$tmp"
    die "Failed to patch file: $path"
  fi

  apply_file_attrs "$path" "$tmp" "$mode"
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    die "Failed to replace file: $path"
  fi
}

maybe_install_needrestart() {
  if have_cmd needrestart; then
    return 0
  fi

  if [[ "$INSTALL_NEEDRESTART" -eq 0 ]]; then
    warn "needrestart is not installed. Restart hints will be limited. Use --install-needrestart to install it."
    return 0
  fi

  if ! have_cmd apt-get; then
    warn "apt-get is unavailable. Cannot install needrestart."
    return 0
  fi

  log "Installing needrestart because --install-needrestart was requested."
  DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=30 -qq update
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=30 -y --no-install-recommends install needrestart
}

content_10_header() {
  cat <<'EOF_10_HEADER'
#!/usr/bin/env bash
# Managed by debian-motd-installer-refactored
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL

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
# Managed by debian-motd-installer-refactored
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL

have_cmd() { command -v "$1" >/dev/null 2>&1; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

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
if [[ -z "$iface" && -r /proc/net/route ]]; then
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
# Managed by debian-motd-installer-refactored
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL

meta="/var/cache/motd/updates.meta"
nr_meta="/var/cache/motd/needrestart.meta"
nr_svcs="/var/cache/motd/needrestart.services"
max_age=$((3 * 24 * 3600))

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

read_kv() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$file" 2>/dev/null || true
}

mtime_epoch() {
  local file="$1"
  stat -c %Y "$file" 2>/dev/null || echo 0
}

is_fresh() {
  local file="$1"
  local now age epoch
  [[ -f "$file" ]] || return 1
  now="$(date +%s)"
  epoch="$(read_kv "$file" generated_epoch)"
  if ! is_uint "$epoch"; then
    epoch="$(mtime_epoch "$file")"
  fi
  is_uint "$epoch" || return 1
  age=$((now - epoch))
  (( age >= 0 && age <= max_age ))
}

if is_fresh "$meta"; then
  status="$(read_kv "$meta" status)"
  total="$(read_kv "$meta" total)"
  sec="$(read_kv "$meta" security)"
  is_uint "$total" || total="0"
  is_uint "$sec" || sec="0"

  if [[ "$status" == "ok" && "$total" -gt 0 ]]; then
    echo "${total} update(s) can be applied immediately."
    if (( sec > 0 )); then
      echo "${sec} of these updates appear to be security updates."
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
# Managed by debian-motd-installer-refactored
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL

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
# Managed by debian-motd-installer-refactored
set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
umask 022

out="/run/motd.dynamic"
tmp="$(mktemp "${out}.tmp.XXXXXX")"
err="$(mktemp "${out}.err.XXXXXX")"
trap 'rm -f "$tmp" "$err"' EXIT

for f in /etc/update-motd.d/*; do
  [[ -x "$f" && -f "$f" ]] || continue
  if ! "$f" >> "$tmp" 2>"$err"; then
    if [[ "${MOTD_DEBUG:-0}" != "0" ]]; then
      printf 'MOTD fragment failed: %s\n' "$f" >&2
      cat "$err" >&2
    fi
  fi
  : > "$err"
done

chmod 0644 "$tmp"
mv -f -- "$tmp" "$out"
trap - EXIT
rm -f "$err"
EOF_UPDATE_MOTD
}

content_motd_refresh() {
  cat <<'EOF_REFRESH'
#!/usr/bin/env bash
# Managed by debian-motd-installer-refactored
set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
umask 022

cache_dir="/var/cache/motd"
upd_meta="${cache_dir}/updates.meta"
sec_list="${cache_dir}/security-updates.list"
nr_meta="${cache_dir}/needrestart.meta"
nr_svcs="${cache_dir}/needrestart.services"

mkdir -p "$cache_dir"
chmod 0755 "$cache_dir"

if command -v flock >/dev/null 2>&1; then
  mkdir -p /run/lock 2>/dev/null || true
  if exec 9>/run/lock/motd-refresh.lock; then
    flock -n 9 || exit 0
  fi
fi

meta_tmp="$(mktemp "${cache_dir}/updates.meta.tmp.XXXXXX")"
seclist_tmp="$(mktemp "${cache_dir}/security-updates.list.tmp.XXXXXX")"
nrmeta_tmp="$(mktemp "${cache_dir}/needrestart.meta.tmp.XXXXXX")"
nrsvcs_tmp="$(mktemp "${cache_dir}/needrestart.services.tmp.XXXXXX")"

cleanup() {
  rm -f "$meta_tmp" "$seclist_tmp" "$nrmeta_tmp" "$nrsvcs_tmp"
}
trap cleanup EXIT

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

apt_status="apt-unavailable"
total="0"
security="0"
: > "$seclist_tmp"

if command -v apt-get >/dev/null 2>&1; then
  apt_opts=(
    "-o" "Acquire::Retries=3"
    "-o" "DPkg::Lock::Timeout=30"
    "-qq"
  )
  if DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" update; then
    apt_status="ok"
    sim="$(DEBIAN_FRONTEND=noninteractive apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null || true)"
    total="$(printf '%s\n' "$sim" | awk '/^Inst /{c++} END{print c+0}')"
    security="$(printf '%s\n' "$sim" | awk '/^Inst / && tolower($0) ~ /(security|debian-security)/{c++} END{print c+0}')"
    printf '%s\n' "$sim" | awk '/^Inst / && tolower($0) ~ /(security|debian-security)/{print $2}' | sort -u > "$seclist_tmp" || true
  else
    apt_status="apt-update-failed"
  fi
fi

is_uint "$total" || total="0"
is_uint "$security" || security="0"
{
  echo "status=${apt_status}"
  echo "total=${total}"
  echo "security=${security}"
  echo "generated=$(date -Is)"
  echo "generated_epoch=$(date +%s)"
} > "$meta_tmp"

nr_status="missing"
out=""
if command -v needrestart >/dev/null 2>&1; then
  nr_status="ok"
  out="$(needrestart -b -r l 2>/dev/null || true)"
fi

ksta="$(printf '%s\n' "$out" | awk -F': *' '/^NEEDRESTART-KSTA:/{print $2; exit}' | tr -d '\r')"
kcur="$(printf '%s\n' "$out" | awk -F': *' '/^NEEDRESTART-KCUR:/{print $2; exit}' | tr -d '\r')"
kexp="$(printf '%s\n' "$out" | awk -F': *' '/^NEEDRESTART-KEXP:/{print $2; exit}' | tr -d '\r')"
is_uint "$ksta" || ksta="0"

printf '%s\n' "$out" | awk -F': *' '/^NEEDRESTART-SVC:/{print $2}' | tr -d '\r' | sort -u > "$nrsvcs_tmp" || true
{
  echo "status=${nr_status}"
  echo "ksta=${ksta}"
  [[ -n "${kcur:-}" ]] && echo "kcur=${kcur}"
  [[ -n "${kexp:-}" ]] && echo "kexp=${kexp}"
  echo "generated=$(date -Is)"
  echo "generated_epoch=$(date +%s)"
} > "$nrmeta_tmp"

chmod 0644 "$meta_tmp" "$seclist_tmp" "$nrmeta_tmp" "$nrsvcs_tmp"
mv -f -- "$meta_tmp" "$upd_meta"
mv -f -- "$seclist_tmp" "$sec_list"
mv -f -- "$nrmeta_tmp" "$nr_meta"
mv -f -- "$nrsvcs_tmp" "$nr_svcs"
trap - EXIT
EOF_REFRESH
}

content_motd_service_unit() {
  cat <<'EOF_MOTD_SERVICE'
# Managed by debian-motd-installer-refactored
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
# Managed by debian-motd-installer-refactored
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

render_pam_sshd() {
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    BEGIN { skip=0 }
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    skip == 1 { next }
    ($0 ~ /pam_exec\.so/ && $0 ~ /\/usr\/local\/bin\/update-motd/) { next }
    ($0 ~ /pam_motd\.so/ && $0 ~ /motd=\/run\/motd\.dynamic/) { next }
    { print }
  ' "$PAM_SSHD"

  cat <<EOF_PAM_BLOCK

${MARK_BEGIN}
# Dynamic MOTD generated by /usr/local/bin/update-motd
session optional pam_exec.so quiet /usr/local/bin/update-motd
session optional pam_motd.so motd=/run/motd.dynamic noupdate
${MARK_END}
EOF_PAM_BLOCK
}

patch_pam_sshd() {
  patch_file_with_tmp "$PAM_SSHD" 0644 render_pam_sshd
  log "Updated: $PAM_SSHD"
}

render_pam_sshd_without_block() {
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    BEGIN { skip=0 }
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    skip == 1 { next }
    { print }
  ' "$PAM_SSHD"
}

remove_pam_block() {
  [[ -f "$PAM_SSHD" ]] || return 0
  patch_file_with_tmp "$PAM_SSHD" 0644 render_pam_sshd_without_block
  log "Removed managed PAM block: $PAM_SSHD"
}

upsert_sshd_global_option() {
  local key="$1"
  local val="$2"

  render_sshd_config() {
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
    ' "$SSHD_CONFIG"
  }

  patch_file_with_tmp "$SSHD_CONFIG" 0644 render_sshd_config
  log "Set sshd global option: ${key} ${val}"
}

validate_sshd_config() {
  local sshd_bin=""

  if ! is_real_root_install; then
    warn "Skipping sshd_config validation for staged root: $TARGET_ROOT"
    return 0
  fi

  if [[ -x /usr/sbin/sshd ]]; then
    sshd_bin="/usr/sbin/sshd"
  elif have_cmd sshd; then
    sshd_bin="$(command -v sshd)"
  else
    warn "sshd binary not found. Skipping sshd_config syntax validation."
    return 0
  fi

  "$sshd_bin" -t -f "$SSHD_CONFIG"
}

reload_ssh_service() {
  local svc

  if [[ "$SKIP_SSH_RELOAD" -eq 1 ]]; then
    log "Skipped SSH reload because --skip-ssh-reload/--no-restart is set."
    return 0
  fi

  if ! is_real_root_install; then
    log "Skipped SSH reload for staged root: $TARGET_ROOT"
    return 0
  fi

  if ! have_cmd systemctl || [[ ! -d /run/systemd/system ]]; then
    warn "systemd is unavailable. SSH service was not reloaded."
    return 0
  fi

  for svc in ssh.service sshd.service ssh sshd; do
    if systemctl reload "$svc" >/dev/null 2>&1; then
      log "SSH service reloaded via: $svc"
      return 0
    fi
  done

  if [[ "$ALLOW_SSH_RESTART" -eq 1 ]]; then
    for svc in ssh.service sshd.service ssh sshd; do
      if systemctl restart "$svc" >/dev/null 2>&1; then
        log "SSH service restarted via: $svc"
        return 0
      fi
    done
  fi

  warn "Could not reload SSH service automatically. Run: systemctl reload ssh || systemctl reload sshd"
  return 0
}

write_managed_files() {
  install -d -m 0755 "$UPDATE_DIR" "$CACHE_DIR"

  atomic_write_from_func "$UPDATE_DIR/10-header" 0755 content_10_header
  atomic_write_from_func "$UPDATE_DIR/50-sysinfo" 0755 content_50_sysinfo
  atomic_write_from_func "$UPDATE_DIR/60-updates" 0755 content_60_updates
  atomic_write_from_func "$UPDATE_DIR/80-reboot-required" 0755 content_80_reboot_required
  atomic_write_from_func "$GEN_BIN" 0755 content_update_motd
  atomic_write_from_func "$REFRESH_BIN" 0755 content_motd_refresh

  if [[ "$ENABLE_TIMER" -eq 1 ]]; then
    atomic_write_from_func "$SRV_UNIT" 0644 content_motd_service_unit
    atomic_write_from_func "$TMR_UNIT" 0644 content_motd_timer_unit
  fi
}

configure_motd_timer() {
  if [[ "$ENABLE_TIMER" -eq 0 ]]; then
    log "Skipped timer setup because --no-timer is set."
    return 0
  fi

  if ! is_real_root_install; then
    log "Skipped timer enable for staged root: $TARGET_ROOT"
    return 0
  fi

  if ! have_cmd systemctl || [[ ! -d /run/systemd/system ]]; then
    warn "systemd is unavailable. Timer files were written but not enabled."
    return 0
  fi

  systemctl daemon-reload
  systemctl enable --now motd-refresh.timer
  log "Enabled timer: motd-refresh.timer"
}

run_refresh_now() {
  if [[ "$SKIP_REFRESH" -eq 1 ]]; then
    log "Skipped initial cache refresh because --skip-refresh is set."
    return 0
  fi

  if ! is_real_root_install; then
    log "Skipped initial cache refresh for staged root: $TARGET_ROOT"
    return 0
  fi

  if [[ -x "$REFRESH_BIN" ]]; then
    "$REFRESH_BIN" || warn "Initial cache refresh failed. Run ${REFRESH_BIN} manually for details."
  fi
}

remove_managed_file() {
  local path="$1"
  [[ -e "$path" ]] || return 0

  if [[ -f "$path" ]] && grep -Fq "$FILE_MARKER" "$path"; then
    rm -f -- "$path"
    log "Removed: $path"
  else
    warn "Skipped non-managed file: $path"
  fi
}

uninstall_managed_files() {
  if is_real_root_install && have_cmd systemctl && [[ -d /run/systemd/system ]]; then
    systemctl disable --now motd-refresh.timer >/dev/null 2>&1 || true
  fi

  remove_managed_file "$UPDATE_DIR/10-header"
  remove_managed_file "$UPDATE_DIR/50-sysinfo"
  remove_managed_file "$UPDATE_DIR/60-updates"
  remove_managed_file "$UPDATE_DIR/80-reboot-required"
  remove_managed_file "$GEN_BIN"
  remove_managed_file "$REFRESH_BIN"
  remove_managed_file "$SRV_UNIT"
  remove_managed_file "$TMR_UNIT"

  if is_real_root_install && have_cmd systemctl && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload || true
  fi
}

install_main() {
  local pam_backup=""
  local sshd_backup=""

  [[ -f "$PAM_SSHD" ]] || die "Missing file: $PAM_SSHD"
  [[ -f "$SSHD_CONFIG" ]] || die "Missing file: $SSHD_CONFIG"

  maybe_install_needrestart

  pam_backup="$(backup_file "$PAM_SSHD")"
  sshd_backup="$(backup_file "$SSHD_CONFIG")"

  write_managed_files
  patch_pam_sshd
  upsert_sshd_global_option "UsePAM" "yes"
  upsert_sshd_global_option "PrintLastLog" "yes"
  upsert_sshd_global_option "PrintMotd" "no"

  if ! validate_sshd_config; then
    warn "sshd_config validation failed. Rolling back PAM and SSH config."
    restore_file "$pam_backup" "$PAM_SSHD"
    restore_file "$sshd_backup" "$SSHD_CONFIG"
    die "Aborted due to invalid sshd configuration."
  fi

  configure_motd_timer
  run_refresh_now
  reload_ssh_service

  cat <<EOF_DONE

Completed.
- Managed scripts: ${UPDATE_DIR}/10-header ${UPDATE_DIR}/50-sysinfo ${UPDATE_DIR}/60-updates ${UPDATE_DIR}/80-reboot-required
- Generator: ${GEN_BIN}
- Refresh script: ${REFRESH_BIN}
- Cache directory: ${CACHE_DIR}
- Timer: motd-refresh.timer

Next: open a new SSH session to verify output.
EOF_DONE
}

uninstall_main() {
  local pam_backup=""

  [[ -f "$PAM_SSHD" ]] && pam_backup="$(backup_file "$PAM_SSHD")"
  remove_pam_block
  uninstall_managed_files
  reload_ssh_service

  cat <<EOF_DONE

Uninstall completed.
- Removed managed PAM block from: ${PAM_SSHD}
- Removed files that carried marker: ${FILE_MARKER}
- Left sshd_config global options unchanged intentionally.
EOF_DONE

  [[ -n "$pam_backup" ]] && log "PAM backup kept at: $pam_backup"
}

usage() {
  cat <<EOF_USAGE
Usage:
  ${SCRIPT_NAME} [options]
  ${SCRIPT_NAME} --uninstall [options]

Options:
  --install-needrestart  Install needrestart if missing.
  --skip-refresh         Do not run /usr/local/bin/motd-refresh after install.
  --skip-ssh-reload      Do not reload SSH service after changes.
  --no-restart           Alias for --skip-ssh-reload.
  --allow-ssh-restart    If SSH reload fails, allow systemctl restart fallback.
  --no-timer             Do not write or enable systemd timer units.
  --root DIR             Stage files under DIR instead of installing to /.
  --uninstall            Remove managed PAM block and managed files.
  --version              Print script version.
  --help, -h             Show this help.
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-needrestart)
        INSTALL_NEEDRESTART=1
        shift
        ;;
      --skip-refresh)
        SKIP_REFRESH=1
        shift
        ;;
      --skip-ssh-reload|--no-restart)
        SKIP_SSH_RELOAD=1
        shift
        ;;
      --allow-ssh-restart)
        ALLOW_SSH_RESTART=1
        shift
        ;;
      --no-timer)
        ENABLE_TIMER=0
        shift
        ;;
      --root)
        [[ $# -ge 2 ]] || die "--root requires a directory argument."
        TARGET_ROOT="$2"
        [[ -n "$TARGET_ROOT" ]] || die "--root cannot be empty."
        shift 2
        ;;
      --uninstall)
        ACTION="uninstall"
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

  if [[ "$TARGET_ROOT" != "/" ]]; then
    TARGET_ROOT="${TARGET_ROOT%/}"
    [[ -n "$TARGET_ROOT" ]] || TARGET_ROOT="/"
  fi
}

main() {
  parse_args "$@"
  init_paths
  require_cmds
  require_root_for_real_install

  log "Starting MOTD ${ACTION} (version ${VERSION})"

  case "$ACTION" in
    install)
      install_main
      ;;
    uninstall)
      uninstall_main
      ;;
    *)
      die "Unknown action: $ACTION"
      ;;
  esac
}

main "$@"

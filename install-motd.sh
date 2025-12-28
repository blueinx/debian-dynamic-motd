#!/usr/bin/env bash
set -euo pipefail

# ========= 配置 =========
UPDATE_DIR="/etc/update-motd.d"
GEN_BIN="/usr/local/bin/update-motd"

PAM_SSHD="/etc/pam.d/sshd"
SSHD_CONFIG="/etc/ssh/sshd_config"

CACHE_DIR="/var/cache/motd"
REFRESH_BIN="/usr/local/bin/motd-refresh"

UPD_META="${CACHE_DIR}/updates.meta"
SEC_LIST="${CACHE_DIR}/security-updates.list"

NR_META="${CACHE_DIR}/needrestart.meta"
NR_SVCS="${CACHE_DIR}/needrestart.services"

SRV_UNIT="/etc/systemd/system/motd-refresh.service"
TMR_UNIT="/etc/systemd/system/motd-refresh.timer"

MARK_BEGIN="# BEGIN MOTD-UBUNTUISH"
MARK_END="# END MOTD-UBUNTUISH"

BACKUP_SUFFIX=".bak.$(date +%Y%m%d%H%M%S)"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请用 root 执行：sudo bash $0"
    exit 1
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}${BACKUP_SUFFIX}"
    echo "已备份：${f}${BACKUP_SUFFIX}"
  fi
}

write_owned_file() {
  # “我们自主管理”的文件：存在则备份，再覆盖
  local path="$1"
  local mode="$2"
  local content="$3"
  if [[ -e "$path" ]]; then backup_file "$path"; fi
  install -d "$(dirname "$path")"
  printf "%s" "$content" > "$path"
  chmod "$mode" "$path"
  echo "已写入：$path"
}

upsert_sshd_kv() {
  local key="$1"
  local val="$2"
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$SSHD_CONFIG"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|g" "$SSHD_CONFIG"
  else
    printf "\n%s %s\n" "$key" "$val" >> "$SSHD_CONFIG"
  fi
  echo "已设置 sshd_config：${key} ${val}"
}

patch_pam_sshd() {
  backup_file "$PAM_SSHD"
  local tmp
  tmp="$(mktemp)"

  # 策略：
  # 1) 删除旧标记块
  # 2) 删除可能造成重复显示的 pam_motd/pam_lastlog/我们的 pam_exec(update-motd)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    BEGIN { skip=0 }
    $0 ~ "^"b { skip=1; next }
    $0 ~ "^"e { skip=0; next }
    skip==1 { next }

    $0 ~ /pam_motd\.so/ { next }
    $0 ~ /pam_lastlog\.so/ { next }
    ($0 ~ /pam_exec\.so/ && $0 ~ /\/usr\/local\/bin\/update-motd/) { next }

    { print }
  ' "$PAM_SSHD" > "$tmp"

  cat >> "$tmp" <<EOF2

${MARK_BEGIN}
# 上次登录时间/来源 IP（Last login ... from ...）
session required pam_lastlog.so

# 生成动态 MOTD 到 /run/motd.dynamic
session optional pam_exec.so /usr/local/bin/update-motd

# 显示动态 MOTD
session optional pam_motd.so motd=/run/motd.dynamic
${MARK_END}
EOF2

  mv "$tmp" "$PAM_SSHD"
  chmod 644 "$PAM_SSHD"
  echo "已更新：$PAM_SSHD"
}

restart_ssh() {
  if systemctl list-unit-files 2>/dev/null | grep -qE '^ssh\.service'; then
    systemctl restart ssh
  elif systemctl list-unit-files 2>/dev/null | grep -qE '^sshd\.service'; then
    systemctl restart sshd
  else
    systemctl restart ssh || systemctl restart sshd || true
  fi
  echo "已重启 SSH 服务"
}

ensure_pkg() {
  local cmd="$1"
  local pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "==> 安装依赖：$pkg"
    apt-get update -y
    apt-get install -y "$pkg"
  fi
}

need_root

# 需要 needrestart（用于“服务/系统需重启建议”）
ensure_pkg needrestart needrestart

echo "==> 1) 创建动态 MOTD 目录"
install -d -m 755 "$UPDATE_DIR"

echo "==> 2) 写入 10-header"
write_owned_file "$UPDATE_DIR/10-header" 755 \
'#!/bin/bash
set -e

OS_PRETTY="$(. /etc/os-release; echo "$PRETTY_NAME")"
KERNEL="$(uname -srmo 2>/dev/null || uname -sr)"
ARCH="$(uname -m)"
DATE_STR="$(date)"

DOC_URL="https://www.debian.org/doc/"
SUPPORT_URL="https://www.debian.org/support"

echo
echo "Welcome to ${OS_PRETTY} (GNU/Linux ${KERNEL} ${ARCH})"
echo
echo " * Documentation:  ${DOC_URL}"
echo " * Support:        ${SUPPORT_URL}"
echo
echo " System information as of ${DATE_STR}"
echo
'

echo "==> 3) 写入 50-sysinfo（IPv4 + IPv6）"
write_owned_file "$UPDATE_DIR/50-sysinfo" 755 \
'#!/bin/bash
set -e

LOAD="$(cut -d " " -f1 /proc/loadavg)"
PROCS="$(ps -e --no-headers | wc -l)"
USERS="$(who | wc -l)"

DISK_LINE="$(df -h / | awk '\''NR==2{printf "%s of %s", $5, $2}'\'')"
MEM_PCT="$(free | awk '\''/Mem:/ {printf "%d", ($3/$2)*100}'\'')"
SWAP_PCT="$(free | awk '\''/Swap:/ { if ($2==0) {print "0"} else {printf "%d", ($3/$2)*100} }'\'')"

IFACE="$(ip route 2>/dev/null | awk '\''/default/ {print $5; exit}'\'')"
[ -z "$IFACE" ] && IFACE="eth0"

IPV4="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '\''/inet /{print $2}'\'' | cut -d/ -f1 | head -n1)"
[ -z "$IPV4" ] && IPV4="N/A"

IPV6="$(ip -6 addr show "$IFACE" scope global 2>/dev/null | awk '\''/inet6 /{print $2}'\'' | cut -d/ -f1 | head -n1)"
[ -z "$IPV6" ] && IPV6="N/A"

echo
printf "  System load:  %-16s Processes:             %s\n" "$LOAD" "$PROCS"
printf "  Usage of /:   %-16s Users logged in:       %s\n" "$DISK_LINE" "$USERS"
printf "  Memory usage: %-16s IPv4 address for %s: %s\n" "${MEM_PCT}%" "$IFACE" "$IPV4"
printf "  Swap usage:   %-16s IPv6 address for %s: %s\n" "${SWAP_PCT}%" "$IFACE" "$IPV6"
echo
'

echo "==> 4) 写入 60-updates（方案 X：总更新 + 安全更新；needrestart 摘要）"
write_owned_file "$UPDATE_DIR/60-updates" 755 \
'#!/bin/bash
set -e

META="/var/cache/motd/updates.meta"
NR_META="/var/cache/motd/needrestart.meta"
NR_SVCS="/var/cache/motd/needrestart.services"

# 仅展示最近 3 天内刷新过的缓存（避免离线太久误导）
if [ -f "$META" ] && find "$META" -mtime -3 >/dev/null 2>&1; then
  total="$(awk -F= "/^total=/{print \$2}" "$META" 2>/dev/null || true)"
  sec="$(awk -F= "/^security=/{print \$2}" "$META" 2>/dev/null || true)"

  total="${total:-0}"
  sec="${sec:-0}"

  if [ "$total" -gt 0 ]; then
    echo "${total} update(s) can be applied immediately."
    if [ "$sec" -gt 0 ]; then
      echo "${sec} of these updates are security updates."
    fi
    echo "To see these additional updates run: apt list --upgradable"
    echo
  fi
fi

# needrestart 摘要（只在需要时显示）
if [ -f "$NR_META" ] && find "$NR_META" -mtime -3 >/dev/null 2>&1; then
  ksta="$(awk -F= "/^ksta=/{print \$2}" "$NR_META" 2>/dev/null || true)"
  ksta="${ksta:-0}"

  # ksta: 1=无; 2=ABI兼容升级待应用(建议重启); 3=版本升级待应用(需要重启)
  if [ "$ksta" -eq 3 ]; then
    echo "*** System restart required ***"
    echo
  elif [ "$ksta" -eq 2 ]; then
    echo "System restart recommended."
    echo
  fi

  if [ -s "$NR_SVCS" ]; then
    n="$(wc -l < "$NR_SVCS" | tr -d " ")"
    echo "Service restart required: ${n} service(s) should be restarted."
    echo "Services:"
    sed "s/^/  - /" "$NR_SVCS" | head -n 12
    [ "$n" -gt 12 ] && echo "  - (and more...)"
    echo
  fi
fi
'

echo "==> 5) 写入 80-reboot-required（兼容 /run/reboot-required；避免与 needrestart 重复刷屏）"
write_owned_file "$UPDATE_DIR/80-reboot-required" 755 \
'#!/bin/bash
set -e

NR_META="/var/cache/motd/needrestart.meta"
ksta="0"
if [ -f "$NR_META" ]; then
  ksta="$(awk -F= "/^ksta=/{print \$2}" "$NR_META" 2>/dev/null || echo 0)"
fi

# 如果 needrestart 已经判定“必须重启”(ksta=3)，这里就不再重复输出
[ "$ksta" = "3" ] && exit 0

REQ=""
PKGS=""

if [ -f /run/reboot-required ]; then
  REQ="/run/reboot-required"
  [ -f /run/reboot-required.pkgs ] && PKGS="/run/reboot-required.pkgs"
elif [ -f /var/run/reboot-required ]; then
  REQ="/var/run/reboot-required"
  [ -f /var/run/reboot-required.pkgs ] && PKGS="/var/run/reboot-required.pkgs"
fi

if [ -n "$REQ" ]; then
  echo "*** System restart required ***"
  if [ -n "$PKGS" ]; then
    echo "Packages requiring reboot:"
    sed "s/^/  - /" "$PKGS" | head -n 20
  fi
  echo
fi
'

echo "==> 6) 写入 MOTD 生成器 /usr/local/bin/update-motd"
write_owned_file "$GEN_BIN" 755 \
'#!/bin/bash
set -e
OUT="/run/motd.dynamic"
tmp="$(mktemp)"
for f in /etc/update-motd.d/*; do
  [ -x "$f" ] && "$f" >> "$tmp"
done
mv "$tmp" "$OUT"
chmod 644 "$OUT"
'

echo "==> 7) 写入缓存刷新脚本 /usr/local/bin/motd-refresh（更新摘要 + needrestart）"
install -d -m 755 "$CACHE_DIR"

write_owned_file "$REFRESH_BIN" 755 \
'#!/bin/bash
set -euo pipefail

CACHE_DIR="/var/cache/motd"
META_TMP="$(mktemp)"
SECLIST_TMP="$(mktemp)"
NRMETA_TMP="$(mktemp)"
NRSVCS_TMP="$(mktemp)"

UPD_META="${CACHE_DIR}/updates.meta"
SEC_LIST="${CACHE_DIR}/security-updates.list"
NR_META="${CACHE_DIR}/needrestart.meta"
NR_SVCS="${CACHE_DIR}/needrestart.services"

mkdir -p "$CACHE_DIR"

APT_OPTS=(
  "-o" "Acquire::Retries=3"
  "-o" "DPkg::Lock::Timeout=30"
  "-qq"
)

# ---- 更新摘要（总更新 + 安全更新）----
# 如果 apt-get update 失败，则保留旧缓存，不覆盖
if apt-get update "${APT_OPTS[@]}"; then
  SIM="$(apt-get -s upgrade 2>/dev/null || true)"

  total="$(printf "%s\n" "$SIM" | awk '\''/^Inst /{c++} END{print c+0}'\'')"
  security="$(printf "%s\n" "$SIM" | awk '\''/^Inst / && $0 ~ /(Debian-Security|bookworm-security|security\.debian\.org)/{c++} END{print c+0}'\'')"

  printf "%s\n" "$SIM" \
    | awk '\''/^Inst / && $0 ~ /(Debian-Security|bookworm-security|security\.debian\.org)/{print $2}'\'' \
    | sort -u > "$SECLIST_TMP" || true

  {
    echo "total=${total}"
    echo "security=${security}"
    echo "generated=$(date -Is)"
  } > "$META_TMP"

  chmod 644 "$META_TMP" "$SECLIST_TMP"
  mv "$META_TMP" "$UPD_META"
  mv "$SECLIST_TMP" "$SEC_LIST"
else
  rm -f "$META_TMP" "$SECLIST_TMP" || true
fi

# ---- needrestart 摘要（批处理 list-only）----
# 输出为 NEEDRESTART-* 机器可读行（batch mode）+ list only
OUT="$(needrestart -b -r l 2>/dev/null || true)"

ksta="$(printf "%s\n" "$OUT" | awk -F': *' '\''/^NEEDRESTART-KSTA:/{print $2; exit}'\'' | tr -d "\r")"
kcur="$(printf "%s\n" "$OUT" | awk -F': *' '\''/^NEEDRESTART-KCUR:/{print $2; exit}'\'' | tr -d "\r")"
kexp="$(printf "%s\n" "$OUT" | awk -F': *' '\''/^NEEDRESTART-KEXP:/{print $2; exit}'\'' | tr -d "\r")"

: > "$NRSVCS_TMP"
printf "%s\n" "$OUT" | awk -F': *' '\''/^NEEDRESTART-SVC:/{print $2}'\'' | tr -d "\r" | sort -u > "$NRSVCS_TMP" || true

{
  echo "ksta=${ksta:-0}"
  [ -n "${kcur:-}" ] && echo "kcur=${kcur}"
  [ -n "${kexp:-}" ] && echo "kexp=${kexp}"
  echo "generated=$(date -Is)"
} > "$NRMETA_TMP"

chmod 644 "$NRMETA_TMP" "$NRSVCS_TMP"
mv "$NRMETA_TMP" "$NR_META"
mv "$NRSVCS_TMP" "$NR_SVCS"
'

echo "==> 8) 创建 systemd service + timer（后台定时刷新缓存）"
write_owned_file "$SRV_UNIT" 644 \
"[Unit]
Description=Refresh MOTD caches (updates + needrestart)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${REFRESH_BIN}
"

write_owned_file "$TMR_UNIT" 644 \
"[Unit]
Description=Periodic refresh of MOTD caches

[Timer]
OnBootSec=5min
OnUnitActiveSec=12h
Persistent=true

[Install]
WantedBy=timers.target
"

systemctl daemon-reload
systemctl enable --now motd-refresh.timer
# 先手动刷新一次，保证立即有内容
"$REFRESH_BIN" || true

echo "==> 9) 更新 PAM（Last login + MOTD，幂等写入）"
patch_pam_sshd

echo "==> 10) 更新 sshd_config（UsePAM/PrintLastLog/PrintMotd）"
backup_file "$SSHD_CONFIG"
upsert_sshd_kv "UsePAM" "yes"
upsert_sshd_kv "PrintLastLog" "yes"
upsert_sshd_kv "PrintMotd" "no"

echo "==> 11) 重启 SSH"
restart_ssh

echo
echo "✅ 完成！请【新开一个 SSH 会话】测试输出是否符合预期。"
echo
echo "你会看到类似 Ubuntu 的更新摘要："
echo "  N update(s) can be applied immediately."
echo "  S of these updates are security updates."
echo "以及 needrestart 的提示（仅在需要时出现）："
echo "  *** System restart required ***"
echo "  Service restart required: ... Services: ..."
echo
echo "查看定时器：systemctl status motd-refresh.timer"

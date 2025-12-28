# Debian Dynamic MOTD / Debian 动态登录提示

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/language-Bash-green.svg)](https://www.gnu.org/software/bash/)

**English** | [中文说明](#中文说明)

## Table of Contents

- [Introduction](#introduction)
- [Features](#features)
- [Preview](#preview)
- [Download](#download)
- [Language / 语言](#language--语言)
- [Installation](#installation)
- [Usage & Commands](#usage--commands)
- [中文说明](#中文说明)

## Introduction

This project provides scripts to install a beautiful, Ubuntu-style dynamic **Message of the Day (MOTD)** on Debian servers (Debian 10/11/12).

By default, Debian does not show detailed system information or update notifications upon login. These scripts set up a dynamic MOTD that displays:

- **System Information:** OS version, Kernel, Architecture.
- **Resource Usage:** CPU load, Memory usage, Swap usage, Disk usage.
- **Network:** IPv4 and IPv6 addresses.
- **Updates:** Pending APT updates (distinguishing security updates).
- **Reboot Status:** Checks if a system or service restart is required (integrates with `needrestart`).

It includes a background `systemd` timer to refresh update caches periodically without slowing down your login process.

## Features

- 📊 **Rich Info:** CPU, RAM, Disk, and Network stats at a glance.
- 🛡️ **Security First:** Clearly shows security updates vs. regular updates.
- ⚡ **Fast Login:** Uses caching to prevent login delays caused by `apt check`.
- 🔄 **Smart Refresh:** Background timer refreshes data every 12 hours (and 5 min after boot).
- 🛠️ **Auto Config:** Automatically patches `sshd_config` and `pam.d/sshd` for correct display.

---


## Preview

Below is an example of what you'll see after SSH login (content varies by system):

以下为 SSH 登录后示例（内容会因系统环境不同而变化）：

```text
Welcome to Debian GNU/Linux 12 (bookworm) (GNU/Linux 6.1.0-xx-amd64 x86_64)

 * Documentation:  https://www.debian.org/doc/
 * Support:        https://www.debian.org/support

 System information as of Sun Dec 28 12:34:56 UTC 2025

  System load:  0.10             Processes:             123
  Usage of /:   40% of 20G       Users logged in:       1
  Memory usage: 35%              IPv4 address for eth0: 203.0.113.10
  Swap usage:   0%               IPv6 address for eth0: 2001:db8::10

3 update(s) can be applied immediately.
1 of these updates are security updates.
To see these additional updates run: apt list --upgradable

*** System restart required ***

Service restart required: 2 service(s) should be restarted.
Services:
  - ssh
  - cron
```

> Note: The **bilingual installer** only changes the **installer prompts**. The installed MOTD output is **English by default** (same style as Ubuntu).

---

## Download

This repo provides **two installer scripts**:

- **Bilingual (Recommended):** `install-motd-bilingual.sh` (interactive language choice during installation)
- **Original (Chinese logs):** `install-motd.sh`

Raw download links (replace `blueinx` if you fork):

- Bilingual script (raw): https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/install-motd-bilingual.sh
- Original script (raw):  https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/install-motd.sh
- Repo ZIP (main): https://github.com/blueinx/debian-dynamic-motd/archive/refs/heads/main.zip
- Repo TAR.GZ (main): https://github.com/blueinx/debian-dynamic-motd/archive/refs/heads/main.tar.gz

---


## Language / 语言

This repo provides a **bilingual installer**: `install-motd-bilingual.sh`.

- During installation, it will **prompt you to choose English / 中文** (only in interactive terminals).
- After installation, the MOTD output remains **English by default** (same as Ubuntu style).

### 中文说明

仓库提供**双语安装脚本**：`install-motd-bilingual.sh`。

- 安装过程中（交互终端）会提示你选择 **English / 中文**（只影响安装过程提示信息）。
- 安装完成后，登录 MOTD 仍然保持**默认英文输出**（和 Ubuntu 风格一致）。

---

## Installation

### Option 1: Quick Install (Bilingual Recommended)

Run the following command as **root** (or add `sudo` if needed):

```bash
bash <(curl -sL https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/install-motd-bilingual.sh)
```

### Option 2: Quick Install (Original Script)

```bash
bash <(curl -sL https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/install-motd.sh)
```

### Option 3: Manual Installation

1. **Download the script** (choose one):

```bash
wget https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/install-motd-bilingual.sh
# or
wget https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/install-motd.sh
```

2. **Add execution permission:**

```bash
chmod +x install-motd-bilingual.sh
# or
chmod +x install-motd.sh
```

3. **Run the script:**

```bash
sudo ./install-motd-bilingual.sh
# or
sudo ./install-motd.sh
```

---

## Usage & Commands

After installation, reconnect your SSH session to see the new MOTD.

**Manually refresh cache (e.g., after `apt upgrade`):**

```bash
sudo /usr/local/bin/motd-refresh
```

**Check the background timer status:**

```bash
systemctl status motd-refresh.timer
```

---

## 中文说明

本项目提供了脚本，用于在 Debian 服务器（Debian 10/11/12）上安装美观的、Ubuntu 风格的**动态登录提示（MOTD）**。

默认 Debian 登录时通常只显示简单信息。本脚本将配置一套动态 MOTD，显示：

- **系统信息：** 系统版本、内核、架构。
- **资源概览：** CPU 负载、内存使用率、Swap 使用率、磁盘使用率。
- **网络信息：** IPv4 和 IPv6 地址。
- **更新提醒：** 待安装的 APT 更新数量（并高亮显示安全更新）。
- **重启提示：** 智能检测系统内核或服务是否需要重启（集成 `needrestart`）。

脚本包含后台 `systemd` 定时任务，定期刷新更新缓存，确保 SSH 登录更快，不会因为检查更新而卡顿。

## 安装说明

仓库内提供两个安装脚本：

- **双语脚本（推荐）：** `install-motd-bilingual.sh`（安装时可交互选择语言）
- **原始脚本：** `install-motd.sh`（安装日志主要为中文，MOTD 输出为英文）

### 方法 1：一键安装（双语推荐）

```bash
bash <(curl -sL https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/install-motd-bilingual.sh)
```


### 方法 2：一键安装（原始脚本）

```bash
bash <(curl -sL https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/install-motd.sh)
```

### 方法 3：手动下载安装

```bash
wget https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/install-motd-bilingual.sh
# or
wget https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/install-motd.sh
```

```bash
chmod +x install-motd-bilingual.sh
sudo ./install-motd-bilingual.sh
```

## 常用命令

安装完成后，请**重新连接 SSH** 查看效果。

```bash
sudo /usr/local/bin/motd-refresh
systemctl status motd-refresh.timer
```

---

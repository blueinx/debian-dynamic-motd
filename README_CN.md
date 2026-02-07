# Debian MOTD 安装脚本

推荐脚本名：`debian-motd-installer.sh`

本项目用于在 Debian 上安装动态 MOTD（类似 Ubuntu 登录欢迎信息），并增强 SSH 配置变更时的安全性（先校验、失败回滚）。

## 功能说明
- 在 `/etc/update-motd.d/` 生成动态 MOTD 脚本。
- 安装：
  - `/usr/local/bin/update-motd`
  - `/usr/local/bin/motd-refresh`
- 创建并启用：
  - `motd-refresh.service`
  - `motd-refresh.timer`
- 更新 SSH 相关配置：
  - `/etc/pam.d/sshd`（写入受控 MOTD 块）
  - `/etc/ssh/sshd_config`（`UsePAM yes`、`PrintLastLog yes`、`PrintMotd no`）
- 重启 SSH 前做 `sshd -t` 校验，失败自动回滚。

## 运行要求
- Debian 或 Debian 系系统，且可用 `bash`
- `root` 权限（`sudo`）
- 若存在 `systemd`，会自动启用定时刷新；无 `systemd` 时仍会写入脚本文件

## 本地使用方式
```bash
chmod +x debian-motd-installer.sh
sudo ./debian-motd-installer.sh
```

可选参数：
```bash
sudo ./debian-motd-installer.sh --no-restart
sudo ./debian-motd-installer.sh --version
sudo ./debian-motd-installer.sh --help
```

## GitHub Raw 使用方式

仓库地址：
- `https://github.com/blueinx/debian-dynamic-motd`
- 默认分支：`main`

### 方式 1：先下载再执行（推荐）
```bash
curl -fsSL https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/debian-motd-installer.sh -o debian-motd-installer.sh
chmod +x debian-motd-installer.sh
sudo ./debian-motd-installer.sh
```

`wget` 写法：
```bash
wget -O debian-motd-installer.sh https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/debian-motd-installer.sh
chmod +x debian-motd-installer.sh
sudo ./debian-motd-installer.sh
```

### 方式 2：一行命令管道执行（快捷但可审计性较低）
```bash
curl -fsSL https://raw.githubusercontent.com/blueinx/debian-dynamic-motd/main/debian-motd-installer.sh | sudo bash -s --
```

建议生产环境优先使用“先下载再审阅再执行”。

## 安装后验证
```bash
sudo /usr/local/bin/motd-refresh
sudo /usr/local/bin/update-motd
systemctl status motd-refresh.timer
sshd -t -f /etc/ssh/sshd_config
```

然后新开一个 SSH 会话，查看 MOTD 输出是否符合预期。

## 回滚方法
脚本会自动创建带时间戳备份：
- `/etc/pam.d/sshd.bak.<timestamp>`
- `/etc/ssh/sshd_config.bak.<timestamp>`

示例：
```bash
sudo cp -a /etc/pam.d/sshd.bak.<timestamp> /etc/pam.d/sshd
sudo cp -a /etc/ssh/sshd_config.bak.<timestamp> /etc/ssh/sshd_config
sudo sshd -t -f /etc/ssh/sshd_config
sudo systemctl restart ssh || sudo systemctl restart sshd
```

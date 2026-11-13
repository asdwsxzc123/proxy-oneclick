# proxy-oneclick

在 Linux 服务器上一条命令装好 **HTTP + SOCKS5 代理**：基于 [GOST](https://github.com/go-gost/gost) v3.3.3，带账号密码，可加 IP 白名单，用 systemd 开机自启。

- gost 从 GitHub 下载；国内服务器连不上时自动换加速镜像，或者用 `--file` 指定本地压缩包
- 不管从哪下载，文件都要和脚本里写死的官方 sha256 对上才会安装
- 装好后自带 `gost-proxy` 命令：查看、换密码、改端口、卸载都不用再连 GitHub

## 安装

用 root 在服务器上执行（普通用户把 `| bash -s --` 换成 `| sudo bash -s --`）：

```bash
# 服务器能连 GitHub
curl -fsSL https://raw.githubusercontent.com/asdwsxzc123/proxy-oneclick/main/install.sh | bash -s --

# 连不上 GitHub（国内服务器常见）：走 jsDelivr
curl -fsSL https://cdn.jsdelivr.net/gh/asdwsxzc123/proxy-oneclick@v1.0.0/install.sh | bash -s --
```

默认开 HTTP `8080` 和 SOCKS5 `1080`，用户名 `proxy`，密码随机生成。装完会自测一次，并打印类似下面的信息：

```
==> 代理信息（gost v3.3.3）
  HTTP   : http://proxy:k3Jd9...@1.2.3.4:8080
  SOCKS5 : socks5://proxy:k3Jd9...@1.2.3.4:1080
```

**最后记得在云厂商的安全组里放行这两个 TCP 端口**（脚本只会处理本机的 ufw / firewalld）。

## 常用写法

选项写在 `bash -s --` 后面：

```bash
# 自己指定账号密码
... | bash -s -- --user alice --pass Abc12345

# 只开 SOCKS5
... | bash -s -- --http-port 0

# 给不支持账号密码的程序用：不要认证，只允许指定 IP 连接
... | bash -s -- --no-auth --allow 1.2.3.4,5.6.7.0/24

# 下载都失败时：在能上 GitHub 的电脑下载
# https://github.com/go-gost/gost/releases/download/v3.3.3/gost_3.3.3_linux_amd64.tar.gz
# 传到服务器后
bash install.sh --file /tmp/gost_3.3.3_linux_amd64.tar.gz
```

## 装好之后

```bash
gost-proxy --show                 # 再看一次地址和密码
gost-proxy --new-pass             # 换一个随机密码
gost-proxy --pass NewPass123      # 换成指定密码
gost-proxy --socks-port 2080      # 改端口
gost-proxy --allow 1.2.3.4        # 加 IP 白名单（--allow none 取消）
gost-proxy --uninstall            # 卸载
systemctl status gost             # 服务状态
journalctl -u gost -n 50          # 日志
```

每次运行都沿用上次的设置，只改这次给的选项。

## 全部选项

| 选项 | 说明 |
|---|---|
| `--user NAME` | 用户名，缺省 `proxy`（字母、数字、`. _ -`） |
| `--pass PASS` | 密码，缺省随机 16 位（字母、数字、`. _ ~ -`，6–64 位，放进代理地址不用转义） |
| `--new-pass` | 重新生成随机密码 |
| `--http-port N` | HTTP 端口，缺省 8080，`0` = 不开 |
| `--socks-port N` | SOCKS5 端口，缺省 1080，`0` = 不开 |
| `--no-auth` / `--auth` | 关掉 / 重新开启账号密码。`--no-auth` 必须配 `--allow` |
| `--allow IP[,IP...]` | 只允许这些来源 IP / 网段连接，`none` = 取消。本机地址总是允许（自测要用） |
| `--file PATH` | 用本地的 gost 压缩包 |
| `--mirror URL` | 再加一个 GitHub 加速前缀（或设环境变量 `GH_PROXY`） |
| `--no-service` | 只装程序和配置，不动 systemd 和防火墙（容器里用） |
| `--show` / `--uninstall` | 显示信息 / 卸载 |

## 装了哪些东西

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/gost` | gost 程序 |
| `/usr/local/bin/gost-proxy` | 管理命令 |
| `/etc/gost/gost.yml` | gost 配置（由脚本生成，手改会在下次运行时被覆盖） |
| `/etc/gost/proxy.env` | 保存的设置（root 只读，含密码） |
| `/etc/systemd/system/gost.service` | 服务，用无登录权限的系统用户 `gost` 运行 |

如果服务器上原来就有不是本脚本装的 `gost.yml` 或 `gost.service`，脚本会先把它们改名为 `.bak.<时间>`，不会直接覆盖。

## 注意

- 代理一定要有密码或 IP 白名单：开放代理会很快被扫到、被滥用
- 需要用 systemd 的 Linux（Debian、Ubuntu、CentOS 系等）；支持 amd64、arm64、armv7、386
- jsDelivr 缓存分支内容最多约 12 小时，所以安装命令用的是带版本号的 `@v1.0.0`

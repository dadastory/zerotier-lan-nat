# ZeroTier LAN NAT Helper

这个项目用于把一台 Linux 服务器配置成 ZeroTier 到本地 LAN 的 NAT 网关。

典型用途：远程设备加入 ZeroTier 后，可以访问家里的路由器、NAS、服务器、Web 面板或 SSH 服务，而不需要在 LAN 内每台设备上配置回程路由。

当前方案是 NAT 模式：ZeroTier 客户端访问 LAN 时，Linux 服务器会把来源地址伪装成自己的 LAN 地址。LAN 设备只需要能回到这台服务器即可。

## 拓扑

```text
Remote ZeroTier client
        |
        | ZeroTier managed network
        v
ZeroTier virtual network
        |
        | managed route: <LAN_CIDR> via <SERVER_ZEROTIER_IP>
        v
Linux server running this helper
        |
        | NAT / MASQUERADE
        v
Local LAN
        |
        +-- Router / gateway
        +-- NAS / services
        +-- Other LAN devices
```

## 不要提交真实配置

`routes.conf` 是本机真实配置文件，已被 `.gitignore` 忽略，不应该提交到公开仓库。

仓库里只保留：

```text
routes.conf.example
```

新机器部署时复制一份：

```bash
cp routes.conf.example routes.conf
```

然后把里面的示例网卡和网段改成自己的真实值。

## ZeroTier Central 配置

在 ZeroTier Central 的网络页面添加 Managed Route：

```text
Destination: <LAN_CIDR>
Via:         <SERVER_ZEROTIER_IP>
```

示例：

```text
Destination: 192.168.1.0/24
Via:         10.147.17.53
```

如果使用本项目的 NAT 模式，主路由器通常不需要再添加 ZeroTier 网段的静态回程路由。

## 文件说明

```text
/opt/docker/zerotier-lan-nat/
├── README.md                 本文档
├── routes.conf.example       示例配置，适合提交
├── routes.conf               本机真实配置，不提交
├── zerotier-lan-nat.sh       主脚本，负责添加/删除/应用 NAT 规则
├── install.sh                安装 systemd 服务并启动
├── uninstall.sh              卸载 systemd 服务并清理 NAT 规则
└── zerotier-lan-nat.service  systemd 服务模板
```

系统级文件：

```text
/etc/default/zerotier-lan-nat
/etc/systemd/system/zerotier-lan-nat.service
/etc/sysctl.d/99-zerotier-lan-nat.conf
```

## routes.conf 格式

`routes.conf` 一行一条 ZeroTier 来源网段：

```text
# ZeroTier接口 ZeroTier网段
ztxxxxxxxx 10.147.17.0/24
```

如果以后有多个 ZeroTier 网络，可以写多行：

```text
ztxxxxxxxx 10.147.17.0/24
ztyyyyyyyy 10.200.0.0/24
```

每一条都会转发到 `/etc/default/zerotier-lan-nat` 里配置的 `LAN_NET`。

## 安装

新服务器上，把整个目录放到 `/opt/docker/zerotier-lan-nat` 后执行：

```bash
cd /opt/docker/zerotier-lan-nat
cp routes.conf.example routes.conf
nano routes.conf
LAN_IF=eth0 LAN_NET=192.168.1.0/24 ./install.sh
```

如果你的 LAN 网卡不是 `eth0`，或者 LAN 网段不是 `192.168.1.0/24`，请按实际情况修改环境变量。

安装脚本会完成：

```text
1. 写入 /etc/default/zerotier-lan-nat
2. 写入 /etc/systemd/system/zerotier-lan-nat.service
3. 写入 /etc/sysctl.d/99-zerotier-lan-nat.conf
4. 开启 net.ipv4.ip_forward=1
5. 执行 systemctl enable --now zerotier-lan-nat
```

安装后检查：

```bash
systemctl status zerotier-lan-nat
cd /opt/docker/zerotier-lan-nat
./zerotier-lan-nat.sh status
```

## 卸载

只卸载服务并清理本工具创建的 NAT 规则，保留目录和 `routes.conf`：

```bash
cd /opt/docker/zerotier-lan-nat
./uninstall.sh
```

彻底删除目录：

```bash
cd /opt/docker/zerotier-lan-nat
./uninstall.sh --purge
```

## 常用命令

查看状态：

```bash
cd /opt/docker/zerotier-lan-nat
./zerotier-lan-nat.sh status
```

查看已配置的 ZeroTier 来源网段：

```bash
./zerotier-lan-nat.sh list
```

添加来源网段：

```bash
./zerotier-lan-nat.sh add ztxxxxxxxx 10.147.17.0/24
```

按网段删除：

```bash
./zerotier-lan-nat.sh remove 10.147.17.0/24
```

按网卡和网段精确删除：

```bash
./zerotier-lan-nat.sh remove ztxxxxxxxx 10.147.17.0/24
```

手动编辑 `routes.conf` 后应用：

```bash
systemctl restart zerotier-lan-nat
```

临时停止转发：

```bash
systemctl stop zerotier-lan-nat
```

重新启用转发：

```bash
systemctl start zerotier-lan-nat
```

## 验证方法

确认 ZeroTier 网卡：

```bash
zerotier-cli listnetworks
ip -br addr | grep zt
```

确认 IPv4 转发已开启：

```bash
sysctl net.ipv4.ip_forward
```

正常应看到：

```text
net.ipv4.ip_forward = 1
```

确认 NAT 规则存在：

```bash
iptables -S DOCKER-USER | grep zerotier-lan-nat
iptables -t nat -S POSTROUTING | grep zerotier-lan-nat
```

从远程 ZeroTier 客户端测试：

```bash
ping <ROUTER_LAN_IP>
curl http://<ROUTER_LAN_IP>
ssh <USER>@<SERVER_LAN_IP>
```

Windows 客户端可以测试：

```powershell
ping <ROUTER_LAN_IP>
Test-NetConnection <SERVER_LAN_IP> -Port 22
```

## 工作原理

脚本会创建三类 iptables 规则：

```text
1. 允许 ZeroTier 网卡 -> LAN 网卡的转发
2. 允许 LAN 网卡 -> ZeroTier 网卡的已建立连接回包
3. 对 ZeroTier 来源访问 LAN 的流量做 MASQUERADE
```

示例：

```text
10.147.17.0/24 -> 192.168.1.0/24
```

LAN 设备看到的来源通常是 Linux 服务器的 LAN 地址，而不是远程客户端真实的 ZeroTier 地址。

优点：

```text
1. 主路由器无需配置回程静态路由
2. LAN 里的其他设备无需单独配置
3. 适合远程管理路由器、NAS、服务器、Web 面板、SSH
```

限制：

```text
1. LAN 设备看不到远程 ZeroTier 客户端的真实 IP
2. 如果需要双向透明路由，应改为纯路由模式，并在主路由器添加回程路由
```

## 和 Docker / 1Panel / FRP 的关系

脚本优先把 FORWARD 规则放进 Docker 推荐的 `DOCKER-USER` 链。

它只管理带有 `zerotier-lan-nat` 注释的 iptables 规则，不会清空或重建：

```text
Docker 规则
1Panel 规则
FRP 进程
UFW 规则
其他 iptables 规则
```

## 修改 LAN 网段或网卡

编辑：

```bash
nano /etc/default/zerotier-lan-nat
```

例如：

```text
LAN_IF=eth0
LAN_NET=192.168.1.0/24
```

然后重启：

```bash
systemctl restart zerotier-lan-nat
```

## 新服务器迁移步骤

1. 在新服务器安装 ZeroTier 并加入对应网络。
2. 确认新服务器能访问 LAN 网关：

```bash
ping <ROUTER_LAN_IP>
```

3. 查看新服务器的 ZeroTier IP 和网卡名：

```bash
zerotier-cli listnetworks
ip -br addr | grep zt
```

4. 把本目录复制到新服务器：

```text
/opt/docker/zerotier-lan-nat
```

5. 按实际 ZeroTier 网卡和网段修改：

```bash
cp routes.conf.example routes.conf
nano routes.conf
```

6. 安装并启动：

```bash
cd /opt/docker/zerotier-lan-nat
LAN_IF=<LAN_INTERFACE> LAN_NET=<LAN_CIDR> ./install.sh
```

7. 在 ZeroTier Central 修改 Managed Route 的 `via` 为新服务器的 ZeroTier IP。

## 常见问题

### 远程 ZeroTier 客户端无法访问 LAN 网关

检查 ZeroTier Central 是否有：

```text
<LAN_CIDR> via <SERVER_ZEROTIER_IP>
```

同时确认客户端允许 ZeroTier 下发的 Managed Routes。部分客户端需要手动允许路由。

### 服务器上没有配置中的 ZeroTier 网卡

查看实际 ZeroTier 网卡名：

```bash
ip -br addr | grep zt
zerotier-cli listnetworks
```

然后更新配置：

```bash
cd /opt/docker/zerotier-lan-nat
./zerotier-lan-nat.sh remove <OLD_ZT_IF> <ZT_CIDR>
./zerotier-lan-nat.sh add <NEW_ZT_IF> <ZT_CIDR>
```

### NAT 规则没有生效

执行：

```bash
systemctl restart zerotier-lan-nat
./zerotier-lan-nat.sh status
```

如果仍然没有规则，检查：

```bash
iptables -S DOCKER-USER
iptables -t nat -S POSTROUTING
```

### 远程能 ping 服务器但不能访问其他 LAN 设备

通常是以下原因之一：

```text
1. ZeroTier Central 的 Managed Route 没配对
2. 客户端没有接受 ZeroTier 下发路由
3. 服务器 ip_forward 没开
4. routes.conf 里的 ZeroTier 网卡名或网段不对
5. 目标 LAN 设备自身防火墙拒绝访问
```

## 回滚

卸载服务并清理规则：

```bash
cd /opt/docker/zerotier-lan-nat
./uninstall.sh
```

如果只是临时关闭：

```bash
systemctl stop zerotier-lan-nat
```

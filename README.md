# ZeroTier LAN NAT Helper

把一台 Linux 服务器配置成 ZeroTier 到内网的 NAT 网关。远程 ZeroTier 客户端可以访问内网设备，主路由和内网设备通常不需要额外配置回程路由。

## 使用流程

### 1. 克隆项目

推荐放到 `/opt/docker`：

```bash
sudo mkdir -p /opt/docker
cd /opt/docker
sudo git clone git@github.com:dadastory/zerotier-lan-nat.git
cd zerotier-lan-nat
```

如果没有配置 GitHub SSH key，也可以使用 HTTPS：

```bash
sudo git clone https://github.com/dadastory/zerotier-lan-nat.git
```

### 2. 准备配置

复制示例配置：

```bash
sudo cp routes.conf.example routes.conf
```

查看 ZeroTier 网卡名和 ZeroTier 地址：

```bash
zerotier-cli listnetworks
ip -br addr | grep zt
```

编辑 `routes.conf`：

```bash
sudo nano routes.conf
```

格式如下：

```text
# ZeroTier接口 ZeroTier网段
ztxxxxxxxx 10.147.17.0/24
```

每行表示允许一个 ZeroTier 网段通过这台服务器访问内网。

### 3. 安装并启动

指定内网网卡和内网网段后安装：

```bash
sudo LAN_IF=eth0 LAN_NET=192.168.1.0/24 ./install.sh
```

把 `eth0` 和 `192.168.1.0/24` 换成实际值。

安装脚本会创建并启动：

```text
zerotier-lan-nat.service
```

### 4. 配置 ZeroTier Central

在 ZeroTier Central 添加 Managed Route：

```text
Destination: <内网网段>
Via:         <这台服务器的 ZeroTier IP>
```

示例：

```text
Destination: 192.168.1.0/24
Via:         10.147.17.53
```

## 验证

查看服务状态：

```bash
systemctl status zerotier-lan-nat
./zerotier-lan-nat.sh status
```

确认转发开启：

```bash
sysctl net.ipv4.ip_forward
```

确认 NAT 规则：

```bash
iptables -S DOCKER-USER | grep zerotier-lan-nat
iptables -t nat -S POSTROUTING | grep zerotier-lan-nat
```

从远程 ZeroTier 客户端测试：

```bash
ping <内网网关IP>
ssh <用户>@<内网服务器IP>
```

Windows 客户端可以测试：

```powershell
ping <内网网关IP>
Test-NetConnection <内网服务器IP> -Port 22
```

## 管理

查看已配置网段：

```bash
./zerotier-lan-nat.sh list
```

添加网段：

```bash
sudo ./zerotier-lan-nat.sh add ztxxxxxxxx 10.147.17.0/24
```

删除网段：

```bash
sudo ./zerotier-lan-nat.sh remove 10.147.17.0/24
```

修改 `routes.conf` 后应用：

```bash
sudo systemctl restart zerotier-lan-nat
```

停止：

```bash
sudo systemctl stop zerotier-lan-nat
```

启动：

```bash
sudo systemctl start zerotier-lan-nat
```

## 卸载

卸载服务并清理 NAT 规则，保留项目目录：

```bash
sudo ./uninstall.sh
```

卸载并删除项目目录：

```bash
sudo ./uninstall.sh --purge
```

## 说明

脚本只管理带有 `zerotier-lan-nat` 注释的 iptables 规则，不会清空 Docker、1Panel、FRP、UFW 或其他规则。

默认优先使用 Docker 推荐的 `DOCKER-USER` 链；如果系统没有该链，则使用 `FORWARD` 链。

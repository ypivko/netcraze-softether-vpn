# Netcraze Ultra SoftEther VPN + Split Tunneling

SoftEther VPN client with Russia-bypass split tunneling for Netcraze Ultra (NC-1812) routers running NDMS.

## Architecture

```
LAN devices (192.168.2.0/24)
        |
  Netcraze Ultra (NDMS 5.x, aarch64)
        |
        +-- ipset "russia" (~11250 subnets) --> direct WAN
        |
        +-- everything else --> fwmark 0x1 --> ip rule table 100
             --> SoftEther vpnclient --> vpn_vpn (TAP)
               --> NL VPS (SoftEther TCP 443)
```

## Prerequisites

- Netcraze Ultra NC-1812 (or compatible Keenetic/NDMS router, aarch64)
- NDMS 3.7+ with OPKG component
- Entware installed on internal storage or USB
- SoftEther VPN server with TAP bridge

## Installation

### 1. Install Entware

```
# In NDMS CLI (SSH port 22):
opkg disk storage:/ https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz
```

### 2. Install packages

```bash
# SSH to Entware shell (port 222, default password: keenetic)
ssh -p 222 root@<router-ip>

opkg update
opkg install softethervpn5-client ipset iptables curl python3-light
```

### 3. Configure SoftEther VPN client

```bash
# Start vpnclient
cd /opt/libexec/softethervpn && ./vpnclient start

# Create adapter and account
vpncmd /CLIENT localhost /CMD NicCreate vpn
vpncmd /CLIENT localhost /CMD AccountCreate conn1 /SERVER:<vpn-server>:443 /HUB:<hub> /USERNAME:<user> /NICNAME:vpn
vpncmd /CLIENT localhost /CMD AccountPasswordSet conn1 /PASSWORD:<pass> /TYPE:standard
vpncmd /CLIENT localhost /CMD AccountStartupSet conn1
vpncmd /CLIENT localhost /CMD AccountConnect conn1

# Assign static IP on vpn_vpn (DHCP may not work with TAP bridge)
ip addr add <vpn-ip>/24 dev vpn_vpn
```

### 4. Deploy scripts

```bash
# Copy scripts to router
scp -P 222 vpn-split.sh root@<router-ip>:/opt/etc/
scp -P 222 S99vpnsplit root@<router-ip>:/opt/etc/init.d/
scp -P 222 vpn-watchdog.sh root@<router-ip>:/opt/etc/
scp -P 222 update-russia-list.sh root@<router-ip>:/opt/etc/

# Make executable
ssh -p 222 root@<router-ip> 'chmod +x /opt/etc/vpn-split.sh /opt/etc/init.d/S99vpnsplit /opt/etc/vpn-watchdog.sh /opt/etc/update-russia-list.sh'
```

### 5. Generate Russia IP list

```bash
ssh -p 222 root@<router-ip> '/opt/etc/update-russia-list.sh'
```

### 6. Configure vpn-split.sh

Edit `vpn-split.sh` and set:
- `VPN_IP` - static IP for vpn_vpn interface
- `VPN_GW` - VPN gateway (TAP bridge IP on server)
- `SE_SERVER` - SoftEther server IP (excluded from VPN to prevent loop)
- `AWG_SERVER` - any other server IPs to exclude from VPN

### 7. Start split tunneling

```bash
/opt/etc/vpn-split.sh start
```

### 8. Setup cron

```bash
mkdir -p /opt/var/spool/cron/crontabs
cat > /opt/var/spool/cron/crontabs/root << 'EOF'
*/5 * * * * /opt/etc/vpn-watchdog.sh
0 4 * * 0 /opt/etc/update-russia-list.sh
EOF
killall crond; /opt/sbin/crond -L /opt/var/log/cron.log
```

## Files

| File | Description |
|------|-------------|
| `vpn-split.sh` | Main split tunneling script (start/stop/status) |
| `S99vpnsplit` | Entware init script (runs after S05vpnclient) |
| `vpn-watchdog.sh` | Cron watchdog - reconnects VPN if down |
| `update-russia-list.sh` | Downloads Russia IP prefixes from RIPE |

## How it works

1. **ipset** `russia` loaded with ~11250 Russian IP prefixes from RIPE
2. **iptables mangle** PREROUTING: LAN traffic to Russian IPs gets `RETURN` (no mark), everything else gets `MARK 0x1`
3. **ip rule**: packets with fwmark `0x1` use routing table 100
4. **Table 100**: default route via VPN gateway through `vpn_vpn`
5. **iptables FORWARD**: explicit ACCEPT for LAN<->vpn_vpn (NDMS FORWARD policy is DROP)
6. **iptables nat MASQUERADE** on vpn_vpn interface

## Important NDMS-specific notes

- NDMS FORWARD chain policy is DROP - you MUST add explicit ACCEPT rules for vpn_vpn
- `/etc/iproute2/rt_tables` does not exist on NDMS, but `ip rule` with numeric table IDs works fine
- `iptables` must be installed from Entware (keenetic-specific build that sees NDMS chains)
- DHCP on SoftEther TAP interface may not work - use static IP assignment
- Entware SSH runs on port 222 (dropbear), NDMS SSH on port 22

## Rollback

```bash
# Quick - remove split tunneling rules:
ssh -p 222 root@<router-ip> '/opt/etc/vpn-split.sh stop'

# Or reboot the router (everything restarts automatically via init scripts)
```

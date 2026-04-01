# Netcraze Ultra SoftEther VPN + Split Tunneling

SoftEther VPN client with Russia-bypass split tunneling for Netcraze Ultra (NC-1812) routers running NDMS 5.x.

See [DIAGNOSTICS.md](DIAGNOSTICS.md) for the troubleshooting runbook.

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

**Key persistence mechanism:** NDMS periodically rebuilds ALL iptables chains, wiping custom rules. The hook in `ndm/netfilter.d/10-vpn-split.sh` is called automatically by NDMS after every rebuild and restores mangle/filter/nat rules, disables fastnat, and restores the table 100 route. A 5-minute cron watchdog acts as a secondary safety net.

## Files

| File | Path on router | Description |
|------|---------------|-------------|
| `vpn-split.sh` | `/opt/etc/vpn-split.sh` | Main script: `start` / `stop` / `fix` / `status` |
| `S99vpnsplit` | `/opt/etc/init.d/S99vpnsplit` | Entware init script (runs after S05vpnclient on boot) |
| `vpn-watchdog.sh` | `/opt/etc/vpn-watchdog.sh` | Cron watchdog every 5 min: reconnects VPN if down, calls `fix` |
| `update-russia-list.sh` | `/opt/etc/update-russia-list.sh` | Downloads Russia IP prefixes from RIPE (weekly cron) |
| `ndm/netfilter.d/10-vpn-split.sh` | `/opt/etc/ndm/netfilter.d/10-vpn-split.sh` | **NDMS netfilter hook** — restores all rules after every NDMS iptables rebuild |
| `DIAGNOSTICS.md` | — | Troubleshooting runbook |

## Prerequisites

- Netcraze Ultra NC-1812 (or compatible Keenetic/NDMS router, aarch64)
- NDMS 5.x with OPKG component
- Entware installed on internal storage or USB
- SoftEther VPN server with TAP bridge on the remote VPS

## Installation

### 1. Install Entware

```sh
# In NDMS CLI (SSH port 22):
opkg disk storage:/ https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz
```

### 2. Install packages

```sh
# SSH to Entware shell (port 222, default password: keenetic)
ssh -p 222 root@<router-ip>

opkg update
opkg install softethervpn5-client ipset iptables curl python3 python3-light
```

### 3. Configure SoftEther VPN client

```sh
# Start vpnclient
cd /opt/libexec/softethervpn && ./vpnclient start

# Create adapter and account
vpncmd /CLIENT localhost /CMD NicCreate vpn
vpncmd /CLIENT localhost /CMD AccountCreate conn1 /SERVER:<vpn-server>:443 /HUB:<hub> /USERNAME:<user> /NICNAME:vpn
vpncmd /CLIENT localhost /CMD AccountPasswordSet conn1 /PASSWORD:<pass> /TYPE:standard
vpncmd /CLIENT localhost /CMD AccountStartupSet conn1
vpncmd /CLIENT localhost /CMD AccountConnect conn1
```

### 4. Edit vpn-split.sh

Set these variables at the top:

```sh
VPN_IP="192.168.30.11"    # static IP for vpn_vpn (assigned by the script, not DHCP)
VPN_GW="192.168.30.1"     # VPN gateway (TAP bridge IP on the VPS)
SE_SERVER="<vps-ip>"      # SoftEther server IP (excluded from VPN to prevent loop)
AWG_SERVER="<other-ip>"   # any other server IPs to exclude from VPN
```

### 5. Deploy scripts

```sh
# Note: use -O flag — Entware's dropbear SSH has no sftp-server
scp -O -P 222 vpn-split.sh root@<router-ip>:/opt/etc/
scp -O -P 222 S99vpnsplit root@<router-ip>:/opt/etc/init.d/
scp -O -P 222 vpn-watchdog.sh root@<router-ip>:/opt/etc/
scp -O -P 222 update-russia-list.sh root@<router-ip>:/opt/etc/
scp -O -P 222 ndm/netfilter.d/10-vpn-split.sh root@<router-ip>:/opt/etc/ndm/netfilter.d/

ssh -p 222 root@<router-ip> 'chmod +x \
  /opt/etc/vpn-split.sh \
  /opt/etc/init.d/S99vpnsplit \
  /opt/etc/vpn-watchdog.sh \
  /opt/etc/update-russia-list.sh \
  /opt/etc/ndm/netfilter.d/10-vpn-split.sh'
```

### 6. Generate Russia IP list

```sh
ssh -p 222 root@<router-ip> '/opt/etc/update-russia-list.sh'
```

### 7. Start split tunneling

```sh
ssh -p 222 root@<router-ip> '/opt/etc/init.d/S99vpnsplit start'
```

### 8. Setup cron

```sh
ssh -p 222 root@<router-ip> '
mkdir -p /opt/var/spool/cron/crontabs
cat > /opt/var/spool/cron/crontabs/root << EOF
*/5 * * * * /opt/etc/vpn-watchdog.sh
0 4 * * 0 /opt/etc/update-russia-list.sh
EOF
killall crond 2>/dev/null; /opt/sbin/crond -L /opt/var/log/cron.log'
```

## How it works

1. **ipset** `russia` loaded with ~11250 Russian IP prefixes from RIPE
2. **iptables mangle** PREROUTING: traffic from LAN to Russian IPs → `RETURN` (no mark); everything else → `MARK 0x1`
3. **ip rule**: packets with fwmark `0x1` use routing table 100
4. **Table 100**: default route via `192.168.30.1 dev vpn_vpn`
5. **iptables FORWARD**: explicit ACCEPT for LAN↔vpn_vpn (NDMS FORWARD policy is DROP)
6. **MASQUERADE** on vpn_vpn (covered by NDMS `_NDM_MASQ` + explicit rule)
7. **MSS clamp** to 1200 on vpn_vpn (SoftEther TCP/443 adds ~250 bytes overhead)

## Quick reference

| Task | Command |
|------|---------|
| Status | `/opt/etc/vpn-split.sh status` |
| Start split tunneling | `/opt/etc/vpn-split.sh start` |
| Stop split tunneling | `/opt/etc/vpn-split.sh stop` |
| Re-apply rules (idempotent) | `/opt/etc/vpn-split.sh fix` |
| Full restart | `/opt/etc/init.d/S99vpnsplit restart` |
| Watchdog log | `tail -50 /opt/var/log/vpn-watchdog.log` |
| NDMS hook log | `cat /tmp/hook.log` |
| Update Russia list | `/opt/etc/update-russia-list.sh` |
| Add IP to Russia list | `ipset add russia <IP> && echo "add russia <IP>" >> /opt/etc/russia.ipset` |
| Check site routing | `ipset test russia <IP>` |

## Known issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `scp` fails with "sftp-server: not found" | Entware dropbear has no sftp-server, modern `scp` defaults to SFTP protocol | Use `scp -O` (force legacy SCP protocol) |
| `ModuleNotFoundError: No module named 'json'` | `python3-base` alone doesn't include the json module — it's in `python3-light` | Install `python3-light` explicitly alongside `python3` |
| `ipset restore` fails on "create" line | ipset v7.21 ignores `-exist` for `create` when set exists | Script uses `flush` + `grep "^add" \| ipset restore -exist` |
| table 100 cleared after vpn_vpn reconnects | Kernel removes routes when interface goes down | `vpn-split.sh fix` restores it; netfilter hook also checks every rebuild |
| `nf_conntrack_fastnat=1` causes connection resets after ~50KB | NDMS resets fastnat to 1 on every iptables rebuild | Netfilter hook sets it to 0 on every rebuild |
| NDMS wipes all custom iptables chains | NDMS rebuilds netfilter tables on any network event | Netfilter hook in `ndm/netfilter.d/` is called automatically after each rebuild |

## Rollback

```sh
# Stop split tunneling (VPN stays connected, all traffic goes via WAN):
/opt/etc/vpn-split.sh stop

# Or reboot (everything restarts automatically via Entware init scripts):
reboot
```

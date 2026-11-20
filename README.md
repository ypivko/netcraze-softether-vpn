# SoftEther VPN + Split Tunneling for NDMS 5.x routers

SoftEther VPN client with Russia-bypass split tunneling for Keenetic/Netcraze routers running NDMS 5.x.

Tested on:
- **Netcraze Ultra NC-1812** (aarch64)
- **Keenetic Giga KN-1011** (mips) — see [Router-specific notes](#router-specific-notes)
- **Keenetic Giga KN-1012** (aarch64, NDMS 5.1, no public IP — managed via KeenDNS cloud) — see [KN-1012 notes](#keenetic-giga-kn-1012)

See [DIAGNOSTICS.md](DIAGNOSTICS.md) for the troubleshooting runbook.

## Architecture

```
LAN devices (192.168.1.0/24)
        |
  Keenetic/Netcraze (NDMS 5.x)
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
| `vpn-split.sh` | `/opt/bin/vpn-split.sh` | Main script: `start` / `stop` / `fix` / `status` |
| `S99vpnsplit` | `/opt/etc/init.d/S99vpnsplit` | Entware init script (runs after S05vpnclient on boot); restores the table 100 route as soon as the tunnel is up |
| `vpn-watchdog.sh` | `/opt/bin/vpn-watchdog.sh` | Cron watchdog every 5 min: reconnects VPN if down, calls `fix` |
| `update-russia-list.sh` | `/opt/bin/update-russia-list.sh` | Downloads Russia IP prefixes from RIPE (weekly cron) |
| `ndm/netfilter.d/10-vpn-split.sh` | `/opt/etc/ndm/netfilter.d/10-vpn-split.sh` | **NDMS netfilter hook** — restores all rules after every NDMS iptables rebuild |
| `ndm/netfilter.d/20-dns-split.sh` | `/opt/etc/ndm/netfilter.d/20-dns-split.sh` | *Optional, DNS anti-poison:* redirects LAN DNS to local dnsmasq |
| `dns/dnsmasq.conf` | `/opt/etc/dnsmasq.conf` | *Optional, DNS anti-poison:* dnsmasq on :5354, `.ru/.su/.рф` direct to Yandex |
| `dns/dnsmasq.servers` | `/opt/etc/dnsmasq.servers` | *Optional, DNS anti-poison:* upstream list (tunnel resolver, then Yandex) |
| `dns/dns-failover.sh` | `/opt/bin/dns-failover.sh` | *Optional, DNS anti-poison:* cron every minute, switches to Yandex while the tunnel is down |
| `DIAGNOSTICS.md` | — | Troubleshooting runbook |

## Prerequisites

- Keenetic or Netcraze router running NDMS 5.x with OPKG component
- Entware installed on USB storage
- SoftEther VPN server with TAP bridge on the remote VPS

## Installation

### 1. Install Entware

**Netcraze Ultra (aarch64):**
```sh
# In NDMS CLI (SSH port 22):
opkg disk storage:/ https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz
```

**Keenetic Giga KN-1011 (mips) and other Keenetic models:**  
Install Entware via the Keenetic web interface: **My Keenetic → OPKG → Install**.  
Entware installs to the USB disk automatically. Feed: `http://bin.entware.net/mipselsf-k3.4`

### 2. Install packages

```sh
# SSH to Entware shell (port 222)
ssh -p 222 root@<router-ip>

opkg update
opkg install softethervpn5-client ipset iptables curl python3-light cron iputils-ping
```

> **Note:** `iptables` and `curl` are not pre-installed on all models. Install them explicitly.

### 3. Configure SoftEther VPN client

```sh
# Start vpnclient daemon
/opt/etc/init.d/S05vpnclient start

# Create virtual NIC
vpncmd /CLIENT localhost /PASSWORD: /CMD NicCreate vpn

# Create and configure account (replace <...> with your values)
vpncmd /CLIENT localhost /PASSWORD: /CMD AccountCreate vpn_account /SERVER:<vpn-server>:443 /HUB:<hub> /USERNAME:<user> /NICNAME:vpn
vpncmd /CLIENT localhost /PASSWORD: /CMD AccountPasswordSet vpn_account /PASSWORD:<pass> /TYPE:standard
vpncmd /CLIENT localhost /PASSWORD: /CMD AccountStartupSet vpn_account
vpncmd /CLIENT localhost /PASSWORD: /CMD AccountConnect vpn_account
```

**Required:** enable bridge routing mode, otherwise SoftEther does not forward LAN traffic:

```sh
/opt/etc/init.d/S05vpnclient stop
sed -i 's/bool RequireBridgeRoutingMode false/bool RequireBridgeRoutingMode true/' /opt/libexec/softethervpn/vpn_client.config
/opt/etc/init.d/S05vpnclient start
```

The account name `vpn_account` must match the `ACCOUNT=` variable in `S99vpnsplit` and `vpn-watchdog.sh`.

### 4. Edit vpn-split.sh

Set these variables at the top:

```sh
VPN_IP="192.168.30.11"    # static IP for vpn_vpn (assigned by the script, not DHCP)
                           # use a unique IP if multiple clients share the same hub
VPN_GW="192.168.30.1"     # VPN gateway (TAP bridge IP on the VPS)
LAN="192.168.1.0/24"      # your local LAN subnet
SE_SERVER="<vps-ip>"      # SoftEther server IP (excluded from VPN to prevent loop)
AWG_SERVER="<other-ip>"   # any other server IPs to exclude from VPN
```

Also update `LAN=` in `ndm/netfilter.d/10-vpn-split.sh` to match.

### 5. Deploy scripts

```sh
# Note: use -O flag — Entware's dropbear SSH has no sftp-server
scp -O -P 222 vpn-split.sh root@<router-ip>:/opt/bin/vpn-split.sh
scp -O -P 222 vpn-watchdog.sh root@<router-ip>:/opt/bin/vpn-watchdog.sh
scp -O -P 222 update-russia-list.sh root@<router-ip>:/opt/bin/update-russia-list.sh
scp -O -P 222 S99vpnsplit root@<router-ip>:/opt/etc/init.d/S99vpnsplit
scp -O -P 222 ndm/netfilter.d/10-vpn-split.sh root@<router-ip>:/opt/etc/ndm/netfilter.d/10-vpn-split.sh

ssh -p 222 root@<router-ip> 'chmod +x \
  /opt/bin/vpn-split.sh \
  /opt/bin/vpn-watchdog.sh \
  /opt/bin/update-russia-list.sh \
  /opt/etc/init.d/S99vpnsplit \
  /opt/etc/ndm/netfilter.d/10-vpn-split.sh'
```

### 6. Generate Russia IP list

```sh
ssh -p 222 root@<router-ip> '/opt/bin/update-russia-list.sh'
```

### 7. Start split tunneling

```sh
ssh -p 222 root@<router-ip> '/opt/etc/init.d/S99vpnsplit start'
```

### 8. Setup cron

Add the jobs to `/opt/etc/crontab` (system crontab of Entware `cron`). Use **either** `/opt/etc/crontab` **or** `/opt/etc/cron.d/` — not both, otherwise every job runs twice.

```sh
ssh -p 222 root@<router-ip> '
cat >> /opt/etc/crontab << EOF
*/5 * * * * root /opt/bin/vpn-watchdog.sh
0 3 * * 0 root /opt/bin/update-russia-list.sh
EOF
sed -i "s|^PATH=.*|PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin|" /opt/etc/crontab
/opt/etc/init.d/S10cron restart'
```

> **PATH matters:** `/opt/bin` must come before `/usr/sbin`. The stock NDMS `/usr/sbin/ping` always exits with code 1, so with the default PATH the watchdog decides the tunnel is dead and reconnects it every 5 minutes.

### 9. Change the default Entware root password

Entware ships with `root` / `keenetic`. Change it right away:

```sh
ssh -p 222 root@<router-ip> passwd
```

### 10. DNS anti-poison (optional, recommended)

Split tunneling only routes **traffic**. DNS still goes to the ISP resolver, and in Russia it returns fake or empty answers for blocked foreign domains (Instagram, ChatGPT, etc.). The site is then broken even though its traffic would go through the VPN. Fix: resolve foreign names on the VPS through the tunnel, keep Russian zones on a Russian resolver.

```
LAN client :53 --DNAT--> dnsmasq :5354 on the router
   .ru / .su / .рф     --> 77.88.8.8 (Yandex, direct)
   everything else     --> 192.168.30.1 (resolver on the VPS, via tunnel)
                           fallback 77.88.8.8 (strict-order)
```

**VPS side** (once per server). Make a resolver listen on the TAP bridge IP. With systemd-resolved, in `/etc/systemd/resolved.conf`:

```ini
[Resolve]
DNS=1.1.1.1 9.9.9.9
DNSStubListenerExtra=192.168.30.1
```

`systemctl restart systemd-resolved`, then check from the router: `nslookup google.com 192.168.30.1`. Allow port 53 only from the tunnel subnet (192.168.30.0/24), so the resolver is not open to the internet.

**Router side.** Edit the LAN IP in `dns/dnsmasq.conf` and the LAN/IP in `20-dns-split.sh` (office-style LANs such as 192.168.2.0/24 need both changed), then:

```sh
ssh -p 222 root@<router-ip> 'opkg update && opkg install dnsmasq-full'

scp -O -P 222 dns/dnsmasq.conf      root@<router-ip>:/opt/etc/dnsmasq.conf
scp -O -P 222 dns/dnsmasq.servers   root@<router-ip>:/opt/etc/dnsmasq.servers
scp -O -P 222 dns/dns-failover.sh   root@<router-ip>:/opt/bin/dns-failover.sh
scp -O -P 222 ndm/netfilter.d/20-dns-split.sh root@<router-ip>:/opt/etc/ndm/netfilter.d/20-dns-split.sh

ssh -p 222 root@<router-ip> '
chmod +x /opt/bin/dns-failover.sh /opt/etc/ndm/netfilter.d/20-dns-split.sh
for s in /opt/etc/init.d/S*dnsmasq; do $s restart; done
table=nat type=iptables /opt/etc/ndm/netfilter.d/20-dns-split.sh
echo "*/1 * * * * root /opt/bin/dns-failover.sh" >> /opt/etc/crontab
/opt/etc/init.d/S10cron restart'
```

Check:

```sh
nslookup instagram.com 127.0.0.1:5354     # real Meta address, not a stub/empty
iptables -t nat -S PREROUTING | grep 5354 # two DNAT rules at the top
cat /opt/etc/dnsmasq.servers              # tunnel resolver first while the tunnel is up
```

**Failover.** `strict-order` alone is not enough: while the tunnel is down dnsmasq still waits on the dead resolver and clients get "site not found". `dns-failover.sh` pings the VPS gateway every minute and rewrites `dnsmasq.servers` to Yandex only, then back when the tunnel returns (logged to `vpn-watchdog.log`). Test it: `iptables -I OUTPUT -d 192.168.30.1 -j DROP`, wait a minute, the servers file should show only `77.88.8.8`; then `iptables -D OUTPUT -d 192.168.30.1 -j DROP`.

**Rollback:**

```sh
rm /opt/etc/ndm/netfilter.d/20-dns-split.sh
for pr in udp tcp; do iptables -t nat -D PREROUTING -s 192.168.1.0/24 -p $pr --dport 53 -j DNAT --to-destination 192.168.1.1:5354; done
sed -i '/dns-failover/d' /opt/etc/crontab && /opt/etc/init.d/S10cron restart
```

Clients fall back to the NDMS resolver right away.

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
| Status | `/opt/bin/vpn-split.sh status` |
| Start split tunneling | `/opt/bin/vpn-split.sh start` |
| Stop split tunneling | `/opt/bin/vpn-split.sh stop` |
| Re-apply rules (idempotent) | `/opt/bin/vpn-split.sh fix` |
| Full restart | `/opt/etc/init.d/S99vpnsplit restart` |
| Watchdog log | `tail -50 /opt/var/log/vpn-watchdog.log` |
| Update Russia list | `/opt/bin/update-russia-list.sh` |
| Add IP to Russia list | `ipset add russia <IP> && echo "add russia <IP>" >> /opt/etc/russia.ipset` |
| Check site routing | `ipset test russia <IP>` |
| Check DNS (anti-poison) | `nslookup <name> 127.0.0.1:5354`, `cat /opt/etc/dnsmasq.servers` |

## Known issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `scp` fails with "sftp-server: not found" | Entware dropbear has no sftp-server, modern `scp` defaults to SFTP protocol | Use `scp -O` (force legacy SCP protocol) |
| `ModuleNotFoundError: No module named 'json'` | `python3-base` alone doesn't include the json module — it's in `python3-light` | Install `python3-light` explicitly |
| Non-Russian traffic goes directly via WAN for up to 5 min after boot/reconnect | table 100 route is dropped while `vpn_vpn` has no session yet | `S99vpnsplit` runs `vpn-split.sh fix` in the background as soon as the VPN gateway answers ping |
| Watchdog reconnects the tunnel every run | NDMS `/usr/sbin/ping` always returns 1; cron PATH starts with `/usr/sbin` | `PATH=/opt/sbin:/opt/bin:...` in `vpn-watchdog.sh` and `/opt/etc/crontab` |
| Every cron job runs twice | jobs defined both in `/opt/etc/crontab` and `/opt/etc/cron.d/` | keep them in one place |
| SoftEther connects but LAN traffic is not forwarded | `RequireBridgeRoutingMode false` (default) | set it to `true` in `vpn_client.config` (see step 3) |
| Tunnel reconnects several times a day for no reason | watchdog treated one lost ping as a dead tunnel and forced a reconnect | `vpn-watchdog.sh` reconnects only when all 3 pings fail (`ping -c3`) |
| Foreign site does not open ("site not found" / wrong IP) although its traffic goes via VPN | ISP resolver poisons DNS for blocked domains | DNS anti-poison, step 10 |
| "Site not found" for a few minutes while the tunnel reconnects | dnsmasq keeps querying the dead tunnel resolver | `dns-failover.sh` every minute (step 10) |
| Firmware update from the Entware shell fails: `Core::Ndss: cannot connect to the server`, `Components::UpdateTask: request failed (0)` | `ndmc -c "components commit"` (or a one-shot `ssh ... 'components commit'`) closes its CLI session right after starting the task, and the task is dropped; the update server itself is reachable | Use local RCI and keep the request open: `curl -X POST -d '{}' http://127.0.0.1:79/rci/components/list`, then the same for `/rci/components/commit`. The router downloads the image and reboots; Entware, SoftEther and the hooks come back on their own |
| `ipset restore` fails on "create" line | ipset v7.21+ ignores `-exist` for `create` when set already exists | Script uses `flush` + `grep "^add" \| ipset restore -exist` |
| table 100 cleared after vpn_vpn reconnects | Kernel removes routes when interface goes down | `vpn-split.sh fix` restores it; netfilter hook also checks on every rebuild |
| `nf_conntrack_fastnat=1` causes connection resets after ~50KB | NDMS resets fastnat to 1 on every iptables rebuild | Netfilter hook sets it to 0 on every rebuild |
| NDMS wipes all custom iptables chains | NDMS rebuilds netfilter tables on any network event | Netfilter hook in `ndm/netfilter.d/` is called automatically after each rebuild |
| `iptables: not found` in hook | NDMS hook runs in restricted environment without `/opt/sbin` in PATH | `10-vpn-split.sh` sets `export PATH=/opt/sbin:/opt/bin:$PATH` at startup |
| ipset RETURN rule missing after start | ipset not yet loaded when mangle rules are added in a single if-block | Rules are now checked individually; ipset rule failure doesn't block others |

## Rollback

```sh
# Stop split tunneling (VPN stays connected, all traffic goes via WAN):
/opt/bin/vpn-split.sh stop

# Or reboot (everything restarts automatically via Entware init scripts):
reboot
```

---

## Router-specific notes

### Keenetic Giga KN-1011

| Parameter | Value |
|-----------|-------|
| Architecture | mips (mipselsf-k3.4) |
| NDMS version | 5.00.C.x |
| NDMS CLI SSH | port **8022**, user `admin` |
| Entware SSH | port **222**, user `root` |
| Default LAN | 192.168.1.0/24 |
| Entware feed | `http://bin.entware.net/mipselsf-k3.4` |

**Extra packages required** (not present in base Entware on this model):
```sh
opkg install iptables curl
```

**Cron daemon:** Entware `cron` (`S10cron`) reads `/opt/etc/crontab` and `/opt/etc/cron.d/*` (system crontab format: `min hour dom mon dow user command`). Put the jobs in one of them only — see step 8.

**Multiple VPN clients on the same hub:** each client needs a unique TAP IP. Update `VPN_IP` in `vpn-split.sh`:
```sh
VPN_IP="192.168.30.13"   # unique per client on the shared hub
```

Current TAP IP allocations:
| IP | Device |
|----|--------|
| 192.168.30.1 | NL VPS (gateway) |
| 192.168.30.10 | MikroTik RB4011 |
| 192.168.30.11 | Netcraze Ultra NC-1812 |
| 192.168.30.12 | Keenetic KN-1011 #1 |
| 192.168.30.13 | Keenetic KN-1011 #2 |
| 192.168.30.14 | Keenetic KN-1012 |
| 192.168.30.20 | MikroTik hAP ax² |

**Entware startup** is handled by `opt-ndmsv2` package, which registers an NDMS hook that starts all `/opt/etc/init.d/S??*` scripts at boot. No additional configuration needed.

**No python3?** The `update-russia-list.sh` script auto-detects python3 availability. On routers without it (limited storage), it falls back to shell-only JSON parsing via `grep`.

### Keenetic Giga KN-1012

| Parameter | Value |
|-----------|-------|
| Architecture | aarch64 (`aarch64-k3.10` feed, same as Netcraze Ultra) |
| NDMS version | 5.1.x |
| Entware SSH | dropbear on port **22** after a fresh OPKG install (not 222) |
| Default LAN | 192.168.1.0/24 |
| NDMS CLI from Entware shell | `ndmc -c "<command>"`, e.g. `ndmc -c "system configuration save"` |

#### Managing a router without a public IP (KeenDNS cloud only)

If the router is behind CGNAT and reachable only via its KeenDNS cloud name (`https://<id>.netcraze.io` / `.keenetic.io`), only the web UI is proxied — no SSH. Two ways in:

1. **RCI HTTP API over the KeenDNS URL** — runs any NDMS CLI command:
   - `GET /auth` → `401` with headers `X-NDM-Realm` and `X-NDM-Challenge` (+ session cookie);
   - `POST /auth` with JSON `{"login":"admin","password":"<sha256(challenge + md5(login:realm:password))>"}` → `200`;
   - `POST /rci/` with `[{"parse":"show version"}, {"parse":"system configuration save"}]`.
2. **A management tunnel to a router you control** — create an L2TP client through RCI (`interface L2TP0`, `peer <your-ip>`, `authentication identity/password`, `no ip global`, `no ip name-servers`, `ipcp no dns-routes`, `security-level private`, `connect via ISP`, `up`, then `system configuration save`) and SSH to Entware over that tunnel. If the remote LAN overlaps yours, masquerade on your side. Disable the server side when you are done; the client can stay configured for later maintenance.


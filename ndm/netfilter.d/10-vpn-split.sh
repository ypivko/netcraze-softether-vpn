#!/bin/sh
# Keenetic NDMS netfilter hook — called automatically when NDMS rewrites iptables
# Variables provided by NDMS: $table (filter/nat/mangle/raw), $type (iptables/ip6tables)
# PATH must be set explicitly — NDMS hook environment does not include /opt/sbin
export PATH=/opt/sbin:/opt/bin:$PATH

[ "$type" = "ip6tables" ] && exit 0  # Skip IPv6

VPN_IF="vpn_vpn"
LAN="192.168.1.0/24"        # must match vpn-split.sh
SE_SERVER="188.137.180.77"
MARK=0x1
IPSET_FILE="/opt/etc/russia.ipset"

# Disable NDMS fast NAT (causes connection resets for forwarded VPN traffic)
echo 0 > /proc/sys/net/netfilter/nf_conntrack_fastnat 2>/dev/null
echo 0 > /proc/sys/net/netfilter/nf_conntrack_fastroute 2>/dev/null
echo 0 > /proc/sys/net/hwnat/extif_offload 2>/dev/null

VPN_GW="192.168.30.1"
TABLE_ID=100

# Restore routing table 100 if missing (cleared when vpn_vpn reconnects)
if ip link show "$VPN_IF" >/dev/null 2>&1; then
    ip route show table $TABLE_ID | grep -q "^default" || \
        ip route replace default via $VPN_GW dev $VPN_IF table $TABLE_ID 2>/dev/null
fi

case "$table" in
  mangle)
    # Load ipset if needed
    # Note: ipset restore fails on "create" line if set exists — use flush+grep workaround
    if ! ipset list russia >/dev/null 2>&1; then
        ipset restore < "$IPSET_FILE" 2>/dev/null
    elif [ "$(ipset list russia 2>/dev/null | grep -c '^[0-9]')" -lt 1000 ]; then
        ipset flush russia 2>/dev/null
        grep "^add " "$IPSET_FILE" | ipset restore -exist 2>/dev/null
    fi

    # Mark non-Russia LAN traffic for VPN routing
    # Each rule checked individually to prevent partial failures
    iptables -t mangle -C PREROUTING -s $LAN -m set --match-set russia dst -j RETURN 2>/dev/null || \
        iptables -t mangle -A PREROUTING -s $LAN -m set --match-set russia dst -j RETURN 2>/dev/null
    iptables -t mangle -C PREROUTING -s $LAN -d $SE_SERVER -j RETURN 2>/dev/null || \
        iptables -t mangle -A PREROUTING -s $LAN -d $SE_SERVER -j RETURN
    iptables -t mangle -C PREROUTING -s $LAN -j MARK --set-mark $MARK 2>/dev/null || \
        iptables -t mangle -A PREROUTING -s $LAN -j MARK --set-mark $MARK

    # MSS clamp for VPN interface
    iptables -t mangle -C FORWARD -o $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -o $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C FORWARD -i $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -i $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C POSTROUTING -o $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || \
        iptables -t mangle -A POSTROUTING -o $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
    ;;

  filter)
    # Allow VPN forwarding (NDMS FORWARD policy=DROP)
    iptables -C FORWARD -s $LAN -o $VPN_IF -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -s $LAN -o $VPN_IF -j ACCEPT
    iptables -C FORWARD -i $VPN_IF -d $LAN -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 2 -i $VPN_IF -d $LAN -m state --state RELATED,ESTABLISHED -j ACCEPT
    ;;

  nat)
    # Masquerade VPN traffic (NDMS _NDM_MASQ may also cover this)
    iptables -t nat -C POSTROUTING -o $VPN_IF -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o $VPN_IF -j MASQUERADE
    ;;
esac

exit 0

#!/bin/sh
# NDMS netfilter hook -> /opt/etc/ndm/netfilter.d/20-dns-split.sh
# Redirects LAN DNS (port 53) to the local dnsmasq on :5354 (DNS anti-poison).
# Inserted at position 1 of nat PREROUTING, above NDMS's own _NDM_DNS_REDIRECT.
export PATH=/opt/sbin:/opt/bin:$PATH

[ "$type" = "ip6tables" ] && exit 0
[ "$table" != "nat" ] && exit 0

LAN="192.168.1.0/24"        # must match vpn-split.sh
IP="192.168.1.1"            # router LAN IP (= listen-address in dnsmasq.conf)
P=5354

for pr in udp tcp; do
  while iptables -t nat -D PREROUTING -s $LAN -p $pr --dport 53 -j DNAT --to-destination $IP:$P 2>/dev/null; do :; done
  iptables -t nat -I PREROUTING 1 -s $LAN -p $pr --dport 53 -j DNAT --to-destination $IP:$P
done
exit 0

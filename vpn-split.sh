#!/bin/sh
# VPN Split Tunneling Script for Netcraze Ultra
# Russia IPs -> direct WAN, everything else -> VPN

VPN_IF="vpn_vpn"
VPN_IP="192.168.30.11"
VPN_GW="192.168.30.1"
LAN="192.168.2.0/24"
TABLE_ID=100
MARK=0x1
CHAIN="VPN_SPLIT"

# IPs that must ALWAYS go via WAN (VPN servers - prevent routing loop)
SE_SERVER="188.137.180.77"
AWG_SERVER="81.91.176.218"

case "$1" in
  start)
    echo "Starting VPN split tunneling..."

    # Assign IP to VPN interface if not set
    ip addr show $VPN_IF 2>/dev/null | grep -q "$VPN_IP" || \
      ip addr add ${VPN_IP}/24 dev $VPN_IF

    # IP rules (idempotent - ignore errors if already exist)
    ip rule add to $SE_SERVER table main priority 50 2>/dev/null
    ip rule add to $AWG_SERVER table main priority 51 2>/dev/null
    ip rule add fwmark $MARK table $TABLE_ID priority 100 2>/dev/null

    # Default route via VPN in table 100
    ip route replace default via $VPN_GW dev $VPN_IF table $TABLE_ID

    # FORWARD rules for VPN traffic
    iptables -C FORWARD -s $LAN -o $VPN_IF -j ACCEPT 2>/dev/null || \
      iptables -I FORWARD 1 -s $LAN -o $VPN_IF -j ACCEPT
    iptables -C FORWARD -i $VPN_IF -d $LAN -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
      iptables -I FORWARD 2 -i $VPN_IF -d $LAN -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Create mangle chain for split tunneling
    iptables -t mangle -N $CHAIN 2>/dev/null
    iptables -t mangle -F $CHAIN

    # Russia IPs -> RETURN (no mark -> goes via WAN)
    iptables -t mangle -A $CHAIN -m set --match-set russia dst -j RETURN
    # VPN servers -> RETURN
    iptables -t mangle -A $CHAIN -d $SE_SERVER -j RETURN
    iptables -t mangle -A $CHAIN -d $AWG_SERVER -j RETURN
    # Everything else -> mark for VPN
    iptables -t mangle -A $CHAIN -j MARK --set-mark $MARK

    # Hook into PREROUTING for LAN traffic
    iptables -t mangle -C PREROUTING -s $LAN -j $CHAIN 2>/dev/null || \
      iptables -t mangle -A PREROUTING -s $LAN -j $CHAIN

    # NAT/masquerade for VPN traffic
    iptables -t nat -C POSTROUTING -o $VPN_IF -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -o $VPN_IF -j MASQUERADE

    echo "VPN split tunneling started."
    ;;

  stop)
    echo "Stopping VPN split tunneling..."

    # Remove mangle rules
    iptables -t mangle -D PREROUTING -s $LAN -j $CHAIN 2>/dev/null
    iptables -t mangle -F $CHAIN 2>/dev/null
    iptables -t mangle -X $CHAIN 2>/dev/null

    # Remove FORWARD rules
    iptables -D FORWARD -s $LAN -o $VPN_IF -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i $VPN_IF -d $LAN -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

    # Remove NAT
    iptables -t nat -D POSTROUTING -o $VPN_IF -j MASQUERADE 2>/dev/null

    # Remove ip rules
    ip rule del fwmark $MARK table $TABLE_ID 2>/dev/null
    ip rule del to $SE_SERVER table main 2>/dev/null
    ip rule del to $AWG_SERVER table main 2>/dev/null

    # Remove VPN route
    ip route del default table $TABLE_ID 2>/dev/null

    echo "VPN split tunneling stopped."
    ;;

  status)
    echo "=== IP RULES ==="
    ip rule list
    echo "=== VPN ROUTE TABLE ==="
    ip route show table $TABLE_ID 2>/dev/null
    echo "=== MANGLE CHAIN ==="
    iptables -t mangle -L $CHAIN -n -v 2>/dev/null
    echo "=== FORWARD VPN ==="
    iptables -L FORWARD -n -v --line-numbers 2>/dev/null | head -5
    echo "=== NAT ==="
    iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep $VPN_IF
    echo "=== VPN INTERFACE ==="
    ip addr show $VPN_IF 2>/dev/null | grep inet
    ;;

  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac

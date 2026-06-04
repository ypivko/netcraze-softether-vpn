# Russia IP address-list (RouterOS)

`russia.rsc` — `/ip/firewall/address-list` add-commands for the `russia` list
(~11.4k CIDR ranges). Used by MikroTik split-tunneling: traffic to these IPs
bypasses the VPN and goes directly via WAN.

## Использование на роутере
```
/tool/fetch url="https://raw.githubusercontent.com/ypivko/netcraze-softether-vpn/main/lists/russia.rsc" dst-path=usb1/russia.rsc
/ip/firewall/address-list/remove [find list=russia]
/import usb1/russia.rsc
```

Снимок выгружен с RB4011 (2026-06-04). Для свежести периодически перегенерировать из RIPE delegated stats.

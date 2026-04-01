# Диагностический план: Netcraze + SoftEther VPN + Split Tunneling

## Контекст

Netcraze Ultra NC-1812 (NDMS 5.0.8, aarch64) с SoftEther VPN и split tunneling через ipset+mangle.
Архитектура: LAN 192.168.2.0/24 → Netcraze → [россия → WAN / всё остальное → vpn_vpn → NL VPS 188.137.180.77].
NDMS периодически пересоздаёт iptables, hook в `/opt/etc/ndm/netfilter.d/10-vpn-split.sh` восстанавливает правила.

---

## Блок 1: Быстрый общий статус (начинать здесь)

```sh
sshpass -p 'keenetic' ssh -p222 root@192.168.2.1 '
echo "=== VPN interface ===" && ip addr show vpn_vpn 2>/dev/null || echo "vpn_vpn MISSING"
echo "=== table 100 ===" && ip route show table 100 2>/dev/null || echo "EMPTY"
echo "=== ip rules ===" && ip rule show | grep -E "50|51|100|1152"
echo "=== ipset ===" && echo "entries: $(ipset list russia 2>/dev/null | grep -c "^[0-9]")"
echo "=== fastnat ===" && cat /proc/sys/net/netfilter/nf_conntrack_fastnat 2>/dev/null
echo "=== mangle PREROUTING ===" && iptables -t mangle -L PREROUTING -n 2>/dev/null | grep -v NDM | grep -v Chain | grep -v target
echo "=== VPN ping ===" && ping -c1 -W3 192.168.30.1 >/dev/null 2>&1 && echo "OK" || echo "FAIL"
'
```

**Что ожидать при нормальной работе:**
- `vpn_vpn`: UP, inet 192.168.30.11/24
- `table 100`: `default via 192.168.30.1 dev vpn_vpn`
- `ip rules`: правила 50 (→188.137.180.77 main), 51 (→81.91.176.218 main), 100 (fwmark 0x1 → 100)
- `ipset entries`: 11250+
- `fastnat`: 0
- `mangle`: RETURN russia, RETURN 188.137.180.77, RETURN 81.91.176.218, MARK 0x1
- `VPN ping`: OK

---

## Блок 2: VPN не работает / vpn_vpn отсутствует

### 2.1 Проверка состояния SoftEther клиента
```sh
/opt/bin/vpncmd /CLIENT localhost /CMD AccountStatusGet conn1
/opt/bin/vpncmd /CLIENT localhost /CMD AccountList
```
→ `Session Status: Connected` — VPN работает
→ `Session Status: Disconnected` — VPN упал, нужен реконнект

### 2.2 Принудительный реконнект
```sh
/opt/bin/vpncmd /CLIENT localhost /CMD AccountDisconnect conn1
sleep 3
/opt/bin/vpncmd /CLIENT localhost /CMD AccountConnect conn1
sleep 10
ip addr show vpn_vpn
```

### 2.3 Полный рестарт сплит-туннелинга
```sh
/opt/etc/init.d/S99vpnsplit restart
```

### 2.4 Проверить что vpnclient вообще запущен
```sh
ps | grep vpnclient
```
→ Нет процесса: `/opt/etc/init.d/S05vpnclient start`

### 2.5 Проверить лог watchdog
```sh
tail -50 /opt/var/log/vpn-watchdog.log
```

---

## Блок 3: Маршрутизация сломана (таблица 100 пустая)

Симптом: VPN интерфейс есть, ping 192.168.30.1 работает, но сайты идут через WAN.

### 3.1 Проверка
```sh
ip route show table 100
# Должно быть: default via 192.168.30.1 dev vpn_vpn
```

### 3.2 Исправление (добавить маршрут)
```sh
ip route replace default via 192.168.30.1 dev vpn_vpn table 100
ip route show table 100
```

### 3.3 Проверить ip rules
```sh
ip rule show
# Должны быть:
#  50: from all to 188.137.180.77 lookup main
#  51: from all to 81.91.176.218 lookup main
#  100: from all fwmark 0x1 lookup 100
```
→ Если нет правила 100:
```sh
ip rule add fwmark 0x1 table 100 priority 100
```
→ Если нет правил 50/51 (VPN/AWG серверы не идут через WAN):
```sh
ip rule add to 188.137.180.77 table main priority 50
ip rule add to 81.91.176.218 table main priority 51
```

### 3.4 Полное восстановление через скрипт
```sh
/opt/etc/vpn-split.sh start
```

---

## Блок 4: ipset пустой (все сайты идут через VPN или WAN неправильно)

Симптом: ipset russia = 0 entries. Мangle правило `RETURN russia` никогда не срабатывает → все сайты помечаются 0x1 → идут через VPN.

### 4.1 Проверка
```sh
ipset list russia 2>/dev/null | grep "Number of entries"
```

### 4.2 Исправление — ручная загрузка
Проблема: `ipset restore` падает если сет уже существует (строка `create russia ...` конфликтует).
```sh
ipset flush russia 2>/dev/null
ipset restore -exist < /opt/etc/russia.ipset
ipset list russia | grep "Number of entries"
```

### 4.3 Если сет не существует совсем
```sh
ipset restore < /opt/etc/russia.ipset
```

### 4.4 Проверить файл
```sh
wc -l /opt/etc/russia.ipset
head -3 /opt/etc/russia.ipset
tail -3 /opt/etc/russia.ipset
# Первая строка должна быть: create russia hash:net hashsize 16384 maxelem 32768
# Далее: add russia X.X.X.X/XX
```

---

## Блок 5: Сайт открывается через неправильный путь (VPN или WAN)

### 5.1 Определить IP сайта
```sh
nslookup example.com 8.8.8.8
# Взять IP из ответа
```

### 5.2 Проверить — в russia ipset или нет
```sh
ipset test russia <IP>
# "is in set russia" → идёт через WAN (прямой)
# "is NOT in set russia" → идёт через VPN (NL)
```

### 5.3 Добавить IP в список russia (чтобы шёл через WAN)
```sh
ipset add russia <IP>
echo "add russia <IP>" >> /opt/etc/russia.ipset
```

### 5.4 Удалить IP из списка russia (чтобы шёл через VPN)
```sh
ipset del russia <IP>
# Из файла: отредактировать /opt/etc/russia.ipset и удалить строку
```

### 5.5 Проверить реальный путь пакета
```sh
# Какой IP видит сайт — VPN или WAN?
curl -m5 -s http://ifconfig.me         # через WAN (трафик роутера без метки)
curl -m5 -s --interface vpn_vpn http://ifconfig.me  # через VPN
# Реальный exit-IP для конкретного хоста:
traceroute -m 5 -n <IP>
```

---

## Блок 6: Страницы подвисают на 2-3 секунды перед загрузкой

Возможные причины и диагностика:

### 6.1 DNS-задержка (самая вероятная причина)
Если DNS-запросы идут через VPN (8.8.8.8 → VPN туннель → NL → ответ), добавляется RTT VPN.

```sh
# Замерить время DNS резолвинга
time nslookup google.com 127.0.0.1    # через NDMS resolver
time nslookup google.com 8.8.8.8      # напрямую через VPN

# Проверить, какой DNS получают клиенты
cat /etc/dnsmasq.conf 2>/dev/null | grep server
# или в NDMS: смотреть настройки DNS в веб-интерфейсе
```

→ Если DNS медленный через VPN: настроить локальный DNS (1.1.1.1 напрямую для российских доменов, через VPN для остальных) — это Phase 8 из плана.

### 6.2 NDMS rebuild iptables в фоне (кратковременные обрывы)
```sh
# Смотреть частоту вызовов хука:
cat /tmp/hook.log 2>/dev/null | tail -20
# Много rebuild событий → NDMS нестабилен (флаппинг интерфейса)
```

→ Проверить: `ip link show` — нет ли интерфейсов в UP/DOWN состоянии.

### 6.3 MTU / фрагментация
SoftEther TCP/443 добавляет overhead. MSS 1200 должен это покрывать, но если нет:

```sh
# Проверить MTU на vpn_vpn
ip link show vpn_vpn | grep mtu

# Тест на фрагментацию (большой пинг без фрагментации)
ping -M do -s 1400 -c3 192.168.30.1  # через VPN
ping -M do -s 1400 -c3 8.8.8.8 -I vpn_vpn
# Если "Frag needed" → уменьшить MSS
```

→ Изменить MSS в `/opt/etc/vpn-split.sh`:
```sh
# Найти строку set-mss 1200, уменьшить до 1180 или 1160
iptables -t mangle -R POSTROUTING <NUM> -o vpn_vpn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1180
```

### 6.4 fastnat был включён (уже происходило ранее)
```sh
cat /proc/sys/net/netfilter/nf_conntrack_fastnat
# 1 = включён → сбрасывает TCP-соединения после ~50KB
echo 0 > /proc/sys/net/netfilter/nf_conntrack_fastnat
echo 0 > /proc/sys/net/netfilter/nf_conntrack_fastroute
echo 0 > /proc/sys/net/hwnat/extif_offload
```

### 6.5 Conntrack переполнен
```sh
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max
# Если count > 80% от max → соединения дропаются
```

---

## Блок 7: Полный сброс и перезапуск

Когда всё остальное не помогает:

```sh
# Полный сброс сплит-туннелинга
/opt/etc/vpn-split.sh stop
/opt/etc/init.d/S99vpnsplit stop

# Пауза
sleep 3

# Полный запуск
/opt/etc/init.d/S99vpnsplit start

# Проверить
/opt/etc/vpn-split.sh status
```

---

## Блок 8: Добавление сайта в исключения (постоянно)

Например, если сайт X должен идти напрямую (через WAN):

```sh
IP=$(nslookup X.ru 8.8.8.8 | grep "Address" | tail -1 | awk '{print $2}')
echo "IP сайта: $IP"
ipset add russia $IP
echo "add russia $IP" >> /opt/etc/russia.ipset
```

> Примечание: CDN-сайты (CloudFront, Akamai) могут менять IP. Для надёжного исключения нужен DNS-based split tunneling (Phase 8).

---

## Блок 9: Сброс настроек — что НЕ трогать

При сбросе настроек Netcraze через веб-интерфейс:
- **НЕ сбрасывать** — Entware `/opt/` сохраняется на USB/flash
- **Сбрасывается** — NDMS config (Wi-Fi, LAN settings, DHCP)
- После сброса: Entware запускается автоматически (S05vpnclient, S99vpnsplit)
- Проверить после сброса: `ip link show vpn_vpn` — должен появиться через ~30с после загрузки

---

## Блок 10: Быстрые команды-справочник

| Задача | Команда |
|--------|---------|
| Статус одной строкой | `/opt/etc/vpn-split.sh status` |
| Включить VPN сплит | `/opt/etc/vpn-split.sh start` |
| Выключить VPN сплит | `/opt/etc/vpn-split.sh stop` |
| Полный рестарт | `/opt/etc/init.d/S99vpnsplit restart` |
| Лог watchdog | `tail -50 /opt/var/log/vpn-watchdog.log` |
| Лог NDMS хука | `cat /tmp/hook.log` |
| Обновить russia-list | `/opt/etc/update-russia-list.sh` |
| Добавить IP в russia | `ipset add russia <IP> && echo "add russia <IP>" >> /opt/etc/russia.ipset` |
| Проверить IP сайта | `ipset test russia $(nslookup site.ru 8.8.8.8 \| grep Address \| tail-1 \| awk '{print $2}')` |
| Отключить fastnat | `echo 0 > /proc/sys/net/netfilter/nf_conntrack_fastnat` |

---

## Известные проблемы

| Проблема | Причина | Решение |
|----------|---------|---------|
| ipset пустой после NDMS rebuild | `ipset restore` падает на строке `create` если сет существует | Использовать `ipset flush + ipset restore -exist` |
| table 100 пустая после NDMS rebuild | Хук восстанавливает только iptables, не ip rules/routes | `ip route replace default via 192.168.30.1 dev vpn_vpn table 100` |
| Страницы тормозят 2-3с | DNS через VPN, или кратковременный rebuild iptables | DNS split tunneling (Phase 8) |
| Сайт блокирует (77.37.130.220) | IP сайта в russia ipset → идёт через WAN, но VPN был нужен | `ipset del russia <IP>` |
| Сайт блокирует (голландский IP) | IP сайта НЕ в russia ipset → идёт через VPN | `ipset add russia <IP>` |
| Connection reset после ~50KB | fastnat=1 (NDMS сбросил на default) | `echo 0 > /proc/sys/net/netfilter/nf_conntrack_fastnat` |

---

## Верификация после любых изменений

```sh
# 1. Проверить путь не-российского сайта (должен быть NL IP):
curl -s -m5 https://2ip.ru
# → должен показать НЕ 77.37.130.220

# 2. Проверить путь российского сайта (должен быть WAN IP):
curl -s -m5 http://ifconfig.me
# → 77.37.130.220 (российский WAN)

# 3. Госуслуги открываются:
curl -v -m5 -o/dev/null https://gosuslugi.ru 2>&1 | grep "HTTP/"

# 4. Скорость через VPN (быстрый тест):
curl -m10 -o /dev/null https://speed.cloudflare.com/__down?bytes=5000000 2>&1 | grep -E "speed|transferred"
```

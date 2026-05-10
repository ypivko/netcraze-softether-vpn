#!/bin/sh
# Update Russia IP list from RIPE
# Works with or without python3 (shell fallback for MIPS routers with limited storage)
LOG="/opt/var/log/russia-update.log"
TMP="/tmp/ru_data.json"
IPSET_OUT="/tmp/russia_new.ipset"

curl -s "https://stat.ripe.net/data/country-resource-list/data.json?resource=RU" -o "$TMP" 2>&1
if [ $? -ne 0 ] || [ ! -s "$TMP" ]; then
    echo "$(date): curl failed" >> $LOG
    rm -f "$TMP"
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    # Fast path: python3 available
    python3 << 'PYEOF'
import json
with open("/tmp/ru_data.json") as f:
    data = json.load(f)
prefixes = data["data"]["resources"]["ipv4"]
with open("/tmp/russia_new.ipset", "w") as out:
    out.write("create russia hash:net hashsize 16384 maxelem 32768\n")
    for p in prefixes:
        out.write("add russia " + p + "\n")
print("Generated " + str(len(prefixes)) + " prefixes")
PYEOF
else
    # Shell fallback: grep CIDR prefixes from JSON (no python3 needed)
    grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+"' "$TMP" | tr -d '"' > /tmp/ru_prefixes.txt
    COUNT=$(wc -l < /tmp/ru_prefixes.txt)
    if [ "$COUNT" -lt 5000 ]; then
        echo "$(date): too few prefixes ($COUNT), skipping" >> $LOG
        rm -f "$TMP" /tmp/ru_prefixes.txt
        exit 1
    fi
    echo "create russia hash:net hashsize 16384 maxelem 32768" > "$IPSET_OUT"
    while read prefix; do
        echo "add russia $prefix"
    done < /tmp/ru_prefixes.txt >> "$IPSET_OUT"
    rm -f /tmp/ru_prefixes.txt
    echo "Generated $COUNT prefixes"
fi

if [ -s "$IPSET_OUT" ]; then
    ipset flush russia 2>/dev/null
    ipset destroy russia 2>/dev/null
    ipset restore < "$IPSET_OUT"
    cp "$IPSET_OUT" /opt/etc/russia.ipset
    echo "$(date): Russia list updated" >> $LOG
fi

rm -f "$TMP" "$IPSET_OUT"

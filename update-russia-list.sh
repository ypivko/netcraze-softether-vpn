#!/bin/sh
LOG="/opt/var/log/russia-update.log"
curl -s "https://stat.ripe.net/data/country-resource-list/data.json?resource=RU" -o /tmp/ru_data.json 2>&1
if [ $? -eq 0 ] && [ -s /tmp/ru_data.json ]; then
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
    if [ -s /tmp/russia_new.ipset ]; then
        ipset flush russia 2>/dev/null
        ipset destroy russia 2>/dev/null
        ipset restore < /tmp/russia_new.ipset
        cp /tmp/russia_new.ipset /opt/etc/russia.ipset
        echo "$(date): Russia list updated" >> $LOG
    fi
    rm -f /tmp/ru_data.json /tmp/russia_new.ipset
fi

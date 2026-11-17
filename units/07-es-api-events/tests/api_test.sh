#!/bin/bash
# /addgames reset test against a running ES (container only).
show() { curl -s http://127.0.0.1:1234/systems/gb/games | python3 -c 'import json,sys
for g in json.load(sys.stdin):
    print("  %-10s favorite=%s lastplayed=%s playcount=%s" % (g.get("name"), g.get("favorite"), g.get("lastplayed"), g.get("playcount")))'; }
echo "before:"; show
code=$(curl -s -o /tmp/addgames.out -w '%{http_code}' -H 'Content-Type: application/xml' --data-binary \
 '<?xml version="1.0"?><gameList><game><path>./Alpha.gb</path><favorite>false</favorite><lastplayed>0</lastplayed></game></gameList>' \
 http://127.0.0.1:1234/addgames/gb)
echo "POST /addgames/gb favorite=false lastplayed=0 -> HTTP $code $(cat /tmp/addgames.out)"
sleep 1
echo "after:"; show
echo "gamelist.xml Alpha entry on disk:"
python3 -c 'import xml.etree.ElementTree as E
for g in E.parse("/userdata/roms/gb/gamelist.xml").getroot():
    if g.findtext("path")=="./Alpha.gb": print("  " + E.tostring(g, encoding="unicode").strip())'

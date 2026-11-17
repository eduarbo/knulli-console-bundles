#!/bin/bash
# Long-press X on the selected game (Alpha) to toggle its favorite; read the event log (container only).
export DISPLAY=:99
w=$(xdotool search --name . | head -1)
echo "window=$w name=$(xdotool getwindowname $w 2>/dev/null)"
xdotool windowfocus --sync $w 2>/dev/null || xdotool windowfocus $w
sleep 1
toggle() { xdotool keydown x; sleep 1.5; xdotool keyup x; sleep 2; }
fav() { curl -s http://127.0.0.1:1234/systems/gb/games | python3 -c 'import json,sys
print([ (g["name"], g["favorite"]) for g in json.load(sys.stdin)])'; }
echo "before: $(fav)"
toggle; echo "after 1st long-press X: $(fav)"
toggle; echo "after 2nd long-press X: $(fav)"
echo "events logged by scripts/game-favorite-changed/log.sh:"
cat /tmp/fav-events.log 2>/dev/null || echo "  (none)"
grep -h "fireEvent: game-favorite-changed" /userdata/system/logs/es_log.txt 2>/dev/null | sed 's/^/  log: /'

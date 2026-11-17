#!/bin/bash
# Fresh fake /userdata for a headless ES run (container only).
set -e
rm -rf /userdata /usr/share/emulationstation
mkdir -p /usr/share/emulationstation /userdata/system/configs/emulationstation/scripts/game-favorite-changed \
         /userdata/system/logs /userdata/roms/gb /userdata/themes/mini
cp -r /src/resources /usr/share/emulationstation/resources
cat > /userdata/system/configs/emulationstation/es_systems.cfg <<'X'
<?xml version="1.0"?>
<systemList>
  <system>
    <name>gb</name>
    <fullname>Game Boy</fullname>
    <path>/userdata/roms/gb</path>
    <extension>.gb</extension>
    <command>true %ROM%</command>
    <platform>gb</platform>
    <theme>gb</theme>
  </system>
</systemList>
X
: > "/userdata/roms/gb/Alpha.gb"
: > "/userdata/roms/gb/Beta Game.gb"
cat > /userdata/roms/gb/gamelist.xml <<'X'
<?xml version="1.0"?>
<gameList>
  <game><path>./Alpha.gb</path><name>Alpha</name><favorite>true</favorite><lastplayed>20261101T101010</lastplayed><playcount>3</playcount></game>
  <game><path>./Beta Game.gb</path><name>Beta Game</name></game>
</gameList>
X
cat > /userdata/themes/mini/theme.xml <<'X'
<theme><formatVersion>7</formatVersion>
<view name="system"><carousel name="systemcarousel"/></view>
<view name="basic"><textlist name="gamelist"/></view>
</theme>
X
cat > /userdata/system/configs/emulationstation/es_settings.cfg <<'X'
<?xml version="1.0"?>
<config>
<string name="ThemeSet" value="mini" />
<bool name="StartupOnGameList" value="true" />
<string name="StartupSystem" value="gb" />
<string name="GamelistViewStyle" value="basic" />
</config>
X
cat > /userdata/system/configs/emulationstation/es_input.cfg <<'X'
<?xml version="1.0"?>
<inputList>
  <inputConfig type="keyboard" deviceName="Keyboard" deviceGUID="-1">
    <input name="a" type="key" id="13" value="1" />
    <input name="b" type="key" id="27" value="1" />
    <input name="x" type="key" id="120" value="1" />
    <input name="y" type="key" id="121" value="1" />
    <input name="up" type="key" id="1073741906" value="1" />
    <input name="down" type="key" id="1073741905" value="1" />
    <input name="left" type="key" id="1073741904" value="1" />
    <input name="right" type="key" id="1073741903" value="1" />
    <input name="start" type="key" id="1073741882" value="1" />
    <input name="select" type="key" id="1073741883" value="1" />
  </inputConfig>
</inputList>
X
cat > /userdata/system/configs/emulationstation/scripts/game-favorite-changed/log.sh <<'X'
#!/bin/sh
printf '%s|%s|%s\n' "$1" "$2" "$3" >> /tmp/fav-events.log
X
chmod +x /userdata/system/configs/emulationstation/scripts/game-favorite-changed/log.sh
rm -f /tmp/fav-events.log
echo setup-ok

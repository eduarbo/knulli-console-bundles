# Intent: the ES series (eduarbo/batocera-emulationstation, onto the ES the tag ships: the commit
# it pins plus Knulli's package patches)

Six commits, in order:
1. /addgames applies default metadata values for existing games: when a posted entry sets a
   field to its default (favorite=false, lastplayed=0), apply it to an existing game instead of
   skipping it (empty values are still skipped). New games behave as before.
2. Documentation only: the API summary says what /restart (reboots), /quit (ES restarts under
   emulationstation-standalone) and /removegames (deletes ROM files) do.
3. Scripting event "game-favorite-changed" with arguments: system name, game path, "true" or
   "false", fired when the favorite changes from the game list (favorite button, game options
   menu) or the metadata editor; NOT for changes made through the web API.
4. Volume popup readable on themes whose text colours are close: keep the theme colours when
   fill and track contrast at least 3:1, else fill with the text colour, else a quarter-opacity
   track.
5. Brightness popup next to the volume one (same frame, bar, label, timing), reading
   /sys/class/backlight or the Allwinner /dev/disp driver; only user changes show it (not the
   battery saver's dim/restore, not after a gap of more than 1 s between reads); follows the
   "show overlay when volume changes" setting.
6. knulli.conf, es_settings.cfg, gamelist.xml and the recovery files are written atomically
   (temporary file in the same folder, same mode and owner, fsync, rename, fsync of the
   folder; symlinks keep pointing to the new file); saveSystemConf holds the
   /var/run/knulli-settings-set.lock flock from reading to replacing (at most 2 s).

Invariants for a resolution:
- Keep every upstream change (Knulli's package patches included); re-express each fix on top
  of the new code with the same observable behaviour, names, arguments, paths and settings. If
  upstream already does one of these (same behaviour), drop that commit instead of duplicating
  it.
- No new network access, files, settings or dependencies. The result must build with the
  existing CMake options (GLES2, BATOCERA, KNULLI) and pass unit 07's API and UI tests.

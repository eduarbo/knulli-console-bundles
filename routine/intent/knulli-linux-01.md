# Intent: group 01, /usr/bin/knulli-suspend (board/fsoverlay/usr/bin/knulli-suspend)

What the fix does (two commits of the series):
1. While suspended, arm the RTC alarm for the soonest of: the battery-saver shutdown timer
   (upstream behaviour, keep it), `system.suspend.shutdowntimer` (seconds; 0 = never; unset =
   10800) and the time the battery needs to reach `system.suspend.shutdownbattery` (percent;
   0 = off; unset = 5) at 6 %/h while discharging. On the alarm, resume whatever the battery
   saver paused, then shut down with `knulli-shutdown -s` (the power menu's path), so a game
   gets SIGTERM while running and can save. Log decisions to /var/log/knulli-suspend.log.
2. Arm the suspend timer only while discharging and when no game is open or the only one is
   RetroArch (it saves SRAM and its auto state on SIGTERM). The battery floor applies whenever
   discharging. Log which rule armed the alarm, or why the timer was skipped.

Invariants for a resolution:
- Keep every upstream change to the file; put the two behaviours above on top of it. When
  upstream changed the same lines, merge both meanings on those lines.
- Same setting names, defaults, units and log path. No new settings, files or network use.
- A suspend must never be blocked or delayed by this code; a failure to arm the alarm must
  leave the stock suspend working.
- Shell: /bin/sh (dash) compatible, as the original file.

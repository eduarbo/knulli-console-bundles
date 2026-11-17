# Intent: group 03, battery saver with holds
Paths: board/fsoverlay/usr/bin/knulli-aggressive-saver, board/fsoverlay/etc/idlewatcher/idle.d/01idle-hooks,
board/fsoverlay/etc/idlewatcher/active.d/01active-hooks, the scraper-start/stop scripts under
board/fsoverlay/usr/share/emulationstation/scripts.

What the fix does (two commits):
1. The aggressive battery saver (SIGSTOP of EmulationStation and emulators, CPU governor to
   powersave when the screen dims) lives in /usr/bin/knulli-aggressive-saver with a lock, a
   state file and "only resume what it stopped". Background tools can hold ES awake:
   `knulli-aggressive-saver run NAME -- CMD`, `hold NAME [PID]`, `release NAME`; a hold whose
   process is gone is dropped; paused games stay paused; `state` reports "frozen" (exit 3)
   while ES is stopped; /var/run/emulationstation.suspended holds ES's process group then.
   The idle and active hooks call the saver and keep their inline code as the fallback.
   The scraper hooks create/remove /var/run/battery-saver/scraper.pause (the folder the saver
   reads), not /var/run/batterysaver.
2. ES is stopped only by a detached worker (own session) that decides under the lock, stops
   ES outside it and undoes the stop if a hold or "off" came in meanwhile; "off" resumes
   everything even when it cannot get the lock (then exits 1), and the active hook falls
   back to the stock undo when "off" fails.

Invariants for a resolution:
- If upstream now ships its own knulli-aggressive-saver (Knulli development does), keep
  upstream's file and behaviour and add only the holds, the detached freeze and the lock
  handling on top; do not reintroduce code upstream removed.
- Keep every upstream change in the hooks; the hooks only gain the call to the saver with
  the inline fallback.
- Bash, as the original files. No new settings, no network.

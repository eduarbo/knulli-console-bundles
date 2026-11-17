#!/bin/sh
# EmulationStation scraper-start hook (user copy). Knulli's own hook writes
# /var/run/batterysaver, a folder the battery saver never reads, so a long
# scrape could be frozen by it; create the pause where the saver looks.
mkdir -p /var/run/battery-saver
touch /var/run/battery-saver/scraper.pause
exit 0

# knulli-console-bundles

Signed bundles of firmware-tied fixes for one Anbernic RG35XX-H running Knulli. When
[knulli-cfw/knulli-linux](https://github.com/knulli-cfw/knulli-linux) publishes a release,
`.github/workflows/console-bundle.yml`:

1. finds the release's `knulli-h700-rg35xx-h-*.img.gz` (sha256 checked against GitHub's digest);
2. carries the fix series of
   [eduarbo/knulli-linux](https://github.com/eduarbo/knulli-linux) and
   [eduarbo/batocera-emulationstation](https://github.com/eduarbo/batocera-emulationstation)
   (read over git; their Actions stay off) onto the new tag and the ES it ships (the ES
   commit it pins plus Knulli's ES package patches, applied as Buildroot does): an
   owner branch `knulli-<tag>-fixes`, else the resolved series of the last complete bundle
   (tag `series/<tag>`), else the original series; a conflict uses the reviewed patch files
   of `claude/resolution-<tag>` (written by a daily routine, read here as data only);
   `pipeline/gate.py` checks every result;
3. rebuilds EmulationStation and ConnMan against the release image's own libraries, runs unit
   07's API/UI tests headless, re-pins the firmware-tied units in `units/` and runs their tests;
4. checks every bundle file against its template, scans for private data, signs the manifest
   (Ed25519, environment `bundle-signing`, public key in `keys/`), attests the build provenance
   and publishes release `bundle-<firmware>`; a complete bundle also publishes `series/<tag>`.

The console's `fix_updater` service caches the next firmware's bundle before an update, then
installs each unit with its own `install.sh`, checks it, and rolls it back on failure.

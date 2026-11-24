# KNULLI console bundles

## Canica on the RG35XX H

This repository provides the ARM64 build tools and the recovery service. [Canica](https://github.com/eduarbo/canica) uses the [KNULLI fork](https://github.com/eduarbo/knulli-linux) for firmware integration, and the [EmulationStation fork](https://github.com/eduarbo/batocera-emulationstation) for navigation, search and video previews. Start with the handheld kit to install Iris or Amber.

[See Canica on the handheld](https://github.com/eduarbo/canica) · [Install it and restore the stock menu](https://github.com/eduarbo/canica/blob/main/docs/canica-rg35xx-h.md) · [Build using the pinned tools](https://github.com/eduarbo/canica/tree/main/tools/canica)

The signed bundle for Scarab `20260511` included the earlier 110-patch frontend. The RC27.1 frontend series grew to 125 patches. RC30 and later use the frontend revision pinned in the installation guide. The kit is a release of the Canica repository. [Signed Scarab bundle](https://github.com/eduarbo/knulli-console-bundles/releases/tag/bundle-scarab-2026-05-11-00-09)

## Firmware fix bundles

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

## Canica kit updates

The same key signs a second channel: release `canica-<firmware slug>` holds the Canica kit the
console installs next. `canica/kit.env` on `main` pins that installer, a release asset of
[eduarbo/canica](https://github.com/eduarbo/canica), by size and SHA-256. When the pin changes,
`.github/workflows/canica-kit.yml` checks the download against it, proves that the published
kit upgrades to the new one, signs a manifest of kind `canica-kit` and publishes it. On the
console, `canica_updater` verifies the manifest with the key it already trusts for the fixes,
runs the kit's own installer while the menu is free, restarts the menu and says each step on
screen. `fix_updater` refuses that kind of manifest, and `canica_updater` refuses every other.

## License

My code in this repository is released under the [MIT License](LICENSE). Files derived from KNULLI or ConnMan sources keep those projects' licenses: the stock scripts used as test fixtures, the patched versions the units install, and the ConnMan patch.

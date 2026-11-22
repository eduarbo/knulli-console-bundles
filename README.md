# knulli-console-bundles

## Instalar Canica en la RG35XX H

Este repositorio proporciona el compilador para Scarab y las herramientas de instalación y recuperación. El [fork de KNULLI](https://github.com/eduarbo/knulli-linux) integra el motor y el adaptador de partidas. El [fork de EmulationStation](https://github.com/eduarbo/batocera-emulationstation) implementa los controles, las vistas previas y la búsqueda usados por el tema. Para **Iris o Ámbar**, empieza por la guía de la candidata. Incluye la ruta sin compilar, la alternativa desde fuentes y cómo volver al menú original. [Instalar Canica en una Anbernic RG35XX H](https://github.com/eduarbo/knulli-linux/blob/main/docs/canica-rg35xx-h.md).

El último bundle firmado para Scarab `20260511` incorporó la serie de 110 parches del menú. Canica RC27.1 usa una serie de 125 y obtiene el tema por separado. [Contenido del bundle de Scarab](https://github.com/eduarbo/knulli-console-bundles/releases/tag/bundle-scarab-2026-05-11-00-09)

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

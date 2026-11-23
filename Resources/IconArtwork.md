# App icon artwork

Arcane Portal's icon is derived from Arcane's (`Bium23/NxLibrary`, MIT; see `NOTICE`). Arcane's owner
created that artwork with AI: a violet, rose and blue crystal inside a clear glass sphere, framed by a navy
and a plum ink brush stroke on light paper, with a plum ink wave inside the sphere.

`scripts/make_portal_artwork.py` turns it into `IconArtwork.png`, the full-bleed 1254 × 1254 square master:
the navy stroke becomes teal, the plum ink violet, and a glowing portal with a swirl opens behind the crystal.
The script's header has the exact commands. The source is opaque and has no pre-rendered icon frame,
transparent padding, rounded corners, rim or external shadow.

Regenerate the Finder icon and Dock appearance resources on macOS:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/make_icons.swift
```

The generator applies the macOS silhouette to the full-bleed source: an
824 × 824 rounded tile centered on a transparent 1024 × 1024 canvas, with a
restrained shadow. It downsamples this master into all ten standard iconset
representations (16–1024 pixels), packages `AppIcon.icns`, and writes the
1024-pixel Light, Dark and Monochrome Dock resources. Light and Dark share
the same tile. Monochrome preserves the geometry and alpha with a
grayscale color-space conversion. The committed resources are exactly what
this command produces from the master.

Inspect the installed app in Finder and the Dock after quitting and reopening
it; the running app can retain its previous icon until it restarts.

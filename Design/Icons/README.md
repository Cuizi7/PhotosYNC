# PhotosYNC D2 — Icon Composer source

Approved direction: D2 ribbon S, pale icy-blue to lavender background (2026-09-15).

Open `PhotosYNC.icon` in Icon Composer. The document separates an editable native diagonal background gradient from the transparent S foreground. The S includes its mountain/sun illustration and internal shading; these are not separate vector layers. The foreground was extracted using image generation from the approved raster, so it is a close reconstruction rather than a pixel-identical lossless split.

- `PhotosYNC.icon/icon.json`: native background, foreground placement and effect settings.
- `PhotosYNC.icon/Assets/S-ribbon.png`: 1254 × 1254 RGBA foreground, preserved at source resolution.
- `Source/S-ribbon.png`: original extracted foreground.
- `Previews/`: 1024 × 1024 Default, Dark and Mono exports from Apple's renderer.
- Foreground scale: 1024 / 1254; no cropped extremities.
- Native gradient: sRGB (0.945, 0.975, 0.995) to (0.960, 0.945, 0.990), top-left to bottom-right.
- Group translucency disabled to preserve the approved color; neutral shadow opacity 0.25.

Validated with Xcode's bundled Icon Composer 1.6 `ictool`, each export exited 0:

```sh
IC='/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool'
"$IC" Design/Icons/PhotosYNC.icon --export-image \
  --output-file Design/Icons/Previews/Default.png \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

Repeat with `Dark` or `Mono` for those appearances. Default and Dark have been visually inspected. Dark is the system's automatically derived dark background, not a second user-selected design.

Integrated into the app target for 0.1.0 beta. Xcode compiles Assets.car and PhotosYNC.icns from this document; the ICNS is the older-macOS fallback. Source/S-ribbon.png is the extraction reference; the Assets copy is the build input.

# App icon

Herm's icon is the MacBook notch worn like Hermes' winged helmet: gold wings
spread from a black notch with a glowing status light, on an indigo tile. It is drawn in code so it can be tweaked and rebuilt:

```sh
swift Scripts/generate-app-icon.swift Sources/Herm/Resources/DockAppIcon.png
mkdir -p /tmp/Herm.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s Sources/Herm/Resources/DockAppIcon.png --out /tmp/Herm.iconset/icon_${s}x${s}.png
  sips -z $((s*2)) $((s*2)) Sources/Herm/Resources/DockAppIcon.png --out /tmp/Herm.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns /tmp/Herm.iconset -o Sources/Herm/Resources/DockAppIcon.icns
```

The PNG is used in the notch; the ICNS goes into the signed app bundle.

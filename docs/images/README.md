# README screenshots

Rendered from production SwiftUI/AppKit views with isolated sample data, not live
device readings. No desktop capture or generated artwork.

Regenerate using a freshly compiled `build/isolated-tests` (see `test.sh`):

```sh
build/isolated-tests --compact-ui-fixtures build/readme-fixtures
build/isolated-tests --window-palette-fixtures build/readme-fixtures
build/isolated-tests --release-ui-fixtures build/readme-fixtures
cp build/readme-fixtures/popup-inactive-dark.png docs/images/quick-actions.png
cp build/readme-fixtures/status-quick-menu-dark.png docs/images/quick-menu.png
cp build/readme-fixtures/window-palette-full-dark.png docs/images/window-actions.png
cp build/readme-fixtures/battery-charging-1000-dark.png docs/images/battery.png
```

The compact fixtures also render the update prompt in light and dark appearance
as `popup-update-light.png` and `popup-update-dark.png`.

# Fix macOS

A macOS menu-bar app for managing monitors, Bluetooth connections, and desktop switching.

## Features

- **Monitor switching:** turn individual screens on or off, with a 20-second restore countdown.
- **Display arrangement:** drag screens into place, preview changes, and close gaps when a monitor goes off. Keep your remaining screens in a familiar layout.
- **Bluetooth reconnect:** choose devices to reconnect, connect or disconnect on demand, and protect other audio connections.
- **Fast Space switching:** shorten horizontal trackpad transitions between desktops.

Enable or disable each module from the **gear icon**. Disabled modules stop background work and release their state; your settings stay saved.

## Build and run

Requires Apple Silicon, macOS 15+, Xcode Command Line Tools, and Homebrew.

```sh
brew install blueutil switchaudio-osx
bash build.sh
open "build/Fix macOS.app"
```

Grant Bluetooth access for device management and Accessibility access for trackpad switching. Enable **Launch at login** if you want it to start with your Mac.

Display changes last for the current login session. Display and gesture features use private macOS APIs; see the [validation notes](VALIDATION.md) for known limitations.

Run the isolated checks with `bash test.sh`.

## Credits

Thanks to these MIT-licensed projects and their authors:

- [strafe](https://github.com/rileycx/strafe) by Riley Hennigh: the embedded Space-switching engine.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) by jurplel: the original instant-switching technique behind strafe.
- [blueutil](https://github.com/toy/blueutil): Bluetooth device control.
- [switchaudio-osx](https://github.com/deweller/switchaudio-osx) by Devon Weller: audio-output selection.

## License

[MIT](LICENSE). Upstream notices remain in [Vendor/strafe/LICENSE](Vendor/strafe/LICENSE).

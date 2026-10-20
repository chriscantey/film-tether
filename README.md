<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Resources/readme/header-dark.svg">
    <img src="Resources/readme/header-light.svg" width="830" alt="Film Tether: the app icon, a strip of 35mm film glowing orange, above the name Film Tether and the line Tethered capture for Canon EOS cameras on macOS">
  </picture>
</p>

<p align="center">
  <a href="https://filmtether.app">Website</a>
  &nbsp;&middot;&nbsp;
  <a href="https://github.com/chriscantey/film-tether/releases/latest/download/FilmTether.zip">Download</a>
  &nbsp;&middot;&nbsp;
  <a href="https://filmpositive.app">See Film Positive</a>
</p>

A small, native macOS app for tethering Canon EOS cameras over USB. It drives a Canon EOS body so you can preview and fire shots from your Mac.

I built it for my own [DSLR film-scanning rig](https://chriscantey.com/film-at-home/). My Canon EOS 7D only works with version 2 of Canon's EOS Utility, and that one doesn't behave well on recent macOS. I also wanted a bunch of extra features I wasn't getting from the other tethering apps I tried, so I built this to help me scan the way I want to scan. It's still experimental, and we're learning together which cameras it works with.

Open source, MIT, macOS 14+.

## What it does

- **Live preview.** Standard tethered live preview, straight from the camera.
- **RAW capture.** Saves the camera's RAW file straight to a folder you pick, as whatever the body produces (`.CR2` on my 7D, `.CR3` on newer bodies). The image data is never touched. The status bar shows which folder, with a pencil to change it.
- **Exposure controls.** ISO, shutter, aperture, the white balance mode and a Kelvin temperature, all from the Mac. A control grays out when the current mode makes it read-only, so aperture priority just works.
- **Focus check.** Hold Shift to punch in using the camera's sensor and confirm your focus is sharp.
- **Focus control.** Step the focus near or far in three sizes, from the buttons or the comma and period keys, or press AF (or the / key) to have the camera autofocus. Both need live view on and the lens switch on AF.
- **Work through a roll.** Focus with AF or the focus keys, hold Shift to check it, and tap Space to fire, so a roll of negatives goes quickly.
- **Live histogram.** Taken from the camera's own frame, before any of the preview adjustments below.
- **Camera clock.** When a camera connects, the app sets its clock to the Mac's time, so the capture time in each RAW matches the Mac. You can turn that off in Settings, and File > Set Camera Clock to This Mac does it whenever you want.

## Working with negatives

These came out of scanning film, which is what I built the app for. None of them changes the RAW that lands in your folder.

- **See the positive.** Invert the preview so a negative reads as the picture it will become.
- **Black and white.** Drop the color out of the preview, for black and white film.
- **Set white balance by clicking.** Click the unexposed film base and the preview corrects relative to it.
- **Rotate and mirror the preview.** Quarter turns, for when the holder can't be squared up. With medium format that happens to me a lot. Mirror flips it left to right, for film sitting emulsion side up.
- **Crop and straighten.** Auto-Crop looks for the negative and puts an adjustable box on it, and you can drag the corners and edges to fit. Dragging in the band just outside the box's handles straightens it, up to 45 degrees either way.
- **Three zoom levels.** Fit, 100%, and a 500% punch-in that uses the camera's own sensor zoom rather than upscaling a preview JPEG, so it shows real detail when you are checking focus.
- **A sidecar file for each scan.** Optionally writes an `.xmp` file next to each RAW. It records the camera the negative was shot on, the film stock, the film size and the day the roll was taken, plus the crop, straightening, rotation, mirror and white balance you had set up, so [Film Positive](https://filmpositive.app) or another app that reads it can pick up where you left off. Settings has more options for it, and the Meta switch turns it off.

## Caveats

- The 500% punch-in snaps to the nearest spot the camera can reach. Those spots were measured on my 7D, so on another body it may land a little off the zoom box.
- At 100% zoom, clicking to move the zoom box and the eyedropper are switched off. Click-to-move works at Fit, and the eyedropper at Fit or 500%.
- Autofocus has only been tried on my 7D. It waits for a signal the 7D sends when it has finished focusing, and on a body that doesn't send it, each run waits up to six seconds instead.
- Auto-Crop doesn't always find the frame edges. When it can't, it says so, and either gives you a rough box to adjust or leaves the crop for you to set by hand.
- Other cameras, or other brands, might be straightforward to add, since it's built on the open-source libgphoto2 project. You would still have to work through it with the camera in hand.

Most of this was built on my 7D, so if you try these features on another body, I'd love to hear how they work for you.

Film Tether sticks to tethered capture. Its companion app, [Film Positive](https://filmpositive.app), picks up from there and develops the negative into the picture.

## Requirements

- macOS 14 (Sonoma) or newer. Apple Silicon or Intel.
- A Canon EOS camera with USB tethering. If it has a Communication setting, set it to PTP.
- For the focus controls and autofocus, the lens switch on AF and live view on.
- libgphoto2, only if you build it yourself. The shipped app already includes it.

## Supported cameras

Tested on a Canon EOS 7D (by me), a 70D and an R5 (by contributors). That is the whole list so far. It should work with other EOS bodies that [libgphoto2 supports](http://www.gphoto.org/proj/libgphoto2/support.php), but I have not tried them. If you run it on another body, [tell me on the repo](https://github.com/chriscantey/film-tether/issues) and I will add it here.

## Contributors

People who have put work into this, and what they did. Huge thanks to everyone here.

- [@eileendarby](https://github.com/eileendarby). Canon R5 support, and most of the film-scanning preview work in 0.3.0: invert, black and white, click-to-set white balance, preview rotation, the Fit zoom mode, and the menu bar fixes. In 0.4.0, the crop box with its handles and straightening, the WB Mode picker, the fix for the status bar clock and the Live View lamp.
- [Melody Murray](https://melodymurray.com). Testing on the Canon EOS 70D, which is the only reason that body is on the supported list.

## Contributing

Pull requests and issues are both welcome, and I read all of them.

One thing worth knowing first. This repo is a published copy of a private working repo, so pull requests here get adapted by hand rather than merged directly. Your work still lands and you still get credit, in the Contributors list above and with a `Co-Authored-By` line on the commit that carries it.

## Install

[Download the latest build](https://github.com/chriscantey/film-tether/releases/latest/download/FilmTether.zip), unzip it, and open it. Older versions are on the [Releases](https://github.com/chriscantey/film-tether/releases) page.

If you let it (Settings > Updates), the app checks filmtether.app once a day for a new version. It's a standard HTTPS request with a User-Agent header like `Film Tether/0.4.0 Sparkle/2.10.0`, and nothing else. As with any web request, the server can see your IP address.

## Build from source

Two commands take you from a fresh clone to a running app.

```bash
git clone https://github.com/chriscantey/film-tether.git
cd film-tether && ./scripts/bootstrap.sh
```

The bootstrap checks for the Xcode command line tools and Homebrew, then installs libgphoto2, pkg-config, the gphoto2 command-line tool and jq with `brew bundle`, so feel free to read through it first to see what it does. It then builds, bundles, and launches the app. After that:

```bash
make run             # build, bundle, launch
make dist            # build a distributable .zip
make tests           # run the unit tests
make doctor          # diagnostics if something looks off
make patched-camlib  # build the patched camera driver from patches/
```

The bootstrap and the make targets build for Apple Silicon. On an Intel Mac, skip the bootstrap: run `brew bundle` in the repo, then add `ARCH=x86_64` to the make commands, as in `make run ARCH=x86_64`.

A source build uses Homebrew's stock camera driver unless you run `make patched-camlib` first, and then it picks up the patched one for as long as it matches your installed libgphoto2 (run it again after a `brew upgrade libgphoto2`). If you have an EOS 7D, run it before `make run` or `make dist`: without the patch, a 7D can hang at connect.

The `make dist` zip carries libgphoto2 and the libraries it needs, so it runs on a Mac without Homebrew, on the same macOS version as the Mac that built it or newer. It isn't notarized, so on another Mac you clear its quarantine flag first, and `make dist` prints how.

## Troubleshooting

### If it won't connect

Film Tether says on screen what went wrong and what to try. Most often another app is holding the camera. For me that's Preview, which I tend to leave open (Image Capture and Photos can grab it too). Close it and relaunch Film Tether. For an issue report, Help > Export Log saves the last 24 hours of the app's log to a file.

## License

MIT for this project's code. See [LICENSE](LICENSE). The app also carries libgphoto2, libusb, libexif, libintl and libltdl, which are under the LGPL, and libjpeg-turbo, under the IJG license. [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists each one with its version and source, and each release has their source archives attached. [RELINKING.md](RELINKING.md) has the steps the LGPL requires for swapping in your own builds of those libraries. Updates come through [Sparkle](https://sparkle-project.org), under the MIT license. The camera driver in the released app carries two small patches, both in [patches](patches).

Canon and EOS are trademarks of Canon Inc. This is a personal project and is not affiliated with or endorsed by Canon.

## Credits

Made with a lot of help from [my AI assistant](https://chriscantey.com/posts/2026-02-24-build-or-buy-may-have-changed/).

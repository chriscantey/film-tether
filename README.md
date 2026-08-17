# Film Tether

A small, native macOS app for tethering Canon EOS DSLRs over USB. It drives a Canon EOS body so you can preview and fire shots from your Mac.

I built it for my own DSLR film-scanning rig. My Canon EOS 7D only works with Canon's EOS Utility 2, and that one doesn't behave well on recent macOS. It works fine as a plain tether too. This is a personal project. It scratched my own itch and helped a friend with a 70D, and maybe a few other people will find it useful.

Open source, MIT, macOS 14+.

## What it does

The handful of things that actually matter for the way I use it.

- **Live preview.** Standard tethered live preview, straight from the camera. On my 7D it's a few frames per second. A newer body may be quicker.
- **RAW capture.** Saves the camera's RAW file straight to a folder you pick, untouched, under whatever type the body actually produced (`.CR2` on my 7D, `.CR3` on newer bodies).
- **Work through a roll.** Tap Space to fire a frame, so working through a roll of negatives is quick.
- **Exposure controls.** ISO, shutter, aperture, and white-balance Kelvin, all from the Mac. A control greys out when the current mode makes it read-only, so aperture priority just works.
- **Focus check.** Hold Shift to punch in using the camera's sensor and confirm your focus is sharp.
- **Focus control.** Keyboard shortcuts for stepping focus, when the conditions are right (lens set to AF, live view on).
- **Focus peaking.** An adjustable overlay that attempts to highlight what's in focus (far from perfect).
- **Live histogram.** Sampled from the frame the camera sends, before any of the preview adjustments below, so it tells you what the sensor is actually being asked to record rather than what the corrected preview looks like.

## Working with negatives

These came out of scanning film, which is what I built the app for. Every one of them changes only what you see on screen. The RAW that lands in your folder is the frame the camera shot, untouched.

- **See the positive.** Invert the preview so a negative reads as the picture it will become, which makes framing and dust a lot easier to judge.
- **Black and white.** Drop the colour out of the preview. Raw pixels off a B&W negative carry no useful colour anyway, and exposure is easier to read without it.
- **Set white balance by clicking.** Click the unexposed film base and the preview corrects relative to it. Per-channel gains rather than a colour temperature, because a film base is off-neutral on both axes and a Kelvin control can only slide between blue and amber.
- **Rotate the preview.** Quarter turns, for when the holder can't be squared up. With medium format that happens to me a lot.
- **Three zoom levels.** Fit, 100%, and a 500% punch-in that uses the camera's own sensor zoom rather than upscaling a preview JPEG, so it shows real detail when you are checking focus.
- **Provenance in the file.** Optionally writes the camera the negative was shot on and the film stock into the RAW, along with a record of the preview adjustments you had applied, so a later tool can read what you were looking at. Nothing is written unless you turn it on.

## Honest caveats

- The focus zoom works, and you can get sharp focus with it. It just doesn't always land on the exact spot you click.
- At 100% zoom, clicking to move the zoom box and using the eyedropper both land in the wrong place. Use Fit or 500% for those. It's fixed in the next release.
- Tested on a Canon EOS 7D (by me), a 70D and an R5 (by contributors). I don't know how many other EOS bodies it works with.
- Other cameras, or other brands, might be straightforward to add, since it's built on the open-source libgphoto2 project. You would still have to work through it with the camera in hand.

It sticks to one job: tethered capture. It doesn't develop RAW, correct lenses, shoot video, do time-lapse, or sync anywhere.

## Requirements

- macOS 14 (Sonoma) or newer. Apple Silicon or Intel.
- A Canon EOS DSLR with USB tethering, set to PTP mode (Menu, wrench, Communication, PTP).
- libgphoto2, only if you build it yourself. The shipped app already includes it.

## Supported cameras

Tested on a Canon EOS 7D (by me), a 70D and an R5 (by contributors). That is the whole list so far. It should work with other EOS bodies that [libgphoto2 supports](https://www.gphoto.org/proj/libgphoto2/support.php), but I have not tried them. If you run it on another body, [tell me on the repo](https://github.com/chriscantey/film-tether/issues) and I will add it here.

## Contributors

People who have put work into this, and what they did. Huge thanks to everyone here.

- [@eileendarby](https://github.com/eileendarby). Canon R5 support, and most of the film-scanning preview work in 0.3.0: invert, black and white, click-to-set white balance, preview rotation, the Fit zoom mode, and the menu bar fixes.
- [Melody Murray](https://melodymurray.com). Testing on the Canon EOS 70D, which is the only reason that body is on the supported list.

## Contributing

Pull requests and issues are both welcome, and I read all of them.

One thing worth knowing first. This repo is a published copy of a private working repo, so pull requests here get adapted by hand rather than merged directly. Your work still lands and you still get credit, in the Contributors list above and with a `Co-Authored-By` line on the commit that carries it.

## Install

Grab the latest build from [Releases](https://github.com/chriscantey/film-tether/releases), unzip it, and open it.

## Build from source

Two commands take you from a fresh clone to a running app.

```bash
git clone https://github.com/chriscantey/film-tether.git
cd film-tether && ./scripts/bootstrap.sh
```

The bootstrap installs things on your Mac (Homebrew if you don't already have it, plus libgphoto2 and pkg-config), so feel free to read through it first to see what it does. It then builds, bundles, and launches the app. After that:

```bash
make run             # build, bundle, launch
make dist            # build a distributable .zip
make dist-universal  # universal build (arm64 + x86_64), macOS 14+
make tests           # run the unit tests
make doctor          # diagnostics if something looks off
```

The `make dist` zip vendors libgphoto2, so it runs on a Mac without Homebrew.

### If it won't connect

Usually libgphoto2 wins the USB claim and Film Tether connects on the first try. When it doesn't, it's almost always another app already holding the camera. For me that's Preview, which I tend to leave open (Image Capture and Photos can grab it too). Close it and relaunch Film Tether.

## License

MIT for this project's code. See [LICENSE](LICENSE). It dynamically links libgphoto2, which is LGPL 2.1 or later. See [RELINKING.md](RELINKING.md) for the relink steps the LGPL requires.

Canon and EOS are trademarks of Canon Inc. This is a personal project and is not affiliated with or endorsed by Canon.

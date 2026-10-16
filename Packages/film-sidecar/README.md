# FilmSidecar

The sidecar file that Film Tether (the scanner) and Film Positive (the developer) both read and write: `<base>.xmp` next to the image, following Adobe's naming with the image extension dropped, so `IMG_0001.CR2` gets `IMG_0001.xmp`. This package reads and writes only that file. Film Tether also has a setting, "Write metadata into the RAW file", that embeds the packet in a classic little-endian TIFF raw such as CR2 instead and removes the sidecar. Other raws, such as CR3, keep the sidecar.

The format is plain XMP. Each app keeps its own fields in its own namespace, the values both apps edit live once in a shared namespace, and files written by Film Tether 0.3.0 still read.

## Namespaces

| namespace | prefix | owner | holds |
|---|---|---|---|
| `http://ns.adobe.com/tiff/1.0/`, `http://analogexif.sourceforge.net/ns`, `http://purl.org/dc/elements/1.1/` | `tiff`, `AnalogExif`, `dc` | Tether at capture. Positive changes the camera and film fields only when a person corrects them | `tiff:Model` (the full camera name), `tiff:Make`, `AnalogExif:Film`, `AnalogExif:FilmMaker`, and Tether's `dc:subject` keyword and `dc:description` caption. Standard fields, so other XMP tools can read them |
| `https://github.com/chriscantey/film-sidecar/ns/1.0/` | `Film` | shared | `Version`, `SourceName`, `SourceSize`, `SourceMTime`, `SourceFingerprint`, `Rotate`, `Flip`, `StraightenDeg`, `CropX/Y/W/H`, `BaseSampleX/Y`, `FilmSizeID`, `FilmSizeName`, `ScannerMake`, `ScannerModel`, `CapturedAt`, `TakenOn`. One copy of every value both apps edit |
| `https://github.com/chriscantey/film-tether/ns/1.0/` | `FilmTether` | Tether | Preview and eyedropper fields. Not typed here, and preserved untouched. `CropX/Y/W/H` and `CropStraightenDeg` here are read as a fallback crop and straighten only when the file has no `Film` geometry at all (no `Film:CropX`, `Rotate`, `Flip` or `StraightenDeg`). `CropFilmSizeID` is read whenever `Film:FilmSizeID` is absent |
| `https://github.com/chriscantey/film-positive/ns/1.0/` | `FilmPositive` | Positive | `Stock`, `ToneMode`, `AutoTone`, `AutoBalance`, `BaseMode`, `BaseAnchor`, `BaseRG/BG`, `BaseMeasured`, `BaseWarmPoints`, `BaseGreenPoints`, `ToneAdjust`, `Stretch`, `HighlightAxes`, the 21 enhance sliders (`Radiance` through `VignetteFeather`), `Levels`, `CurveRGB`, `CurveRed`, `CurveGreen`, `CurveBlue`, `Look`, `ColorAuto`. A retired `Light` field is still accepted and is dropped on the next save |

The namespace URIs are identifiers, not links to pages. The fields this package writes are flat attributes on `rdf:Description`. Film Tether writes `dc:subject` and `dc:description` as elements (an `rdf:Bag` and an `rdf:Alt`), which this package does not read. Everything else in the file (Adobe's `crs:` fields, extra `rdf:Description` blocks, elements) is kept on rewrite. The packet is re-serialized, so whitespace and the XML declaration can change on the first two saves of a file from another writer. After that, a sidecar whose state has not changed rewrites to the same bytes, and `SidecarStore.save` skips the write entirely when none of our fields changed.

## Sections and owners (the Swift type)

`Sidecar` carries `version`, `source`, `capture` (Tether), `geometry` and `samplePoint` (shared), and `develop`, `enhance`, `look` and `colorAuto` (Positive). `source` is written by Tether at capture, or by Positive when it is absent.

Crop is normalized, y down, in the original orientation, and measured after straighten. Apply order is fixed: straighten, crop, rotate, flip.

An app preserves every section it does not own on read-modify-write, because the type carries all sections and both apps encode through it. That covers the fields the writing app's copy of this package knows. On save, every attribute in the `Film` and `FilmPositive` namespaces is removed and written again from the type, so a field added by a newer copy of the package is dropped when an app built with an older copy saves the file, unless the newer copy also raised `Film:Version`.

## Rules

- `develop` absent means undeveloped. `enhance` absent means identity, and an absent slider is 0.
- Zero sliders and identity values (the printer-point axes, `Levels`, curves) are not written, and `ToneAdjust`, `Stretch` and `ColorAuto` are written only when set, so a frame nobody adjusted carries none of them. `Stretch` is one number in 0...1. A finite value outside that range is clamped into it on read.
- A file whose `Film:Version` is newer than the package knows is read for known fields: `SidecarStore.load` reports it as read-only, and `save` refuses a sidecar whose version is newer than the package knows, which is what such a load returns. `save` checks the version of the value it is given, not the version in the file on disk.
- A file that is not parseable XMP is never overwritten. `load` throws `XMPError` and `save` refuses.
- Writes go to a temp file in the same directory and then replace the sidecar. A save that would not change any of our fields writes nothing. A temp left by a crash is removed by a later load once it is a minute old, so a save running in the other app is never touched.
- Strict decoding (`Sidecar.decode(_:liveSource:strict: true)`) rejects unknown fields in the `Film` and `FilmPositive` namespaces. `SidecarStore.load` decodes leniently. Foreign namespaces are never an error.
- Never reuse a field name with a changed meaning. Bump `Film:Version`, add a field and write a migration instead.
- Never name a field so that another field's name on the same element ends with it, or the other way round. Foundation's XML writer silently drops such an attribute. That was observed within one namespace and is assumed across them, and four cross-namespace pairs exist today: `tiff:Make` with `Film:ScannerMake`, `tiff:Model` with `Film:ScannerModel`, `FilmTether:CropStraightenDeg` with `Film:StraightenDeg`, and `FilmTether:CropFilmSizeID` with `Film:FilmSizeID`. `testEncodeLandsEveryAttribute` checks that every attribute the codec produces reaches the bytes. It covers the first two pairs, not the two with a `FilmTether` field.
- `EnhanceSettings.sliderKeys`, `EnhanceSettings.values` and the codec's `subscript(slider:)` list the sliders in one order and must change together, which `EnhanceOrderingTests` checks. The codec walks `sliderKeys` by index and writes and reads each slider under its own name, so a file is keyed by name and inserting a slider in all three places changes nothing on disk.
- Values are written with trailing zeros dropped, to at most four decimals for sliders, base ratios, `Levels`, curve points, `ToneAdjust`, `Stretch` and `ColorAuto`, three for the printer-point axes (`BaseWarmPoints`, `BaseGreenPoints`, `HighlightAxes`), and six for crop, the base sample point and straighten degrees. Timestamps are ISO 8601 to the second. `TakenOn` is a plain `YYYY-MM-DD` day. Booleans are `True` and `False`.
- A file with no `Film:Source*` fields (Tether 0.3.0, an Adobe sidecar) takes its source from the live image, and its load status is `ok`.

## Use

Each app's `Package.swift` names this package as a local path dependency, pointing at wherever its copy lives: `Packages/film-sidecar` inside an app's repository, or a sibling checkout such as `../film-sidecar`.

```swift
.package(path: "Packages/film-sidecar")
```

`SidecarStore` is the entry point:

```swift
import FilmSidecar

let store = SidecarStore()
let source = try SidecarStore.source(for: imageURL)
var sidecar = try store.load(for: imageURL)?.sidecar ?? Sidecar(source: source)
sidecar.look = "pop"
try store.save(sidecar, for: imageURL)
```

`load(for:)` returns nil when the image has no sidecar, and its `status` says whether the image still matches the recorded size and fingerprint. `save(_:for:)` returns `.unchanged` when there was nothing to write. `XMPSidecarCodec` is public for a writer that needs to add its own fields to the same packet.

The package also has a second product, `FilmStyle`: a small SwiftUI target with the spacing scale, card finish and info popover both apps share. It is separate so `FilmSidecar` does not depend on SwiftUI.

Requires macOS 14 or later. Run the tests with `swift test`.

## License

MIT. See [LICENSE](LICENSE).

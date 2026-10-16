# The app icon

## What the build reads

`scripts/bundle.sh` packs **`Resources/AppIcon.iconset/`** with `iconutil` and writes
`Contents/Resources/AppIcon.icns` into the bundle. The iconset is the source of truth, and it
is the only icon input the build touches.

Ten slices, all required, all RGBA with transparent corners:

```
icon_16x16.png    icon_16x16@2x.png     (16, 32)
icon_32x32.png    icon_32x32@2x.png     (32, 64)
icon_128x128.png  icon_128x128@2x.png   (128, 256)
icon_256x256.png  icon_256x256@2x.png   (256, 512)
icon_512x512.png  icon_512x512@2x.png   (512, 1024)
```

`bundle.sh` fails the build when the directory is missing or when the slice count is not ten.
`iconutil` accepts a partial iconset without complaint, so the count check is what stops an
app shipping with a Dock icon that is right at one size and blank at another.

## What the build does not read

`AppIcon.png` is the 1024 master, kept for reference and for re-deriving the set. The build
does not read it, and nothing scales it into the slices, so each size can carry its own artwork.

## The grid

The icon is a dark rounded tile holding a strip of film, with sprocket holes above and below
a frame that glows in an orange to pink gradient.

The icon body is 816 pixels in the 1024 canvas (79.7 percent), inset 104 on each side, and the
128, 256 and 512 pixel slices use the same proportion. The smaller sizes use a larger inset:
the body is 50 of 64 pixels (78.1 percent) in the 64 pixel slice, and 75 percent of the canvas
at 16 and 32 pixels.

The 16 and 32 pixel slices are drawn separately rather than scaled down from the master. The
sprocket holes would be under a pixel there, so those two sizes leave them out and keep only
the tile, the strip and the frame. From 64 pixels up the slices follow the master.

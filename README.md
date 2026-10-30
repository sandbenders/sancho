# sancho

A PNG writer and a deflate compressor for [Odin](https://odin-lang.org), with no dependencies beyond Odin's own `core` library.

Odin's `core:image/png` reads PNG files and `core:compress/zlib` inflates, but neither has the other half: writing a PNG, or compressing. sancho is that other half.

- **`png_writer`** saves a `core:image` `Image`, or plain pixels, as a PNG: grey, grey with alpha, RGB or RGBA, at 8 or 16 bits a channel. `encode_animation` writes animated PNGs from the same kinds of pixels. Its `save`, `save_to_buffer` and `save_to_file` have the same shape as the writers in `core:image` (`qoi`, `tga`, `bmp`, `netpbm`).
- **`deflate`** compresses to raw deflate (RFC 1951) or to a zlib stream (RFC 1950) that `core:compress/zlib.inflate` reads back.

It is called sancho, after [Sancho Panza](https://en.wikipedia.org/wiki/Sancho_Panza) because it rides beside [rocinante](https://github.com/sandbenders/rocinante), the creative-coding language it was written for, and carries the luggage.

## Using it

Odin has no package manager: copy the repository into your project (or add it as a git submodule), then name it as a collection when you build, or import its folders by relative path.

```sh
git submodule add https://github.com/sandbenders/sancho libs/sancho
odin build . -collection:sancho=libs/sancho
```

```odin
import "core:image"
import png "sancho:png_writer"

save_picture :: proc(img: ^image.Image) -> bool {
 return png.save("picture.png", img) == nil
}
```

From plain pixels (rows from the top; 16-bit samples in the machine's byte order, as `core:image` keeps them):

```odin
data, err := png.encode(pixels, width, height, channels = 4)  // depth = 8 by default
defer delete(data)
```

Compressing anything:

```odin
import "sancho:deflate"

raw  := deflate.compress(data)       // raw deflate, as in zip and gzip
zlib := deflate.compress_zlib(data)  // a zlib stream, as in PNG
```

The result is in `context.allocator` (or the allocator you pass), and the working memory is taken from the temporary allocator and given back before each call returns.

`examples/gradient` writes an RGB picture from an `Image` and a 16-bit grey one from plain pixels:

```sh
odin run examples/gradient
```

## Rows: filtered, unfiltered, or whichever is smaller

PNG lets each row be stored as differences from its neighbours ("filtered") before it is compressed. Filtering suits gradients and photographs; flat colours with hard edges often compress better left alone. `Filters` chooses:

| `Filters`             | What it does                                                              |
| --------------------- | ------------------------------------------------------------------------- |
| `.Smallest` (default) | makes the file both ways and keeps the smaller, but it is twice the work  |
| `.Adaptive`           | each row gets the filter that leaves the smallest numbers (libpng's rule) |
| `.None`               | every row as it is                                                        |

```odin
png.save("frame.png", &img, filters = .Adaptive)  // when speed matters more than size
```

## Animations

`encode_animation` writes an animated PNG (APNG), which every current browser plays and which keeps every pixel exactly, where a GIF has 256 colours. The frames are laid out as `encode` takes pixels, all the same size; `ticks[i]` is how long frame i shows, in 1/`per_second` of a second, and the animation plays forever:

```odin
data, err := png.encode_animation(frames, width, height, channels = 4, ticks = ticks, per_second = 30)
defer delete(data)
```

The first frame is the file's own picture, so a program that knows only PNG (`core:image/png` among them) shows it. Each later frame keeps only the rectangle that changed since the frame before, and a frame equal to the one before is not kept again (the one before shows longer), so a drawing that changes a little at a time stays small.

## How it compares

Six rendered 2D pictures (flat colours, gradients, thin anti-aliased lines; 280 KB to 1.9 MB of pixels), total size in bytes, on one x86-64 Linux computer:

|                 | sancho  | reference                                                         |
| --------------- | ------- | ----------------------------------------------------------------- |
| deflate alone   | 158,534 | zlib level 6 (`gzip -6`): 158,420; level 9: 154,412               |
| whole PNG files | 156,892 | libpng with zlib level 6 (ImageMagick): 170,574; level 9: 168,241 |

- The deflate data is as small as zlib's default level: it uses the same method (hash chains 128 long and lazy matching) and picks, for each block, the smallest of its own Huffman codes, the fixed ones, or the data stored as it is.
- The PNG files are smaller than libpng's here because `.Smallest` also tries leaving the rows unfiltered, which wins on pictures like these.
- It takes about twice as long as zlib. These were drawn pictures, not photographs; measurements on other kinds of picture are welcome.

## The same bytes everywhere

Everything is decided by the data alone, never by addresses, hashing order or timing, and ties always go the same way, so the same pixels give the same file on every system and every run. That is what golden-image tests need, which is what sancho was first written for.

## What it does not do (yet)

- Palette (indexed) images, bit depths below 8, and interlaced files.
- Ancillary chunks: gamma, colour profiles, text, timestamps. `save_to_buffer` takes `core:image`'s `Options` so it has the same shape as the other writers, but no option applies to PNG yet and any given is ignored.
- Streaming: the whole picture is compressed in memory. An animation holds all its frames in memory too.
- Compression levels: there is one, about zlib's level 6.

Note that `core:image/png` gives grey pictures back as RGB (and grey with alpha as RGBA) when it reads them; the files sancho writes are grey.

## Tests

```sh
odin test deflate
odin test png_writer
```

Every test checks its output with Odin's own readers: deflate data is inflated by `core:compress/zlib`, PNG files are read by `core:image/png`. Besides cases chosen by hand (empty input, runs past the longest match, repeats at every distance, data that does not compress, the deepest Huffman tree) there are 300 generated inputs and 60 generated pictures from fixed seeds, so a failure names the seed that finds it again. Tested with Odin `dev-2026-10`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md)

## Licence

[Zero-Clause BSD](LICENSE) (0BSD): use it for anything, with or without credit.

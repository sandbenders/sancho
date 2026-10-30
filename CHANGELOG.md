# Changelog

Every release of sancho, newest first. Versions follow [Semantic Versioning](https://semver.org): until 1.0.0, a minor version may change the API, and the notes say how.

## Unreleased

- `png_writer`: `encode_animation` writes animated PNGs (APNG) from frames laid out as `encode` takes pixels, at every layout and depth `encode` writes. Each frame after the first keeps only the rectangle that changed, and a repeated frame shows longer instead of being kept again. Tested by playing every frame back from generated frames, in every layout and at both depths.
- `encode` and `encode_animation` share the code that filters and compresses the rows; `encode`'s output is unchanged.

## 0.1.0 (2026-10-29)

The first release.

- `deflate`: `compress` (raw deflate, RFC 1951) and `compress_zlib` (a zlib stream, RFC 1950). Hash chains of 128 places and lazy matching, as zlib's level 6; each block written as its own Huffman codes, the fixed codes or stored, whichever is smallest. The same input always gives the same bytes.
- `png_writer`: `save`, `save_to_buffer` and `save_to_file` for a `core:image` `Image`, and `encode` for plain pixels. Grey, grey with alpha, RGB and RGBA at 8 or 16 bits a channel. `Filters` chooses filtered rows (libpng's rule), unfiltered rows, or the smaller of the two (the default).
- Tests that check every output with Odin's own readers, including 300 generated inputs and 60 generated pictures from fixed seeds.

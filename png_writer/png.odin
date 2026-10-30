// SPDX-License-Identifier: 0BSD
//
// A PNG writer for Odin: the other half of core:image/png, which only reads. Its
// package name differs from core's, so a program can use both.
// It takes a core:image Image, as core:image's own writers do (qoi, tga, bmp,
// netpbm), or plain pixels, and writes grey, grey with alpha, RGB or RGBA at 8
// or 16 bits a channel, compressed by the deflate package beside it.
//
// Each row may be filtered the way that leaves the smallest numbers (libpng's
// rule: the least sum of the bytes read as signed), which suits gradients and
// photographs, or left as it is, which often suits flat colours with hard edges
// better; by default both are made and the smaller kept (`Filters`).
//
// Format: https://www.w3.org/TR/png-3/
package png_writer

import "base:runtime"
import "core:bytes"
import "core:hash"
import "core:image"

Image   :: image.Image
Options :: image.Options
Error   :: image.Error

// How the rows are filtered before they are compressed.
Filters :: enum u8 {
	Smallest, // both ways below, keeping the smaller file: twice the work
	Adaptive, // each row the filter that leaves the smallest numbers
	None,     // every row as it is
}

SIGNATURE := [8]u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}

// A PNG of `img` added to `output`. `options` is there so this has the shape of
// core:image's other writers; no option applies to PNG yet, and any given is
// ignored. 16-bit pixels are in the machine's byte order, as core:image keeps them.
save_to_buffer :: proc(output: ^bytes.Buffer, img: ^Image, options := Options{}, filters := Filters.Smallest, allocator := context.allocator) -> (err: Error) {
	if img == nil {
		return .Invalid_Input_Image
	}
	data := encode(img.pixels.buf[:], img.width, img.height, img.channels, img.depth, filters, allocator) or_return
	defer delete(data, allocator)
	_, write_err := bytes.buffer_write(output, data)
	if write_err != nil {
		return write_err
	}
	return nil
}

// A PNG of `pixels`: rows from the top, `channels` values a pixel (1 grey, 2 grey
// and alpha, 3 RGB, 4 RGBA), each `depth` bits (8, or 16 in the machine's byte
// order). The file is in `allocator`; the working memory is temporary and given
// back before it returns.
encode :: proc(pixels: []u8, width, height, channels: int, depth := 8, filters := Filters.Smallest, allocator := context.allocator) -> (png: []u8, err: Error) {
	switch {
	case width <= 0 || height <= 0 || width > 0x7fff_ffff || height > 0x7fff_ffff:
		return nil, .Invalid_Image_Dimensions
	case channels < 1 || channels > 4:
		return nil, .Invalid_Number_Of_Channels
	case depth != 8 && depth != 16:
		return nil, .Invalid_Image_Depth
	case len(pixels) != width * height * channels * depth / 8:
		return nil, .Invalid_Input_Image
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	z := compressed(pixels, width, height, channels * depth / 8, depth, filters)

	out := make([dynamic]u8, 0, len(z) + 57, allocator)
	append(&out, ..SIGNATURE[:])
	ihdr: [13]u8
	put_u32(ihdr[0:], u32(width))
	put_u32(ihdr[4:], u32(height))
	ihdr[8] = u8(depth)
	ihdr[9] = COLOUR_TYPE[channels]
	// ihdr[10:13]: deflate, adaptive filtering, no interlace (all zero)
	put_chunk(&out, "IHDR", ihdr[:])
	put_chunk(&out, "IDAT", z)
	put_chunk(&out, "IEND", nil)
	return out[:], nil
}

// PNG's colour type for each number of channels: grey, grey and alpha, RGB, RGBA.
@(private)
COLOUR_TYPE := [5]u8{0, 0, 4, 2, 6}

// 16-bit samples in PNG's order, most significant byte first.
@(private)
big_endian :: proc(pixels: []u8) -> []u8 {
	when ODIN_ENDIAN == .Big {
		return pixels
	} else {
		out := make([]u8, len(pixels), context.temp_allocator)
		for i := 0; i + 1 < len(pixels); i += 2 {
			out[i], out[i + 1] = pixels[i + 1], pixels[i]
		}
		return out
	}
}

// The rows, each led by the number of its filter: 0 none, 1 the byte a pixel to
// the left taken away, 2 the byte above, 3 their average, 4 Paeth's guess. With
// `adaptive`, every filter is tried on every row and the one whose bytes, read as
// signed, add up least wins (a tie goes to the lower number); without it every
// row is left as it is.
@(private)
filter_rows :: proc(samples: []u8, width, height, bpp: int, adaptive: bool) -> []u8 {
	row := width * bpp
	raw := make([]u8, (row + 1) * height, context.temp_allocator)
	trial := make([]u8, row, context.temp_allocator)
	zero := make([]u8, row, context.temp_allocator)
	for y in 0 ..< height {
		line := samples[y * row:(y + 1) * row]
		above := samples[(y - 1) * row:y * row] if y > 0 else zero
		out := raw[y * (row + 1):(y + 1) * (row + 1)]
		if !adaptive {
			copy(out[1:], line)
			continue
		}
		best := max(int)
		for filter in u8(0) ..= 4 {
			sum := 0
			for x in 0 ..< row {
				left := line[x - bpp] if x >= bpp else 0
				up := above[x]
				corner := above[x - bpp] if x >= bpp else 0
				guess: u8
				switch filter {
				case 1: guess = left
				case 2: guess = up
				case 3: guess = u8((int(left) + int(up)) / 2)
				case 4: guess = paeth(left, up, corner)
				}
				trial[x] = line[x] - guess
				sum += abs(int(i8(trial[x])))
			}
			if sum < best {
				best = sum
				out[0] = filter
				copy(out[1:], trial)
			}
		}
	}
	return raw
}

// The neighbour closest to left + up - corner, preferring left, then up.
@(private)
paeth :: proc "contextless" (left, up, corner: u8) -> u8 {
	p := int(left) + int(up) - int(corner)
	pa, pb, pc := abs(p - int(left)), abs(p - int(up)), abs(p - int(corner))
	if pa <= pb && pa <= pc {
		return left
	}
	return up if pb <= pc else corner
}

@(private)
put_u32 :: proc(out: []u8, v: u32) {
	out[0], out[1], out[2], out[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

// A chunk: its length, its type, its data, and the CRC-32 of the type and data.
@(private)
put_chunk :: proc(out: ^[dynamic]u8, type: string, data: []u8) {
	n: [4]u8
	put_u32(n[:], u32(len(data)))
	append(out, ..n[:])
	start := len(out)
	append(out, type)
	append(out, ..data)
	put_u32(n[:], hash.crc32(out[start:]))
	append(out, ..n[:])
}

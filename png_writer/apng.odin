// SPDX-License-Identifier: 0BSD
//
// Animated PNG (APNG), which every current browser plays. The first frame is the
// file's own picture, so a program that knows only PNG shows it; each later frame
// keeps only the rectangle that changed since the frame before, written over it. A
// frame equal to the one before is not kept again: the one before shows longer.
//
// Format: https://www.w3.org/TR/png-3/#apng-frame-control-chunk
package png_writer

import "base:runtime"

import "../deflate"

// An APNG of `frames`, each laid out as `encode` takes pixels (rows from the top,
// `channels` values a pixel, each `depth` bits). Frame i shows for `ticks[i]` of
// 1/`per_second` of a second, and the animation plays forever. The file is in
// `allocator`; the working memory is temporary and given back before it returns.
encode_animation :: proc(frames: [][]u8, width, height, channels: int, ticks: []int, per_second: int, depth := 8, filters := Filters.Smallest, allocator := context.allocator) -> (png: []u8, err: Error) {
	switch {
	case width <= 0 || height <= 0 || width > 0x7fff_ffff || height > 0x7fff_ffff:
		return nil, .Invalid_Image_Dimensions
	case channels < 1 || channels > 4:
		return nil, .Invalid_Number_Of_Channels
	case depth != 8 && depth != 16:
		return nil, .Invalid_Image_Depth
	case len(frames) == 0 || len(ticks) != len(frames) || per_second < 1 || per_second > 65535:
		return nil, .Invalid_Input_Image
	}
	bpp := channels * depth / 8
	for f, i in frames {
		if len(f) != width * height * bpp || ticks[i] < 1 {
			return nil, .Invalid_Input_Image
		}
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	Kept :: struct {
		frame, ticks: int,
	}
	kept := make([dynamic]Kept, context.temp_allocator)
	for f, i in frames {
		if i > 0 && equal(frames[kept[len(kept) - 1].frame], f) {
			kept[len(kept) - 1].ticks += ticks[i]
		} else {
			append(&kept, Kept{i, ticks[i]})
		}
	}
	for k in kept {
		if k.ticks > 65535 {
			return nil, .Invalid_Input_Image
		}
	}

	out := make([dynamic]u8, allocator)
	append(&out, ..SIGNATURE[:])
	ihdr: [13]u8
	put_u32(ihdr[0:], u32(width))
	put_u32(ihdr[4:], u32(height))
	ihdr[8] = u8(depth)
	ihdr[9] = COLOUR_TYPE[channels]
	put_chunk(&out, "IHDR", ihdr[:])
	actl: [8]u8
	put_u32(actl[0:], u32(len(kept)))
	put_u32(actl[4:], 0) // play forever
	put_chunk(&out, "acTL", actl[:])

	sequence: u32
	for k, i in kept {
		x, y, w, h := 0, 0, width, height
		part := frames[k.frame]
		if i > 0 {
			x, y, w, h = changed_box(frames[kept[i - 1].frame], part, width, height, bpp)
			part = crop(part, width, bpp, x, y, w, h)
		}
		fctl: [26]u8
		put_u32(fctl[0:], sequence)
		sequence += 1
		put_u32(fctl[4:], u32(w))
		put_u32(fctl[8:], u32(h))
		put_u32(fctl[12:], u32(x))
		put_u32(fctl[16:], u32(y))
		fctl[20], fctl[21] = u8(k.ticks >> 8), u8(k.ticks)
		fctl[22], fctl[23] = u8(per_second >> 8), u8(per_second)
		// fctl[24:26]: keep what is there, and replace the rectangle's pixels (zero)
		put_chunk(&out, "fcTL", fctl[:])
		z := compressed(part, w, h, bpp, depth, filters)
		if i == 0 {
			put_chunk(&out, "IDAT", z)
		} else {
			fdat := make([dynamic]u8, 4, 4 + len(z), context.temp_allocator)
			put_u32(fdat[:4], sequence)
			sequence += 1
			append(&fdat, ..z)
			put_chunk(&out, "fdAT", fdat[:])
		}
	}
	put_chunk(&out, "IEND", nil)
	return out[:], nil
}

// The rows of a picture filtered and compressed, as `encode` keeps them.
@(private)
compressed :: proc(pixels: []u8, width, height, bpp, depth: int, filters: Filters) -> []u8 {
	samples := big_endian(pixels) if depth == 16 else pixels
	switch filters {
	case .Adaptive: return deflate.compress_zlib(filter_rows(samples, width, height, bpp, true), context.temp_allocator)
	case .None:     return deflate.compress_zlib(filter_rows(samples, width, height, bpp, false), context.temp_allocator)
	case .Smallest:
		z := deflate.compress_zlib(filter_rows(samples, width, height, bpp, true), context.temp_allocator)
		if plain := deflate.compress_zlib(filter_rows(samples, width, height, bpp, false), context.temp_allocator); len(plain) < len(z) {
			return plain
		}
		return z
	}
	return nil
}

@(private)
equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for v, i in a {
		if v != b[i] {
			return false
		}
	}
	return true
}

// The smallest rectangle holding every pixel that differs between two pictures of
// one size; the whole picture when none differs.
@(private)
changed_box :: proc(a, b: []u8, width, height, bpp: int) -> (x, y, w, h: int) {
	left, top, right, bottom := width, height, -1, -1
	for row in 0 ..< height {
		for col in 0 ..< width {
			i := (row * width + col) * bpp
			if !equal(a[i:i + bpp], b[i:i + bpp]) {
				left, right = min(left, col), max(right, col)
				top, bottom = min(top, row), max(bottom, row)
			}
		}
	}
	if right < 0 {
		return 0, 0, width, height
	}
	return left, top, right - left + 1, bottom - top + 1
}

// A rectangle of a picture, as pixels of its own, in the temporary allocator.
@(private)
crop :: proc(pixels: []u8, width, bpp, x, y, w, h: int) -> []u8 {
	out := make([]u8, w * h * bpp, context.temp_allocator)
	for row in 0 ..< h {
		from := ((y + row) * width + x) * bpp
		copy(out[row * w * bpp:(row + 1) * w * bpp], pixels[from:from + w * bpp])
	}
	return out
}

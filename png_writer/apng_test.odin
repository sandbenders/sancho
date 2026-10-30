// SPDX-License-Identifier: 0BSD
package png_writer

import "core:bytes"
import "core:compress/zlib"
import "core:hash"
import core_png "core:image/png"
import "core:math/rand"
import "core:testing"

@(private = "file")
Chunk :: struct {
	type: string,
	data: []u8,
}

@(private = "file")
be32 :: proc(b: []u8) -> int {
	return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3])
}

// The chunks of a file, checking the signature and every CRC.
@(private = "file")
chunks_of :: proc(t: ^testing.T, data: []u8) -> []Chunk {
	out := make([dynamic]Chunk, context.temp_allocator)
	testing.expect(t, bytes.equal(data[:8], SIGNATURE[:]))
	at := 8
	for at + 12 <= len(data) {
		n := be32(data[at:])
		testing.expect(t, u32(be32(data[at + 8 + n:])) == hash.crc32(data[at + 4:at + 8 + n]))
		append(&out, Chunk{string(data[at + 4:at + 8]), data[at + 8:at + 8 + n]})
		at += 12 + n
	}
	testing.expect_value(t, at, len(data))
	return out[:]
}

// A compressed rectangle's samples, unfiltered as a reader does (big-endian for 16 bits).
@(private = "file")
unpacked :: proc(t: ^testing.T, z: []u8, w, h, bpp: int) -> []u8 {
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	testing.expect(t, zlib.inflate(z, &buf, false, (w * bpp + 1) * h) == nil)
	raw := bytes.buffer_to_bytes(&buf)
	row := w * bpp
	out := make([]u8, row * h, context.temp_allocator)
	for y in 0 ..< h {
		filter := raw[y * (row + 1)]
		line := raw[y * (row + 1) + 1:(y + 1) * (row + 1)]
		for x in 0 ..< row {
			left := out[y * row + x - bpp] if x >= bpp else 0
			up := out[(y - 1) * row + x] if y > 0 else 0
			corner := out[(y - 1) * row + x - bpp] if x >= bpp && y > 0 else 0
			guess: u8
			switch filter {
			case 1: guess = left
			case 2: guess = up
			case 3: guess = u8((int(left) + int(up)) / 2)
			case 4: guess = paeth(left, up, corner)
			}
			out[y * row + x] = line[x] + guess
		}
	}
	return out
}

// Plays an APNG as a browser does and gives every frame shown, in the file's byte order.
@(private = "file")
played :: proc(t: ^testing.T, data: []u8, bpp: int) -> [][]u8 {
	chunks := chunks_of(t, data)
	w, h := be32(chunks[0].data), be32(chunks[0].data[4:])
	canvas := make([]u8, w * h * bpp, context.temp_allocator)
	shown := make([dynamic][]u8, context.temp_allocator)
	fx, fy, fw, fh := 0, 0, w, h
	for c in chunks {
		switch c.type {
		case "fcTL":
			fw, fh, fx, fy = be32(c.data[4:]), be32(c.data[8:]), be32(c.data[12:]), be32(c.data[16:])
		case "IDAT", "fdAT":
			part := unpacked(t, c.data if c.type == "IDAT" else c.data[4:], fw, fh, bpp)
			for row in 0 ..< fh {
				copy(canvas[((fy + row) * w + fx) * bpp:][:fw * bpp], part[row * fw * bpp:][:fw * bpp])
			}
			frame := make([]u8, len(canvas), context.temp_allocator)
			copy(frame, canvas)
			append(&shown, frame)
		}
	}
	return shown[:]
}

// Frames from a seed: a picture of noise, then in each later frame a small square
// moved, as a drawing that animates changes a part at a time.
@(private = "file")
frames_for :: proc(width, height, bpp, count: int, seed: u64) -> [][]u8 {
	r := rand.create(seed)
	gen := rand.default_random_generator(&r)
	out := make([][]u8, count, context.temp_allocator)
	for i in 0 ..< count {
		out[i] = make([]u8, width * height * bpp, context.temp_allocator)
		if i == 0 {
			for &b in out[i] {
				b = u8(rand.uint32(gen))
			}
		} else {
			copy(out[i], out[i - 1])
			x, y := int(rand.uint32(gen)) % (width - 3), int(rand.uint32(gen)) % (height - 3)
			for dy in 0 ..< 3 {
				for dx in 0 ..< 3 * bpp {
					out[i][((y + dy) * width + x) * bpp + dx] = u8(rand.uint32(gen))
				}
			}
		}
	}
	return out
}

@(test)
animations_play_back_every_frame_in_every_layout :: proc(t: ^testing.T) {
	for channels in 1 ..= 4 {
		for depth in ([]int{8, 16}) {
			bpp := channels * depth / 8
			seed := u64(channels * 100 + depth)
			frames := frames_for(17, 11, bpp, 6, seed)
			ticks := []int{1, 2, 1, 3, 1, 1}
			data, err := encode_animation(frames, 17, 11, channels, ticks, 30, depth)
			testing.expectf(t, err == nil, "seed %d: %v", seed, err)
			defer delete(data)
			shown := played(t, data, bpp)
			testing.expectf(t, len(shown) == len(frames), "seed %d: %d frames shown", seed, len(shown))
			for f, i in frames {
				want := big_endian(f) if depth == 16 else f
				if i < len(shown) {
					testing.expectf(t, bytes.equal(shown[i], want), "seed %d: frame %d plays back different", seed, i)
				}
			}
		}
	}
}

@(test)
a_repeated_frame_shows_longer_instead :: proc(t: ^testing.T) {
	a := make([]u8, 4 * 4 * 4, context.temp_allocator)
	b := make([]u8, 4 * 4 * 4, context.temp_allocator)
	b[5] = 9
	data, err := encode_animation({a, a, b}, 4, 4, 4, {1, 2, 3}, 30)
	testing.expect(t, err == nil)
	defer delete(data)
	chunks := chunks_of(t, data)
	testing.expect_value(t, be32(chunks[1].data), 2) // acTL: two frames kept
	testing.expect_value(t, int(chunks[2].data[20]) << 8 | int(chunks[2].data[21]), 3)
	// A reader that knows only PNG shows the first frame.
	img, read_err := core_png.load_from_bytes(data)
	testing.expect(t, read_err == nil)
	if read_err == nil {
		testing.expect(t, bytes.equal(bytes.buffer_to_bytes(&img.pixels), a))
		core_png.destroy(img)
	}
}

@(test)
encode_animation_refuses_what_it_cannot_write :: proc(t: ^testing.T) {
	one := make([]u8, 2 * 2 * 4, context.temp_allocator)
	_, e1 := encode_animation({}, 2, 2, 4, {}, 30)
	_, e2 := encode_animation({one}, 2, 2, 4, {1, 1}, 30)
	_, e3 := encode_animation({one}, 2, 2, 4, {1}, 0)
	_, e4 := encode_animation({one}, 2, 2, 4, {0}, 30)
	_, e5 := encode_animation({one}, 0, 2, 4, {1}, 30)
	_, e6 := encode_animation({one}, 2, 2, 5, {1}, 30)
	_, e7 := encode_animation({one, one}, 2, 2, 4, {65535, 1}, 30)
	testing.expect(t, e1 != nil && e2 != nil && e3 != nil && e4 != nil && e5 != nil && e6 != nil && e7 != nil)
}

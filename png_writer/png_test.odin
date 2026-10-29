// SPDX-License-Identifier: 0BSD
package png_writer

import "core:bytes"
import core_png "core:image/png"
import "core:math/rand"
import "core:os"
import "core:testing"

// Pixels that change everywhere, from a seed, mixing runs, ramps and noise so
// every filter gets used.
@(private = "file")
pixels_for :: proc(width, height, channels, depth: int, seed: u64) -> []u8 {
	r := rand.create(seed)
	gen := rand.default_random_generator(&r)
	out := make([]u8, width * height * channels * depth / 8)
	for &b, i in out {
		switch (i / 97) % 3 {
		case 0: b = u8(i / 13)
		case 1: b = u8(seed)
		case:   b = u8(rand.uint32(gen))
		}
	}
	return out
}

// Grey samples repeated as red, green and blue, with alpha after them when there is one.
@(private = "file")
grey_as_colour :: proc(pixels: []u8, channels, depth: int) -> []u8 {
	sample := depth / 8
	pixel := channels * sample
	count := len(pixels) / pixel
	out := make([dynamic]u8, 0, count * (pixel + 2 * sample))
	for i in 0 ..< count {
		p := pixels[i * pixel:(i + 1) * pixel]
		for _ in 0 ..< 3 {append(&out, ..p[:sample])}
		if channels == 2 {append(&out, ..p[sample:])}
	}
	return out[:]
}

// Encodes, reads back with core:image/png, and checks everything matches.
@(private = "file")
round_trips :: proc(t: ^testing.T, width, height, channels, depth: int, filters: Filters, seed: u64, loc := #caller_location) -> int {
	pixels := pixels_for(width, height, channels, depth, seed)
	defer delete(pixels)
	data, err := encode(pixels, width, height, channels, depth, filters)
	defer delete(data)
	if !testing.expectf(t, err == nil, "%dx%d %d channels %d bits %v: %v", width, height, channels, depth, filters, err, loc = loc) {
		return 0
	}
	img, load_err := core_png.load_from_bytes(data)
	if !testing.expectf(t, load_err == nil, "%dx%d %d channels %d bits %v: %v", width, height, channels, depth, filters, load_err, loc = loc) {
		return 0
	}
	defer core_png.destroy(img)
	testing.expect_value(t, img.width, width, loc = loc)
	testing.expect_value(t, img.height, height, loc = loc)
	// core:image/png gives grey back as RGB, and grey with alpha as RGBA.
	want := pixels
	if channels <= 2 {
		want = grey_as_colour(pixels, channels, depth)
	}
	defer if channels <= 2 {delete(want)}
	testing.expect_value(t, img.channels, channels + 2 if channels <= 2 else channels, loc = loc)
	testing.expect_value(t, img.depth, depth, loc = loc)
	testing.expectf(t, bytes.equal(bytes.buffer_to_bytes(&img.pixels), want), "%dx%d %d channels %d bits %v: pixels differ", width, height, channels, depth, filters, loc = loc)
	return len(data)
}

@(test)
test_every_kind_of_pixel_round_trips_with_every_filter_choice :: proc(t: ^testing.T) {
	for channels in 1 ..= 4 {
		for depth in ([?]int{8, 16}) {
			for filters in Filters {
				round_trips(t, 37, 23, channels, depth, filters, u64(channels * depth))
			}
		}
	}
}

@(test)
test_tiny_and_thin_pictures_round_trip :: proc(t: ^testing.T) {
	for size in ([?][2]int{{1, 1}, {1, 50}, {50, 1}, {2, 2}, {3, 1}}) {
		for channels in 1 ..= 4 {
			round_trips(t, size.x, size.y, channels, 8, .Smallest, 1)
			round_trips(t, size.x, size.y, channels, 16, .Smallest, 2)
		}
	}
}

@(test)
test_generated_pictures_round_trip :: proc(t: ^testing.T) {
	for seed in u64(1) ..= 60 {
		r := rand.create(seed)
		gen := rand.default_random_generator(&r)
		width, height := 1 + int(rand.uint32(gen) % 300), 1 + int(rand.uint32(gen) % 200)
		channels := 1 + int(rand.uint32(gen) % 4)
		depth := 8 if rand.uint32(gen) % 3 > 0 else 16
		if round_trips(t, width, height, channels, depth, .Smallest, seed) == 0 {
			return
		}
	}
}

@(test)
test_smallest_keeps_the_smaller_of_the_two :: proc(t: ^testing.T) {
	// Flat stripes with hard edges, where leaving the rows alone wins, and a smooth
	// gradient, where filtering wins.
	w, h := 200, 120
	flat := make([]u8, w * h * 4)
	defer delete(flat)
	smooth := make([]u8, w * h * 4)
	defer delete(smooth)
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := (y * w + x) * 4
			stripe := u8(((x / 9) ~ (y / 7)) & 3) * 80
			flat[i], flat[i + 1], flat[i + 2], flat[i + 3] = stripe, 255 - stripe, 30, 255
			smooth[i], smooth[i + 1], smooth[i + 2], smooth[i + 3] = u8(x), u8(y * 2), u8(x + y), 255
		}
	}
	for pixels in ([?][]u8{flat, smooth}) {
		sizes: [Filters]int
		for choice in Filters {
			data, err := encode(pixels, w, h, 4, 8, choice)
			testing.expect(t, err == nil)
			sizes[choice] = len(data)
			delete(data)
		}
		testing.expect_value(t, sizes[.Smallest], min(sizes[.Adaptive], sizes[.None]))
	}
}

@(test)
test_rows_left_unfiltered_are_the_samples_themselves :: proc(t: ^testing.T) {
	samples := []u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	raw := filter_rows(samples, 2, 2, 3, false)
	testing.expect(t, bytes.equal(raw, []u8{0, 1, 2, 3, 4, 5, 6, 0, 7, 8, 9, 10, 11, 12}))
}

@(test)
test_rows_use_the_filter_that_suits_them :: proc(t: ^testing.T) {
	// Every row is the one above, so "up" wins; the first row climbs by one a
	// pixel, so "left" wins there.
	w := 64
	samples := make([]u8, w * 4 * 4)
	defer delete(samples)
	for y in 0 ..< 4 {
		for x in 0 ..< w {
			for c in 0 ..< 4 {
				samples[(y * w + x) * 4 + c] = u8(x)
			}
		}
	}
	raw := filter_rows(samples, w, 4, 4, true)
	row := w * 4 + 1
	testing.expect_value(t, raw[0], 1)
	for y in 1 ..< 4 {
		testing.expect_value(t, raw[y * row], 2)
	}
}

@(test)
test_paeth_picks_the_nearest_neighbour :: proc(t: ^testing.T) {
	testing.expect_value(t, paeth(10, 20, 10), 20) // guess 20: up
	testing.expect_value(t, paeth(20, 10, 10), 20) // guess 20: left
	testing.expect_value(t, paeth(10, 10, 30), 10) // guess -10: left wins the tie
	testing.expect_value(t, paeth(100, 200, 150), 150) // guess 150: the corner
	testing.expect_value(t, paeth(0, 0, 0), 0)
}

@(test)
test_the_file_starts_with_the_signature_and_header :: proc(t: ^testing.T) {
	data, err := encode([]u8{1, 2, 3, 4, 5, 6}, 2, 1, 3, 8)
	defer delete(data)
	testing.expect(t, err == nil)
	testing.expect(t, bytes.equal(data[:8], SIGNATURE[:]))
	testing.expect(t, bytes.equal(data[12:16], transmute([]u8)string("IHDR")))
	testing.expect_value(t, data[24], 8) // depth
	testing.expect_value(t, data[25], 2) // RGB
	testing.expect(t, bytes.equal(data[len(data) - 8:len(data) - 4], transmute([]u8)string("IEND")))
}

@(test)
test_bad_input_is_refused :: proc(t: ^testing.T) {
	px := []u8{1, 2, 3, 4}
	_, err := encode(px, 0, 1, 4)
	testing.expect_value(t, err, Error(.Invalid_Image_Dimensions))
	_, err = encode(px, 1, -1, 4)
	testing.expect_value(t, err, Error(.Invalid_Image_Dimensions))
	_, err = encode(px, 1, 1, 5)
	testing.expect_value(t, err, Error(.Invalid_Number_Of_Channels))
	_, err = encode(px, 1, 1, 0)
	testing.expect_value(t, err, Error(.Invalid_Number_Of_Channels))
	_, err = encode(px, 1, 1, 4, 12)
	testing.expect_value(t, err, Error(.Invalid_Image_Depth))
	_, err = encode(px, 2, 1, 4)
	testing.expect_value(t, err, Error(.Invalid_Input_Image))
	_, err = encode(nil, 1, 1, 1)
	testing.expect_value(t, err, Error(.Invalid_Input_Image))
	out: bytes.Buffer
	testing.expect_value(t, save_to_buffer(&out, nil), Error(.Invalid_Input_Image))
	testing.expect_value(t, len(out.buf), 0)
}

@(test)
test_an_image_saves_to_a_buffer_and_a_file :: proc(t: ^testing.T) {
	img := Image{width = 3, height = 2, channels = 4, depth = 8}
	pixels := pixels_for(3, 2, 4, 8, 4)
	defer delete(pixels)
	bytes.buffer_write(&img.pixels, pixels)
	defer bytes.buffer_destroy(&img.pixels)

	out: bytes.Buffer
	defer bytes.buffer_destroy(&out)
	testing.expect(t, save(&out, &img) == nil)
	loaded, err := core_png.load_from_bytes(bytes.buffer_to_bytes(&out))
	testing.expect(t, err == nil)
	if err == nil {
		testing.expect(t, bytes.equal(bytes.buffer_to_bytes(&loaded.pixels), pixels))
		core_png.destroy(loaded)
	}

	path := "sancho_png_writer_test.png"
	defer os.remove(path)
	testing.expect(t, save(path, &img) == nil)
	from_file, file_err := core_png.load_from_file(path)
	testing.expect(t, file_err == nil)
	if file_err == nil {
		testing.expect(t, bytes.equal(bytes.buffer_to_bytes(&from_file.pixels), pixels))
		core_png.destroy(from_file)
	}
	testing.expect_value(t, save("no/such/folder/x.png", &img), Error(.Unable_To_Write_File))
}

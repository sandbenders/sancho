// SPDX-License-Identifier: 0BSD
package deflate

import "base:runtime"
import "core:bytes"
import "core:compress/zlib"
import "core:hash"
import "core:math/rand"
import "core:testing"

// Compresses, inflates with Odin's own reader and compares. Gives the compressed size.
@(private = "file")
inflates_back :: proc(t: ^testing.T, data: []u8, loc := #caller_location) -> int {
	packed := compress(data)
	defer delete(packed)
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	err := zlib.inflate(packed, &buf, true, len(data))
	testing.expectf(t, err == nil, "inflate failed: %v", err, loc = loc)
	testing.expectf(t, bytes.equal(bytes.buffer_to_bytes(&buf), data), "%d bytes came back different", len(data), loc = loc)
	return len(packed)
}

@(test)
test_nothing_and_single_bytes_round_trip :: proc(t: ^testing.T) {
	inflates_back(t, nil)
	inflates_back(t, {0})
	inflates_back(t, {255})
	inflates_back(t, {1, 2})
	inflates_back(t, {7, 7, 7}) // the shortest match there is, but nothing before it to match
}

@(test)
test_long_runs_shrink_to_almost_nothing :: proc(t: ^testing.T) {
	zeros := make([]u8, 1_000_000)
	defer delete(zeros)
	testing.expect(t, inflates_back(t, zeros) < 2_000)
	// Lengths around the longest match, 258.
	for n in ([?]int{3, 4, 257, 258, 259, 260, 516, 517}) {
		inflates_back(t, zeros[:n])
	}
}

@(test)
test_repeats_are_found_at_every_distance :: proc(t: ^testing.T) {
	data := make([dynamic]u8)
	defer delete(data)
	r := rand.create(7)
	piece := make([]u8, 300)
	defer delete(piece)
	for &b in piece {
		b = u8(rand.uint32(rand.default_random_generator(&r)))
	}
	// The piece again after gaps that reach every distance code, up to the edge of the window.
	for gap in ([?]int{0, 1, 5, 100, 1000, 10_000, 32_000, 32_468, 40_000}) {
		append(&data, ..piece)
		for _ in 0 ..< gap {
			append(&data, u8(len(data) % 251))
		}
	}
	append(&data, ..piece)
	size := inflates_back(t, data[:])
	testing.expect(t, size < len(data))
}

@(test)
test_what_does_not_compress_is_stored :: proc(t: ^testing.T) {
	data := make([]u8, 200_000)
	defer delete(data)
	r := rand.create(11)
	for &b in data {
		b = u8(rand.uint32(rand.default_random_generator(&r)))
	}
	size := inflates_back(t, data)
	// Stored, it costs 5 bytes for each 65535 at most (a chance match or two can
	// make a block a little longer and split it), so far less than a thousandth.
	testing.expectf(t, size <= len(data) + len(data) / 1000, "%d bytes", size)
}

@(test)
test_many_blocks_and_every_byte_value_round_trip :: proc(t: ^testing.T) {
	// More symbols than one block takes, with text-like repeats and all 256 values.
	data := make([dynamic]u8)
	defer delete(data)
	words := [?]string{"circle ", "at ", "radius ", "forward ", "right ", "repeat "}
	for i in 0 ..< 60_000 {
		append(&data, words[(i * 7 + i / 13) % len(words)])
		append(&data, u8(i % 256))
	}
	inflates_back(t, data[:])
}

@(test)
test_the_same_input_gives_the_same_bytes :: proc(t: ^testing.T) {
	data := fuzz_data(42)
	defer delete(data)
	a := compress(data)
	defer delete(a)
	b := compress(data)
	defer delete(b)
	testing.expect(t, bytes.equal(a, b))
}

@(test)
test_huffman_codes_stay_within_fifteen_bits :: proc(t: ^testing.T) {
	// Frequencies that grow like Fibonacci numbers make the deepest possible tree,
	// which has to be flattened to fit.
	freqs: [30]u32
	a, b := u32(1), u32(1)
	for &f in freqs {
		f = a
		a, b = b, a + b
	}
	data := make([dynamic]u8)
	defer delete(data)
	for f, s in freqs {
		for _ in 0 ..< min(f, 50_000) {
			append(&data, u8(s * 8))
		}
	}
	// Shuffled so runs do not turn into matches and every symbol stays a literal.
	r := rand.create(3)
	rand.shuffle(data[:], rand.default_random_generator(&r))
	inflates_back(t, data[:])
}

@(test)
test_the_zlib_stream_has_its_header_and_checksum :: proc(t: ^testing.T) {
	data := fuzz_data(5)
	defer delete(data)
	z := compress_zlib(data)
	defer delete(z)
	testing.expect_value(t, z[0], 0x78)
	testing.expect_value(t, (u16(z[0]) << 8 | u16(z[1])) % 31, 0) // the header check bits
	sum := hash.adler32(data)
	tail := z[len(z) - 4:]
	testing.expect_value(t, u32(tail[0]) << 24 | u32(tail[1]) << 16 | u32(tail[2]) << 8 | u32(tail[3]), sum)
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	err := zlib.inflate(z, &buf, false, len(data))
	testing.expect(t, err == nil)
	testing.expect(t, bytes.equal(bytes.buffer_to_bytes(&buf), data))
}

@(test)
test_the_working_memory_is_given_back :: proc(t: ^testing.T) {
	data := fuzz_data(9)
	defer delete(data)
	// The guard gives back what was taken from the default temporary allocator,
	// so the test uses that one even if the runner set another.
	context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
	_ = new(int, context.temp_allocator) // make sure it has a block to measure
	arena := &runtime.global_default_temp_allocator_data.arena
	before := arena.total_used
	packed := compress_zlib(data)
	delete(packed)
	testing.expect_value(t, arena.total_used, before)
	free_all(context.temp_allocator)
}

// Data of a random length made of random pieces: runs of one byte, copies of
// something earlier (near and far), bytes from a small alphabet, slow ramps and
// noise. Built from `seed` alone, so a failure is found again from the seed it prints.
fuzz_data :: proc(seed: u64) -> []u8 {
	r := rand.create(seed)
	gen := rand.default_random_generator(&r)
	size := int(rand.uint32(gen) % 120_000)
	if seed % 4 == 0 {
		size %= 600 // plenty of tiny inputs too
	}
	data := make([dynamic]u8, 0, size)
	for len(data) < size {
		n := min(size - len(data), 1 + int(rand.uint32(gen) % 700))
		switch rand.uint32(gen) % 5 {
		case 0: // a run
			b := u8(rand.uint32(gen))
			for _ in 0 ..< n {append(&data, b)}
		case 1: // a copy of something earlier, possibly overlapping itself
			if len(data) == 0 {
				append(&data, u8(rand.uint32(gen)))
				continue
			}
			from := len(data) - 1 - int(rand.uint32(gen) % u32(min(len(data), 40_000)))
			for k in 0 ..< n {append(&data, data[from + k])}
		case 2: // a small alphabet, like text
			for _ in 0 ..< n {append(&data, 'a' + u8(rand.uint32(gen) % 6))}
		case 3: // a slow ramp, like a gradient
			start := rand.uint32(gen)
			for k in 0 ..< n {append(&data, u8(start + u32(k / 7)))}
		case: // noise
			for _ in 0 ..< n {append(&data, u8(rand.uint32(gen)))}
		}
	}
	return data[:]
}

@(test)
test_generated_data_round_trips :: proc(t: ^testing.T) {
	for seed in u64(1) ..= 300 {
		data := fuzz_data(seed)
		defer delete(data)
		packed := compress(data)
		defer delete(packed)
		buf: bytes.Buffer
		defer bytes.buffer_destroy(&buf)
		err := zlib.inflate(packed, &buf, true, len(data))
		if !testing.expectf(t, err == nil && bytes.equal(bytes.buffer_to_bytes(&buf), data), "seed %d (%d bytes): %v", seed, len(data), err) {
			return
		}
	}
}

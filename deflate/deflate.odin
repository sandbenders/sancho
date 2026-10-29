// SPDX-License-Identifier: 0BSD
//
// A deflate compressor (RFC 1951) and its zlib wrapper (RFC 1950). Odin's
// core:compress/zlib only inflates; this is the other half.
//
// Matches are found with hash chains over a 32 KiB window, lazily, as zlib's
// level 6 finds them, and each block is written in whichever of its three forms
// is smallest: Huffman codes made for that block, the fixed codes, or stored as
// it is. Everything is decided by the data alone (ties go to the earlier
// choice), so the same input always gives the same bytes, on every system.
package deflate

import "base:runtime"
import "core:hash"
import "core:slice"

@(private = "file") WINDOW :: 32768
@(private = "file") HASH_BITS :: 15
@(private = "file") MAX_CHAIN :: 128 // how many earlier places with the same three bytes are tried (zlib's level 6 tries as many)
@(private = "file") LAZY_LIMIT :: 32 // a match this long is taken without trying the next place
@(private = "file") MIN_MATCH :: 3
@(private = "file") MAX_MATCH :: 258
@(private = "file") BLOCK_TOKENS :: 65535 // symbols in a block before a new one starts: all literals still fit one stored block
@(private = "file") END_OF_BLOCK :: 256

@(private = "file")
LENGTH_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private = "file")
LENGTH_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private = "file")
DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private = "file")
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
// The order the lengths of the code-length code are written in.
@(private = "file")
CODE_LENGTH_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

// A literal byte (`distance` 0) or a match of `value` bytes `distance` back.
@(private = "file")
Token :: struct {
	value:    u16,
	distance: u16,
}

@(private = "file")
Bit_Writer :: struct {
	out:   ^[dynamic]u8,
	bits:  u64,
	count: uint,
}

@(private = "file")
put_bits :: proc(w: ^Bit_Writer, value: u32, n: uint) {
	w.bits |= u64(value) << w.count
	w.count += n
	for w.count >= 8 {
		append(w.out, u8(w.bits))
		w.bits >>= 8
		w.count -= 8
	}
}

@(private = "file")
align_to_byte :: proc(w: ^Bit_Writer) {
	if w.count > 0 {
		put_bits(w, 0, 8 - w.count)
	}
}

// The length code (257 to 285) of a match length, and the distance code of a distance.
@(private = "file")
length_code :: proc(length: u16) -> int {
	code := 28
	for code > 0 && LENGTH_BASE[code] > length {
		code -= 1
	}
	return code
}

@(private = "file")
distance_code :: proc(distance: u16) -> int {
	code := 29
	for code > 0 && DIST_BASE[code] > distance {
		code -= 1
	}
	return code
}

// Raw deflate data of `data` (no zlib header or checksum), in `allocator`. The
// working memory is temporary and given back before it returns.
//
// Matching is lazy, as zlib's is: a match found at one place is held back while
// the next place is tried, and when that one is longer the first byte goes out
// as a literal instead. Long matches are taken at once (LAZY_LIMIT).
compress :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	out := make([dynamic]u8, 0, len(data) / 4 + 64, allocator)
	m := Matcher{
		data   = data,
		head   = make([]i32, 1 << HASH_BITS, context.temp_allocator),
		prev   = make([]i32, WINDOW, context.temp_allocator),
		tokens = make([dynamic]Token, 0, BLOCK_TOKENS, context.temp_allocator),
		w      = Bit_Writer{out = &out},
	}
	slice.fill(m.head, -1)

	held := false // a match starting at i - 1 waits to see whether i has a longer one
	held_length, held_distance := 0, 0
	for i := 0; i < len(data); i += 1 {
		length, distance := longest_match(&m, i, held_length if held else 0)
		insert(&m, i)
		switch {
		case held && length > held_length:
			emit(&m, Token{u16(data[i - 1]), 0}, 1)
			held_length, held_distance = length, distance
		case held:
			emit(&m, Token{u16(held_length), u16(held_distance)}, held_length)
			// The match began at i - 1 and i is in already; add the rest.
			for k in i + 1 ..< i - 1 + held_length {
				insert(&m, k)
			}
			i += held_length - 2
			held = false
		case length >= MIN_MATCH && length < LAZY_LIMIT:
			held, held_length, held_distance = true, length, distance
		case length >= MIN_MATCH:
			emit(&m, Token{u16(length), u16(distance)}, length)
			for k in i + 1 ..< i + length {
				insert(&m, k)
			}
			i += length - 1
		case:
			emit(&m, Token{u16(data[i]), 0}, 1)
		}
	}
	if held {
		emit(&m, Token{u16(held_length), u16(held_distance)}, held_length)
	}
	write_block(&m.w, m.tokens[:], data[m.block_start:], true)
	align_to_byte(&m.w)
	return out[:]
}

// A zlib stream of `data`: a two-byte header, the deflate data and the Adler-32 of
// `data`, which is what `core:compress/zlib.inflate` reads by default and what
// PNG files hold.
compress_zlib :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	raw := compress(data, context.temp_allocator)
	out := make([]u8, len(raw) + 6, allocator)
	out[0], out[1] = 0x78, 0x01 // deflate with a 32 KiB window; no preset dictionary
	copy(out[2:], raw)
	sum := hash.adler32(data)
	out[len(out) - 4], out[len(out) - 3], out[len(out) - 2], out[len(out) - 1] = u8(sum >> 24), u8(sum >> 16), u8(sum >> 8), u8(sum)
	return out
}

// What finding matches and cutting blocks needs to keep between bytes.
@(private = "file")
Matcher :: struct {
	data:        []u8,
	head:        []i32, // the latest place for each hash of three bytes, or -1
	prev:        []i32, // for each place in the window, the place before it with the same hash
	tokens:      [dynamic]Token,
	w:           Bit_Writer,
	block_start: int, // the first byte of the block being collected
	done:        int, // how many bytes the tokens so far stand for
}

@(private = "file")
hash3 :: proc(data: []u8, i: int) -> int {
	return (int(data[i]) << 10 ~ int(data[i + 1]) << 5 ~ int(data[i + 2])) & (1 << HASH_BITS - 1)
}

@(private = "file")
insert :: proc(m: ^Matcher, i: int) {
	if i + MIN_MATCH <= len(m.data) {
		h := hash3(m.data, i)
		m.prev[i & (WINDOW - 1)] = m.head[h]
		m.head[h] = i32(i)
	}
}

// The longest match for the bytes at `i` among earlier places, if it is longer
// than `beat` (0 takes any of at least three bytes).
@(private = "file")
longest_match :: proc(m: ^Matcher, i, beat: int) -> (length, distance: int) {
	data := m.data
	if i + MIN_MATCH > len(data) {
		return
	}
	limit := min(MAX_MATCH, len(data) - i)
	best := max(beat, MIN_MATCH - 1)
	if best >= limit {
		return
	}
	candidate := int(m.head[hash3(data, i)])
	for chain := 0; chain < MAX_CHAIN && candidate >= 0 && i - candidate <= WINDOW; chain += 1 {
		// The byte that would make this one longer than the best is checked first.
		if data[candidate + best] == data[i + best] {
			n := 0
			for n < limit && data[candidate + n] == data[i + n] {
				n += 1
			}
			if n > best {
				best, length, distance = n, n, i - candidate
				if n == limit {break}
			}
		}
		next := int(m.prev[candidate & (WINDOW - 1)])
		if next >= candidate {break} // the slot was reused by a newer place
		candidate = next
	}
	return
}

// Adds a token standing for `covers` bytes, and writes the block when it is full.
@(private = "file")
emit :: proc(m: ^Matcher, t: Token, covers: int) {
	append(&m.tokens, t)
	m.done += covers
	if len(m.tokens) == BLOCK_TOKENS {
		write_block(&m.w, m.tokens[:], m.data[m.block_start:m.done], false)
		clear(&m.tokens)
		m.block_start = m.done
	}
}

// One block in its smallest form. `raw` is the data its tokens stand for.
@(private = "file")
write_block :: proc(w: ^Bit_Writer, tokens: []Token, raw: []u8, last: bool) {
	lit_freq: [286]u32
	dist_freq: [30]u32
	for t in tokens {
		if t.distance == 0 {
			lit_freq[t.value] += 1
		} else {
			lit_freq[257 + length_code(t.value)] += 1
			dist_freq[distance_code(t.distance)] += 1
		}
	}
	lit_freq[END_OF_BLOCK] = 1

	lit_len: [286]u8
	dist_len: [30]u8
	huffman_lengths(lit_freq[:], 15, lit_len[:])
	huffman_lengths(dist_freq[:], 15, dist_len[:])
	header := code_lengths_header(lit_len[:], dist_len[:])

	fixed_lit, fixed_dist := fixed_lengths()
	dynamic_bits := 3 + header.bits + body_bits(lit_freq[:], dist_freq[:], lit_len[:], dist_len[:])
	fixed_bits := 3 + body_bits(lit_freq[:], dist_freq[:], fixed_lit[:], fixed_dist[:])
	// Stored: the header bits, up to 7 to reach a byte, then 4 bytes of length for each 65535.
	stored_bits := 3 + 7 + (len(raw) / 65535 + 1) * 32 + len(raw) * 8

	switch {
	case stored_bits < dynamic_bits && stored_bits < fixed_bits:
		write_stored(w, raw, last)
	case fixed_bits <= dynamic_bits:
		put_bits(w, 1 if last else 0, 1)
		put_bits(w, 1, 2)
		write_tokens(w, tokens, fixed_lit[:], fixed_dist[:])
	case:
		put_bits(w, 1 if last else 0, 1)
		put_bits(w, 2, 2)
		write_header(w, header)
		write_tokens(w, tokens, lit_len[:], dist_len[:])
	}
}

@(private = "file")
write_stored :: proc(w: ^Bit_Writer, raw: []u8, last: bool) {
	offset := 0
	for {
		n := min(len(raw) - offset, 65535)
		final := offset + n >= len(raw)
		put_bits(w, 1 if last && final else 0, 1)
		put_bits(w, 0, 2)
		align_to_byte(w)
		put_bits(w, u32(n), 16)
		put_bits(w, u32(~u16(n)), 16)
		append(w.out, ..raw[offset:offset + n])
		offset += n
		if final {break}
	}
}

@(private = "file")
fixed_lengths :: proc() -> (lit: [288]u8, dist: [30]u8) {
	for i in 0 ..< 288 {
		switch {
		case i < 144: lit[i] = 8
		case i < 256: lit[i] = 9
		case i < 280: lit[i] = 7
		case:         lit[i] = 8
		}
	}
	for i in 0 ..< 30 {
		dist[i] = 5
	}
	return
}

// The bits the symbols of a block take with these code lengths, extra bits included.
@(private = "file")
body_bits :: proc(lit_freq, dist_freq: []u32, lit_len, dist_len: []u8) -> int {
	bits := 0
	for f, s in lit_freq {
		bits += int(f) * int(lit_len[s])
		if s > 256 {
			bits += int(f) * int(LENGTH_EXTRA[s - 257])
		}
	}
	for f, s in dist_freq {
		bits += int(f) * (int(dist_len[s]) + int(DIST_EXTRA[s]))
	}
	return bits
}

// Canonical codes for code lengths (RFC 1951 3.2.2), bit-reversed so they can be
// written lowest bit first.
@(private = "file")
canonical_codes :: proc(lengths: []u8, codes: []u16) {
	count: [16]u16
	for l in lengths {
		count[l] += 1
	}
	count[0] = 0
	next: [16]u16
	code: u16 = 0
	for bits in 1 ..< 16 {
		code = (code + count[bits - 1]) << 1
		next[bits] = code
	}
	for l, s in lengths {
		if l == 0 {continue}
		c := next[l]
		next[l] += 1
		reversed: u16 = 0
		for _ in 0 ..< l {
			reversed = reversed << 1 | c & 1
			c >>= 1
		}
		codes[s] = reversed
	}
}

@(private = "file")
write_tokens :: proc(w: ^Bit_Writer, tokens: []Token, lit_len, dist_len: []u8) {
	lit_code := make([]u16, len(lit_len), context.temp_allocator)
	dist_code: [30]u16
	canonical_codes(lit_len, lit_code)
	canonical_codes(dist_len, dist_code[:])
	for t in tokens {
		if t.distance == 0 {
			put_bits(w, u32(lit_code[t.value]), uint(lit_len[t.value]))
			continue
		}
		lc := length_code(t.value)
		put_bits(w, u32(lit_code[257 + lc]), uint(lit_len[257 + lc]))
		put_bits(w, u32(t.value - LENGTH_BASE[lc]), uint(LENGTH_EXTRA[lc]))
		dc := distance_code(t.distance)
		put_bits(w, u32(dist_code[dc]), uint(dist_len[dc]))
		put_bits(w, u32(t.distance - DIST_BASE[dc]), uint(DIST_EXTRA[dc]))
	}
	put_bits(w, u32(lit_code[END_OF_BLOCK]), uint(lit_len[END_OF_BLOCK]))
}

// ---- the header of a block with its own codes ----

@(private = "file")
Header :: struct {
	hlit, hdist, hclen: int,
	symbols:  [dynamic]u16, // code-length symbols 0 to 18, each followed by its extra bits in `extras`
	extras:   [dynamic]u8,
	cl_len:   [19]u8,
	bits:     int, // what the header takes
}

@(private = "file")
code_lengths_header :: proc(lit_len, dist_len: []u8) -> (h: Header) {
	h.hlit = 286
	for h.hlit > 257 && lit_len[h.hlit - 1] == 0 {
		h.hlit -= 1
	}
	h.hdist = 30
	for h.hdist > 1 && dist_len[h.hdist - 1] == 0 {
		h.hdist -= 1
	}
	all := make([]u8, h.hlit + h.hdist, context.temp_allocator)
	copy(all, lit_len[:h.hlit])
	copy(all[h.hlit:], dist_len[:h.hdist])
	h.symbols = make([dynamic]u16, context.temp_allocator)
	h.extras = make([dynamic]u8, context.temp_allocator)
	// Runs: 16 repeats the last length 3 to 6 times, 17 and 18 write 3 to 10 and 11 to 138 zeros.
	for i := 0; i < len(all); {
		l := all[i]
		run := 1
		for i + run < len(all) && all[i + run] == l {
			run += 1
		}
		i += run
		if l == 0 {
			for run >= 11 {
				n := min(run, 138)
				append(&h.symbols, 18)
				append(&h.extras, u8(n - 11))
				run -= n
			}
			if run >= 3 {
				append(&h.symbols, 17)
				append(&h.extras, u8(run - 3))
				run = 0
			}
		} else {
			append(&h.symbols, u16(l))
			append(&h.extras, 0)
			run -= 1
			for run >= 3 {
				n := min(run, 6)
				append(&h.symbols, 16)
				append(&h.extras, u8(n - 3))
				run -= n
			}
		}
		for _ in 0 ..< run {
			append(&h.symbols, u16(l))
			append(&h.extras, 0)
		}
	}
	cl_freq: [19]u32
	for s in h.symbols {
		cl_freq[s] += 1
	}
	huffman_lengths(cl_freq[:], 7, h.cl_len[:])
	h.hclen = 19
	for h.hclen > 4 && h.cl_len[CODE_LENGTH_ORDER[h.hclen - 1]] == 0 {
		h.hclen -= 1
	}
	h.bits = 5 + 5 + 4 + 3 * h.hclen
	for s in h.symbols {
		h.bits += int(h.cl_len[s])
		switch s {
		case 16: h.bits += 2
		case 17: h.bits += 3
		case 18: h.bits += 7
		}
	}
	return
}

@(private = "file")
write_header :: proc(w: ^Bit_Writer, h: Header) {
	put_bits(w, u32(h.hlit - 257), 5)
	put_bits(w, u32(h.hdist - 1), 5)
	put_bits(w, u32(h.hclen - 4), 4)
	for i in 0 ..< h.hclen {
		put_bits(w, u32(h.cl_len[CODE_LENGTH_ORDER[i]]), 3)
	}
	cl_len := h.cl_len
	cl_code: [19]u16
	canonical_codes(cl_len[:], cl_code[:])
	for s, i in h.symbols {
		put_bits(w, u32(cl_code[s]), uint(h.cl_len[s]))
		switch s {
		case 16: put_bits(w, u32(h.extras[i]), 2)
		case 17: put_bits(w, u32(h.extras[i]), 3)
		case 18: put_bits(w, u32(h.extras[i]), 7)
		}
	}
}

// ---- Huffman code lengths ----

// Code lengths for these frequencies, none longer than `max_bits`. At least two
// symbols always get a code (the first unused ones are added), because a code of
// one symbol is a case decoders handle differently. When the tree is too deep,
// the frequencies are halved and it is built again, which flattens it.
@(private = "file")
huffman_lengths :: proc(freqs: []u32, max_bits: int, lengths: []u8) {
	f := make([]u32, len(freqs), context.temp_allocator)
	copy(f, freqs)
	used := 0
	for x in f {
		if x > 0 {used += 1}
	}
	for s := 0; used < 2 && s < len(f); s += 1 {
		if f[s] == 0 {
			f[s] = 1
			used += 1
		}
	}
	for {
		if build_lengths(f, lengths) <= max_bits {
			return
		}
		for &x in f {
			if x > 0 {x = max(1, x / 2)}
		}
	}
}

// Builds the tree with two queues (the leaves sorted by frequency, then by symbol,
// and the joined nodes in the order they are made) and gives its depth.
@(private = "file")
build_lengths :: proc(freqs: []u32, lengths: []u8) -> int {
	Node :: struct {
		freq:   u64,
		parent: int,
	}
	leaves := make([dynamic]int, context.temp_allocator)
	for x, s in freqs {
		lengths[s] = 0
		if x > 0 {append(&leaves, s)}
	}
	// A stable sort keeps the symbols in order among equal frequencies.
	context.user_ptr = raw_data(freqs)
	slice.stable_sort_by(leaves[:], proc(a, b: int) -> bool {
		f := ([^]u32)(context.user_ptr)
		return f[a] < f[b]
	})
	nodes := make([dynamic]Node, context.temp_allocator)
	for s in leaves {
		append(&nodes, Node{u64(freqs[s]), -1})
	}
	n := len(leaves)
	li, ni := 0, n // the next leaf, the next joined node
	take :: proc(nodes: []Node, li, ni: ^int, n: int) -> int {
		if li^ < n && (ni^ >= len(nodes) || nodes[li^].freq <= nodes[ni^].freq) {
			li^ += 1
			return li^ - 1
		}
		ni^ += 1
		return ni^ - 1
	}
	for len(nodes) < 2 * n - 1 {
		a := take(nodes[:], &li, &ni, n)
		b := take(nodes[:], &li, &ni, n)
		append(&nodes, Node{nodes[a].freq + nodes[b].freq, -1})
		nodes[a].parent = len(nodes) - 1
		nodes[b].parent = len(nodes) - 1
	}
	deepest := 0
	for s, i in leaves {
		depth := 0
		for p := nodes[i].parent; p >= 0; p = nodes[p].parent {
			depth += 1
		}
		lengths[s] = u8(min(depth, 255))
		deepest = max(deepest, depth)
	}
	return deepest
}

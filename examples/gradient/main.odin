// SPDX-License-Identifier: 0BSD
//
// Saves gradient.png, a 256 x 256 RGB gradient made as a core:image Image, and
// grey16.png, a 16-bit grey ramp made from plain pixels.
// Run from the repository root: odin run examples/gradient
package main

import "core:bytes"
import "core:fmt"
import "core:image"
import "core:os"
import "core:slice"

import png "../../png_writer"

main :: proc() {
	img := image.Image{width = 256, height = 256, channels = 3, depth = 8}
	defer bytes.buffer_destroy(&img.pixels)
	for y in 0 ..< 256 {
		for x in 0 ..< 256 {
			bytes.buffer_write(&img.pixels, []u8{u8(x), u8(y), u8(255 - x)})
		}
	}
	if err := png.save("gradient.png", &img); err != nil {
		fmt.eprintln("could not save gradient.png:", err)
		os.exit(1)
	}

	// 16-bit samples are in the machine's byte order, as core:image keeps them.
	grey := make([]u16, 256 * 256)
	defer delete(grey)
	for &v, i in grey {
		v = u16(i % 256 * 257)
	}
	data, err := png.encode(slice.to_bytes(grey), 256, 256, channels = 1, depth = 16)
	defer delete(data)
	if err != nil || os.write_entire_file("grey16.png", data) != nil {
		fmt.eprintln("could not save grey16.png:", err)
		os.exit(1)
	}
	fmt.println("wrote gradient.png and grey16.png")
}

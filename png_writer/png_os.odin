// SPDX-License-Identifier: 0BSD
#+build !js
package png_writer

import "core:bytes"
import "core:os"

save :: proc{save_to_buffer, save_to_file}

// Writes a PNG of `img` to the file at `output`, replacing it.
save_to_file :: proc(output: string, img: ^Image, options := Options{}, filters := Filters.Smallest, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator

	out := &bytes.Buffer{}
	defer bytes.buffer_destroy(out)

	save_to_buffer(out, img, options, filters) or_return
	write_err := os.write_entire_file(output, out.buf[:])

	return nil if write_err == nil else .Unable_To_Write_File
}

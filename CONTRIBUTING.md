# Contributing to sancho

Thank you for helping. Issues and pull requests are welcome on GitHub.

## Before you start

- **Bugs**: open an issue with the smallest input that shows the problem. For a picture, the width, height, channels and depth and how its pixels were made are usually enough; for a test failure, the seed it prints.
- **New features** (palette images, ancillary chunks, compression levels, streaming): open an issue first, so we agree on the shape before you write it. sancho so it keeps Odin's `core:image`'s conventions and stays free of dependencies.

## Making a change

1. Use the Odin release named in the README (currently `dev-2026-10`).
2. Write the tests with the code. Every output is checked by reading it back with Odin's own readers (`core:compress/zlib`, `core:image/png`), never only by comparing with bytes we wrote ourselves.
3. Keep output deterministic: nothing may depend on addresses, map order, threads or time, and ties must always go the same way.
4. Run everything as the pipeline does:

   ```sh
   odin test deflate -vet -strict-style
   odin test png_writer -vet -strict-style
   odin test deflate -o:speed
   odin test png_writer -o:speed
   odin build examples/gradient -vet -strict-style
   ```

5. Follow Odin's own style (tabs, `snake_case` procedures, `Ada_Case` types), and write comments that say what the code does and why, in plain words.
6. Add a line to the "Unreleased" part of `CHANGELOG.md` (start one at the top if there is none).

## Size and speed

If a change is about compression, say what it does to size and time, and on which pictures or data. The README's table is the baseline; a change that makes files bigger or slower needs a good reason.

## Licence

sancho is under the [Zero-Clause BSD licence](LICENSE). By contributing you agree that your contribution is under the same licence.

# CWebP: libwebp's encoder, vendored

Google's libwebp **v1.6.0** (tag `v1.6.0`, commit
`4fa21912338357f89e4fd51cf2368325b59e9bd9`), from
https://github.com/webmproject/libwebp. BSD-3-Clause: see `COPYING` and
`PATENTS` here, and the notice in `THIRD-PARTY-LICENSES.txt`.

It is here because macOS reads WebP but has no WebP encoder, and the shelf
needs to write one. Only the encoder is copied, unchanged:

- `src/enc`, `src/utils`, `src/dsp` (all of them, less the MIPS files, which
  never build on a Mac), and `sharpyuv`, which the encoder's sharp RGB to YUV
  conversion calls.
- From `src/dec`, the headers only: some `dsp` files include them for shared
  tables and declarations. No decoder `.c` file is compiled.
- From `src/webp`, the public headers the above include: `encode.h`,
  `types.h`, `decode.h`, `format_constants.h`, `mux_types.h`.

Nothing else upstream ships (decoder, mux, demux, examples, build scripts)
is here. `include/CWebP.h` is ours: the one header Swift imports, which pulls
in `src/webp/encode.h`.

SIMD needs no switches. Without `HAVE_CONFIG_H`, libwebp turns NEON on for
arm64 and SSE2 on for x86_64 from the compiler's own defines, and the SSE4.1
and AVX2 files compile to nothing unless the target enables them.

To update: copy the same folders from a newer tag over these, keep the file
list the same unless the encoder needs a new one, and change the version above.

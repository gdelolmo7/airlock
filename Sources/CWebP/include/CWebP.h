#ifndef CWEBP_H
#define CWEBP_H

// The one header Swift sees. It is libwebp's own encoder header, untouched,
// which declares `WebPEncodeRGBA`, `WebPEncodeLosslessRGBA` and `WebPFree`
// (and the rest of the encoder's API, which the app does not call). The
// decoder's functions are not compiled in: ImageIO reads WebP already.
#include "../src/webp/encode.h"

#endif  // CWEBP_H

// Simplified libpng fuzzer harness for Angora/DFSan compatibility.
// Avoids nalloc.h (uses __libc_reallocarray / variadic function pointers that
// DFSan clang-11 cannot resolve).
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include "png.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 8)
        return 0;

    png_image image;
    memset(&image, 0, sizeof(image));
    image.version = PNG_IMAGE_VERSION;

    if (!png_image_begin_read_from_memory(&image, data, size))
        return 0;

    image.format = PNG_FORMAT_RGBA;
    png_uint_32 stride = PNG_IMAGE_ROW_STRIDE(image);
    size_t buf_size = PNG_IMAGE_BUFFER_SIZE(image, stride);

    void *buf = malloc(buf_size);
    if (buf) {
        png_image_finish_read(&image, NULL, buf, stride, NULL);
        free(buf);
    }

    png_image_free(&image);
    return 0;
}

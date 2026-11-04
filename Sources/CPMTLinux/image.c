#include "PMTImage.h"
#include <png.h>
#include <stdlib.h>
#include <string.h>

#define PMT_MAX_ENCODED_BYTES ((size_t)268435456)
#define PMT_MAX_PIXELS ((uint64_t)64000000)

static uint32_t read_u32(const uint8_t *value) {
    return ((uint32_t)value[0] << 24) | ((uint32_t)value[1] << 16) |
           ((uint32_t)value[2] << 8) | value[3];
}

/* Libpng ohne APNG-Erweiterung würde sonst nur das statische Vorschaubild liefern. */
static int inspect_chunks(const uint8_t *bytes, size_t count) {
    size_t offset = 8;
    while (offset < count) {
        if (count - offset < 12) return PMT_IMAGE_INVALID;
        uint32_t length = read_u32(bytes + offset);
        if ((size_t)length > count - offset - 12) return PMT_IMAGE_INVALID;
        const uint8_t *type = bytes + offset + 4;
        if (memcmp(type, "acTL", 4) == 0) return PMT_IMAGE_UNSUPPORTED;
        offset += (size_t)length + 12;
        if (memcmp(type, "IEND", 4) == 0) return PMT_IMAGE_OK;
    }
    return PMT_IMAGE_INVALID;
}

enum pmt_image_status pmt_validate_png(const uint8_t *bytes, size_t count, struct pmt_image_info *info) {
    static const uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (info == NULL) return PMT_IMAGE_INVALID;
    memset(info, 0, sizeof(*info));
    if (count > PMT_MAX_ENCODED_BYTES) return PMT_IMAGE_TOO_LARGE;
    if (bytes == NULL || count < sizeof(signature) ||
        memcmp(bytes, signature, sizeof(signature)) != 0) return PMT_IMAGE_UNSUPPORTED;
    int chunks = inspect_chunks(bytes, count);
    if (chunks != PMT_IMAGE_OK) return chunks;

    png_image image;
    memset(&image, 0, sizeof(image));
    image.version = PNG_IMAGE_VERSION;
    if (!png_image_begin_read_from_memory(&image, bytes, count)) {
        png_image_free(&image);
        return PMT_IMAGE_INVALID;
    }
    if (image.width == 0 || image.height == 0 ||
        (uint64_t)image.width * image.height > PMT_MAX_PIXELS) {
        png_image_free(&image);
        return PMT_IMAGE_TOO_LARGE;
    }
    image.format = PNG_FORMAT_RGBA;
    /* Dimensionen werden vor der einzigen Pixelpuffer-Allokation begrenzt. */
    size_t decoded_bytes = (size_t)image.width * image.height * 4;
    void *pixels = malloc(decoded_bytes);
    if (pixels == NULL) {
        png_image_free(&image);
        return PMT_IMAGE_OUT_OF_MEMORY;
    }
    int success = png_image_finish_read(&image, NULL, pixels, 0, NULL);
    free(pixels);
    if (!success) {
        png_image_free(&image);
        return PMT_IMAGE_INVALID;
    }
    info->width = image.width;
    info->height = image.height;
    info->frame_count = 1;
    png_image_free(&image);
    return PMT_IMAGE_OK;
}

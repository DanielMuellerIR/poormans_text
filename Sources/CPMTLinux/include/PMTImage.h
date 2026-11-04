#ifndef PMT_IMAGE_H
#define PMT_IMAGE_H

#include <stddef.h>
#include <stdint.h>

enum pmt_image_status {
    PMT_IMAGE_OK = 0,
    PMT_IMAGE_UNSUPPORTED = 1,
    PMT_IMAGE_INVALID = 2,
    PMT_IMAGE_TOO_LARGE = 3,
    PMT_IMAGE_OUT_OF_MEMORY = 4
};

struct pmt_image_info {
    uint32_t width;
    uint32_t height;
    uint32_t frame_count;
};

/* Dekodiert statisches PNG vollständig; Ausgabepixel bleiben nicht erhalten. */
enum pmt_image_status pmt_validate_png(const uint8_t *bytes, size_t count, struct pmt_image_info *info);

#endif

/*
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#ifndef TURBORES_H
#define TURBORES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TurboresDecoder TurboresDecoder;
typedef struct TurboresFrame TurboresFrame;

/*
 * Planar YUV(A) pixel formats. I420, I422 and I444 indicate 4:2:0, 4:2:2 and 4:4:4 chroma subsampling respectively,
 * an A indicates an additional alpha plane, and P10/P12 indicate 10/12-bit samples (8-bit otherwise).
 */
typedef enum TurboresPixelFormat {
    TURBORES_PIXEL_FORMAT_I420 = 0,
    TURBORES_PIXEL_FORMAT_I420P10 = 1,
    TURBORES_PIXEL_FORMAT_I420P12 = 2,
    TURBORES_PIXEL_FORMAT_I420A = 3,
    TURBORES_PIXEL_FORMAT_I420AP10 = 4,
    TURBORES_PIXEL_FORMAT_I420AP12 = 5,
    TURBORES_PIXEL_FORMAT_I422 = 6,
    TURBORES_PIXEL_FORMAT_I422P10 = 7,
    TURBORES_PIXEL_FORMAT_I422P12 = 8,
    TURBORES_PIXEL_FORMAT_I422A = 9,
    TURBORES_PIXEL_FORMAT_I422AP10 = 10,
    TURBORES_PIXEL_FORMAT_I422AP12 = 11,
    TURBORES_PIXEL_FORMAT_I444 = 12,
    TURBORES_PIXEL_FORMAT_I444P10 = 13,
    TURBORES_PIXEL_FORMAT_I444P12 = 14,
    TURBORES_PIXEL_FORMAT_I444A = 15,
    TURBORES_PIXEL_FORMAT_I444AP10 = 16,
    TURBORES_PIXEL_FORMAT_I444AP12 = 17
} TurboresPixelFormat;

typedef enum TurboresScanType {
    TURBORES_SCAN_TYPE_PROGRESSIVE = 0,
    TURBORES_SCAN_TYPE_INTERLACED_TOP_FIELD_FIRST = 1,
    TURBORES_SCAN_TYPE_INTERLACED_BOTTOM_FIELD_FIRST = 2
} TurboresScanType;

/* Negative return values of turbores_decode */
typedef enum TurboresError {
    TURBORES_ERROR_OUT_OF_MEMORY = -1,
    TURBORES_ERROR_UNEXPECTED_EOF = -2,
    TURBORES_ERROR_INVALID_DATA = -3,
    TURBORES_ERROR_NOT_SUPPORTED = -4,
    TURBORES_ERROR_INVALID_STATE = -5,
    TURBORES_ERROR_OVERFLOW = -6
} TurboresError;

/* Pass as allowed_output_formats to allow every output format */
#define TURBORES_ALL_PIXEL_FORMATS ((uint32_t) -1)

/*
 * Creates a new decoder. Returns NULL on allocation failure.
 *
 * `concurrency`: The number of threads used for packet decoding. The library manages a single internal thread pool
 * shared across all decoders, spun up on decoder creation. Pass 0 to automatically pick a concurrency based on the
 * number of logical CPU cores.
 *
 * `bit_depth`: 10 or 12. You can derive this from the ProRes FourCC: 12 for 'ap4x' and 'ap4h', 10 otherwise.
 *
 * `allowed_output_formats`: A non-zero bit field of allowed output formats, where each `TurboresPixelFormat` value
 * contributes the bit `(1u << format)`. Pass `TURBORES_ALL_PIXEL_FORMATS` to allow all formats. When a frame's native
 * format is not allowed, the decoder picks the best allowed alternative, preferring lossless conversions.
 */
TurboresDecoder *turbores_decoder_create(uint32_t concurrency, uint32_t bit_depth, uint32_t allowed_output_formats);

/*
 * Decodes one ProRes packet into the given frame, blocking until the frame is fully decoded. The packet data is
 * is not copied and must stay alive for the duration of this call. Returns 0 on success or a negative `TurboresError`
 * value on failure; in the failure case, turbores_decoder_error_message_ptr may provide details.
 *
 * A decoder must not be used from multiple threads at once.
 */
int32_t turbores_decode(
    TurboresDecoder *decoder,
    TurboresFrame *frame,
    const uint8_t *packet_data,
    size_t packet_size
);

/* Returns a pointer to the UTF-8 error message of the last failed decode, or NULL if there is none. Not terminated. */
const uint8_t *turbores_decoder_error_message_ptr(TurboresDecoder *decoder);

/* Returns the byte length of the error message. */
size_t turbores_decoder_error_message_size(TurboresDecoder *decoder);

/* Frees the decoder and all its internal resources. */
void turbores_decoder_destroy(TurboresDecoder *decoder);

/*
 * Creates a new, empty frame for decoders to decode into. Returns NULL on allocation failure. Frames are reusable
 * across decodes; the frame data buffer is owned by the frame and reallocated as needed.
 */
TurboresFrame *turbores_frame_create(void);

/* Frees the frame and its frame data. */
void turbores_frame_destroy(TurboresFrame *frame);

/*
 * Returns a pointer to the decoded planar YUV(A) data, tightly packed plane after plane at the frame's coded
 * dimensions. Samples are uint8_t for 8-bit formats and native-endian uint16_t for 10/12-bit formats. Valid until
 * the next decode into this frame or until `turbores_frame_destroy`.
 */
uint8_t *turbores_frame_data_ptr(TurboresFrame *frame);

/* Returns the byte length of the frame data. */
size_t turbores_frame_data_size(TurboresFrame *frame);

/* The frame's pixel format as a `TurboresPixelFormat` value. */
uint32_t turbores_frame_pixel_format(TurboresFrame *frame);

/*
 * The pixel format the frame's packet natively was in, as a `TurboresPixelFormat` value. Can differ from the frame's
 * pixel format when `allowed_output_formats` forced a conversion.
 */
uint32_t turbores_frame_original_pixel_format(TurboresFrame *frame);

uint32_t turbores_frame_visible_width(TurboresFrame *frame);
uint32_t turbores_frame_visible_height(TurboresFrame *frame);
uint32_t turbores_frame_coded_width(TurboresFrame *frame);
uint32_t turbores_frame_coded_height(TurboresFrame *frame);

/* The numerator of the frame's pixel aspect ratio. The ratio is typically 1:1. */
uint32_t turbores_frame_aspect_ratio_num(TurboresFrame *frame);

/* The denominator of the frame's pixel aspect ratio. */
uint32_t turbores_frame_aspect_ratio_den(TurboresFrame *frame);

/*
 * The color primaries of the decoded frame's color space, as defined by ISO/IEC 23091-2. Common values are:
 *
 * 0 - Unknown/unspecified
 * 1 - ITU-R BT.709
 * 2 - Unknown/unspecified
 * 5 - ITU-R BT.601 625
 * 6 - ITU-R BT.601 525
 * 9 - ITU-R BT.2020
 * 11 - DCI P3
 * 12 - P3 D65
 */
uint32_t turbores_frame_color_primaries(TurboresFrame *frame);

/*
 * The color transfer function of the decoded frame's color space, as defined by ISO/IEC 23091-2. Common values are:
 *
 * 0 - Unknown/unspecified
 * 1 - ITU-R BT.601/BT.709/BT.2020
 * 2 - Unknown/unspecified
 * 6 - ITU-R BT.601
 * 8 - Linear
 * 13 - IEC 61966-2-1
 * 16 - SMPTE ST 2084 (PQ)
 * 18 - ITU-R BT.2100-2 (HLG)
 */
uint32_t turbores_frame_color_transfer(TurboresFrame *frame);

/*
 * The matrix coefficients of the decoded frame's color space, as defined by ISO/IEC 23091-2. Common values are:
 *
 * 0 - Unknown/unspecified
 * 1 - ITU-R BT.709
 * 2 - Unknown/unspecified
 * 5 - ITU-R BT.601 625
 * 6 - ITU-R BT.601 525
 * 9 - ITU-R BT.2020
 */
uint32_t turbores_frame_color_matrix(TurboresFrame *frame);

/* The frame's scan type as a `TurboresScanType` value */
uint32_t turbores_frame_scan_type(TurboresFrame *frame);

#ifdef __cplusplus
}
#endif

#endif /* TURBORES_H */

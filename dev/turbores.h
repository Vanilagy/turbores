/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/*
 * C interface for the native turbores dynamic library. These declarations mirror the `export fn` definitions in
 * src/decoder.zig and src/frame.zig. Zig's `export fn` already uses the C ABI, so `u32` maps to `uint32_t`, `usize`
 * to `size_t`, and pointers to opaque struct pointers.
 */

#ifndef TURBORES_H
#define TURBORES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handles. */
typedef struct Decoder Decoder;
typedef struct Frame Frame;

/* --- Decoder lifecycle --- */

/*
 * Creates a decoder. `concurrency` is the number of worker threads to decode with (0 = decode synchronously on the
 * calling thread). `bit_depth` is 10 or 12. `allowed_output_formats` is a bitfield of permitted pixel formats
 * (0xffffffff = all). Returns NULL on allocation failure.
 */
Decoder *createDecoder(uint32_t concurrency, uint32_t bit_depth, uint32_t allowed_output_formats);
void closeDecoder(Decoder *decoder);

uint32_t getOriginalPixelFormat(Decoder *decoder);
const uint8_t *getErrorMessagePtr(Decoder *decoder);
size_t getErrorMessageSize(Decoder *decoder);

/* --- Decoding --- */

/* Allocates (or reallocates) the decoder's packet buffer; copy the packet bytes into the returned pointer. */
uint8_t *allocatePacket(Decoder *decoder, size_t size);

/* Address of the decoder's task-state word; used by the WASM host to wait asynchronously. Native callers use
 * waitForCompletion() instead. */
uint32_t *getTaskStateAddress(Decoder *decoder);

/* Dispatches decoding of the packet currently in the decoder's buffer into `frame`. Returns 0 on success or a
 * negative error code. When concurrency > 0, this only kicks off the work; call waitForCompletion() and then
 * finalizePacketDecoding() afterwards. */
int32_t decodePacket(Decoder *decoder, Frame *frame);

/* Blocks until all dispatched worker tasks have finished. Only needed when concurrency > 0. */
void waitForCompletion(Decoder *decoder);

/* Returns 0 on success or a negative error code reported by a worker. Only needed when concurrency > 0. */
int32_t finalizePacketDecoding(Decoder *decoder);

/* --- Frames --- */

Frame *createFrame(void);
void closeFrame(Frame *frame);

uint32_t getVisibleWidth(Frame *frame);
uint32_t getVisibleHeight(Frame *frame);
uint32_t getCodedWidth(Frame *frame);
uint32_t getCodedHeight(Frame *frame);
uint8_t *getFrameDataPtr(Frame *frame);
size_t getFrameDataSize(Frame *frame);
uint32_t getFramePixelFormat(Frame *frame);
uint32_t getColorPrimaries(Frame *frame);
uint32_t getColorTransfer(Frame *frame);
uint32_t getColorMatrix(Frame *frame);
uint32_t getScanType(Frame *frame);

#ifdef __cplusplus
}
#endif

#endif /* TURBORES_H */

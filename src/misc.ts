/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

export function assert(condition: unknown): asserts condition {
    if (!condition) {
        throw new Error('Assertion failed.');
    }
}

// This thing is much faster than TextDecoder
// https://gist.github.com/pascaldekloe/62546103a1576803dade9269ccf76330
export const decodeUtf8 = (bytes: Uint8Array) => {
    let i = 0, s = '';

    while (i < bytes.length) {
        let c = bytes[i++]!;
        if (c > 127) {
            if (c > 191 && c < 224) {
                if (i >= bytes.length) {
                    throw new Error('UTF-8 decode: incomplete 2-byte sequence');
                }
                c = (c & 31) << 6 | bytes[i++]! & 63;
            } else if (c > 223 && c < 240) {
                if (i + 1 >= bytes.length) {
                    throw new Error('UTF-8 decode: incomplete 3-byte sequence');
                }
                c = (c & 15) << 12 | (bytes[i++]! & 63) << 6 | bytes[i++]! & 63;
            } else if (c > 239 && c < 248) {
                if (i + 2 >= bytes.length) {
                    throw new Error('UTF-8 decode: incomplete 4-byte sequence');
                }
                c = (c & 7) << 18 | (bytes[i++]! & 63) << 12 | (bytes[i++]! & 63) << 6 | bytes[i++]! & 63;
            } else {
                throw new Error('UTF-8 decode: unknown multibyte start 0x' + c.toString(16) + ' at index ' + (i - 1));
            }
        }
        if (c <= 0xffff) s += String.fromCharCode(c);
        else if (c <= 0x10ffff) {
            c -= 0x10000;
            s += String.fromCharCode(c >> 10 | 0xd800);
            s += String.fromCharCode(c & 0x3FF | 0xdc00);
        } else throw new Error('UTF-8 decode: code point 0x' + c.toString(16) + ' exceeds UTF-16 reach');
    }

    return s;
};

export class AsyncMutex {
    currentPromise = Promise.resolve();
    pending = 0;

    async acquire() {
        let resolver: () => void;
        const nextPromise = new Promise<void>((resolve) => {
            let resolved = false;

            resolver = () => {
                if (resolved) {
                    return;
                }

                resolve();
                this.pending--;
                resolved = true;
            };
        });

        const currentPromiseAlias = this.currentPromise;
        this.currentPromise = nextPromise;
        this.pending++;

        await currentPromiseAlias;

        return resolver!;
    }
}

export const canUseSharedMemory = typeof SharedArrayBuffer !== 'undefined';

export const identity = <T>(x: T) => x;

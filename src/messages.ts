/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import type { FrameContents } from './frame.js';

export enum MessageType {
    SharedMemoryInit,
    MessagePassingInit,
    CreateDecoder,
    CloseDecoder,
    Decode,
    Ready,
    InitOutOfMemoryError,
    Decoded,
    DecodeError,
}

// Message sent to the worker
export type WorkerMessage =
    | {
        type: MessageType.SharedMemoryInit;
        wasmBinary: Uint8Array<ArrayBuffer>;
        memory: WebAssembly.Memory;
        stackPointer: number;
        tlsPointer: number;
    }
    | {
        type: MessageType.MessagePassingInit;
        wasmBinary: Uint8Array<ArrayBuffer>;
    }
    | {
        type: MessageType.CreateDecoder;
        decoderId: number;
        bitDepth: number;
        allowedOutputFormats: number;
        log2Scale: number;
    }
    | {
        type: MessageType.CloseDecoder;
        decoderId: number;
    }
    | {
        type: MessageType.Decode;
        id: number;
        decoderId: number;
        packet: Uint8Array;
        frameBuffer: ArrayBuffer | null;
    };

// Message sent from the worker
export type WorkerReply =
    | {
        type: MessageType.Ready;
    }
    | {
        type: MessageType.InitOutOfMemoryError;
        message: string;
    }
    | {
        type: MessageType.Decoded;
        id: number;
        contents: FrameContents;
    }
    | {
        type: MessageType.DecodeError;
        id: number;
        code: number;
        message?: string;
    };

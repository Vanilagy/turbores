/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

// Mirrors the codes returned by misc.zig's toErrorCode.
export enum ErrorCode {
    OutOfMemory = -1,
    UnexpectedEof = -2,
    InvalidData = -3,
    NotSupported = -4,
    InvalidState = -5,
    Overflow = -6,
}

export class OutOfMemoryError extends Error {
    constructor(message = 'The decoder ran out of memory.') {
        super(message);
        this.name = 'OutOfMemoryError';
    }
}

export class UnexpectedEofError extends Error {
    constructor(message = 'The packet ended before the decoder expected it to.') {
        super(message);
        this.name = 'UnexpectedEofError';
    }
}

export class InvalidDataError extends Error {
    constructor(message = 'The packet contains invalid data.') {
        super(message);
        this.name = 'InvalidDataError';
    }
}

export class NotSupportedError extends Error {
    constructor(message = 'The packet uses a feature that is not supported.') {
        super(message);
        this.name = 'NotSupportedError';
    }
}

export class InvalidStateError extends Error {
    constructor(message = 'The decoder is in an invalid state.') {
        super(message);
        this.name = 'InvalidStateError';
    }
}

export class DecoderClosedError extends Error {
    constructor(message = 'The decoder has been closed.') {
        super(message);
        this.name = 'DecoderClosedError';
    }
}

export const createErrorFromCodeAndMessage = (code: number, message?: string) => {
    switch (code) {
        case ErrorCode.OutOfMemory: return new OutOfMemoryError(message);
        case ErrorCode.UnexpectedEof: return new UnexpectedEofError(message);
        case ErrorCode.InvalidData: return new InvalidDataError(message);
        case ErrorCode.NotSupported: return new NotSupportedError(message);
        case ErrorCode.InvalidState: return new InvalidStateError(message);
        // Overflow is just another flavor of invalid data
        case ErrorCode.Overflow: return new InvalidDataError(message ?? 'Unexpected integer overflow.');
        default: throw new Error(`Unhandled error code: ${code}`);
    }
};

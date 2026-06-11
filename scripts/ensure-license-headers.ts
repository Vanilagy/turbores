import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const LICENSE_HEADER = `/*!
 * Copyright (c) 2026-present, Vanilagy and contributors
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */`;

const ZIG_LICENSE_HEADER = `// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.`;

const missingFiles: string[] = [];

const checkFile = (filePath: string) => {
    const content = fs.readFileSync(filePath, 'utf8');
    const header = filePath.endsWith('.zig') ? ZIG_LICENSE_HEADER : LICENSE_HEADER;
    if (!content.startsWith(header)) {
        missingFiles.push(filePath);
    }
};

const checkDirectory = (dirPath: string) => {
    const entries = fs.readdirSync(dirPath, { withFileTypes: true });

    for (const entry of entries) {
        const fullPath = path.join(dirPath, entry.name);
        if (entry.isDirectory()) {
            checkDirectory(fullPath);
        } else if (entry.name.endsWith('.ts') || entry.name.endsWith('.zig')) {
            checkFile(fullPath);
        }
    }
};

checkDirectory(path.join(__dirname, '..', 'src'));

if (missingFiles.length > 0) {
    console.error('Files missing license header:');
    missingFiles.forEach(file => console.error(`  ${file}`));
    process.exit(1);
}

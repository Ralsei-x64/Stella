// SPDX-License-Identifier: MIT
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const [referencePath, mesaPath, outputPath] = process.argv.slice(2);
if (!outputPath) throw Error('Usage: node prepare.mjs MACLAUNCHER_SOURCE MESA_SOURCE NEW_BUILD_DIRECTORY');
const reference = fs.realpathSync(referencePath);
const mesa = fs.realpathSync(mesaPath);
const output = path.resolve(outputPath);
const git = (cwd, ...args) => execFileSync('git', ['-C', cwd, ...args], {encoding: 'utf8'}).trim();
const recipe = '01afe442d9186433a7a60d0527ad0ae8209f58eb';
const revision = '4f071f891d63396c799b267172c19ba6b0301682';
for (const [dir, pin] of [[reference, recipe], [mesa, revision]]) {
    if (git(dir, 'rev-parse', 'HEAD') !== pin || git(dir, 'status', '--porcelain', '--untracked-files=no')) {
        throw Error('Expected a clean pinned checkout at ' + dir);
    }
}
if (fs.existsSync(output)) throw Error('Choose a new directory for the adapted source');
execFileSync('git', ['clone', '--quiet', '--no-checkout', '--local', mesa, output]);
git(output, 'checkout', '--quiet', '--detach', revision);
const {adaptedKosmicSources} = await import(pathToFileURL(path.join(reference, 'kosmickrisp-source.mjs')));
for (const [name, content] of Object.entries(adaptedKosmicSources(mesa))) {
    const target = path.resolve(output, name);
    if (!target.startsWith(output + path.sep)) throw Error('Unexpected adaptation path ' + name);
    if (content === null) fs.rmSync(target, {force: true});
    else {
        fs.mkdirSync(path.dirname(target), {recursive: true});
        fs.writeFileSync(target, content);
    }
}
for (const patch of ['0001-stella-venus-memory.patch', '0002-depth-bounded-wide-lines.patch']) {
    git(output, 'apply', path.join(import.meta.dirname, patch));
}
console.log('Prepared renderer source in ' + output);

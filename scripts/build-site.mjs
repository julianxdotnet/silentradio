import { copyFile, lstat, mkdir, readdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

// Explicit allowlist: CSS, JavaScript and icons are embedded in index.html.
// Fonts and application data are fetched from external services at runtime.
const root = fileURLToPath(new URL('../', import.meta.url));
const output = join(root, 'dist');
const assets = ['index.html'];

for (const asset of assets) {
  const info = await lstat(join(root, asset));
  if (!info.isFile() || info.isSymbolicLink()) {
    throw new Error(`Expected a regular website asset: ${asset}`);
  }
}

// Never follow an output-directory symlink or remove anything outside dist.
const existing = await lstat(output).catch(error => {
  if (error.code === 'ENOENT') return null;
  throw error;
});
if (existing && (!existing.isDirectory() || existing.isSymbolicLink())) {
  throw new Error('Refusing to replace a non-directory or symlink at dist');
}
await mkdir(output, { recursive: true });
for (const entry of await readdir(output)) {
  await rm(join(output, entry), { recursive: true, force: true });
}
for (const asset of assets) {
  await copyFile(join(root, asset), join(output, asset));
}
console.log(`Staged ${assets.length} website asset in dist: ${assets.join(', ')}`);

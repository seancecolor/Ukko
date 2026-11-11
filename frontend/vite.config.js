import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const staticOutDir = path.resolve(__dirname, '../priv/static');
const COMPRESSIBLE_EXTS = new Set(['.js', '.css', '.html', '.svg', '.json', '.txt', '.xml']);

function precompressStaticPlugin() {
  return {
    name: 'ukko-precompress-static',
    apply: 'build',
    buildStart() {
      const assetsDir = path.join(staticOutDir, 'assets');
      if (fs.existsSync(assetsDir)) {
        for (const entry of fs.readdirSync(assetsDir)) {
          fs.rmSync(path.join(assetsDir, entry), { recursive: true, force: true });
        }
      }
    },
    closeBundle() {
      const compressDir = (dir) => {
        if (!fs.existsSync(dir)) return;
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
          const fullPath = path.join(dir, entry.name);
          if (entry.isDirectory()) {
            compressDir(fullPath);
            continue;
          }
          const ext = path.extname(entry.name).toLowerCase();
          if (!COMPRESSIBLE_EXTS.has(ext)) continue;
          const raw = fs.readFileSync(fullPath);
          if (raw.byteLength < 256) continue;
          const gz = gzipSync(raw, { level: 9 });
          fs.writeFileSync(`${fullPath}.gz`, gz);
        }
      };

      compressDir(staticOutDir);
    }
  };
}

export default defineConfig({
  plugins: [svelte(), precompressStaticPlugin()],
  build: {
    outDir: '../priv/static',
    emptyOutDir: false
  },
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://localhost:4000',
        changeOrigin: true
      }
    }
  }
});


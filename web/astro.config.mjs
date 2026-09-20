// @ts-check
import { defineConfig } from 'astro/config';

// https://astro.build/config
export default defineConfig({
  site: 'https://neural-sheet.quassum.com',
  output: 'static',
  trailingSlash: 'never',
  build: { format: 'file' },
});

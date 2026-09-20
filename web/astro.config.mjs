// @ts-check
import sitemap from '@astrojs/sitemap';
import { defineConfig } from 'astro/config';

// https://astro.build/config
export default defineConfig({
  site: 'https://neural-sheet.quassum.com',
  integrations: [sitemap()],
  output: 'static',
  trailingSlash: 'never',
  compressHTML: false,
});

# Website Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A one-page static Astro site in `web/`, deployed by Cloudflare Workers Builds to `https://neural-sheet.quassum.com`, that mirrors the README, offers the latest release for download, redirects `/appcast.xml` to the GitHub feed, and is rebuilt after every app release.

**Architecture:** `web/` is a self-contained Astro 7 project (`output: 'static'`, no framework islands, one global stylesheet, self-hosted Inter/JetBrains Mono from the app's own font files). `src/lib/release.ts` fetches the latest GitHub release at build time and returns a typed value or `null`; `src/pages/index.astro` renders the page from it with a safe fallback. `public/_redirects` and `wrangler.jsonc` make Workers static assets serve it. The repo's CI gets a `web` job, the release workflow POSTs a deploy hook, and `release-changes.sh` ignores `web/` so site changes never cut an app release.

**Tech Stack:** Astro 7.3, TypeScript (`astro/tsconfigs/strict`), `@astrojs/check`, Vitest 5 (through `astro/config`'s `getViteConfig`), wrangler 4, Node 22, npm; `sips` for icon sizes; Cloudflare Workers static assets + Workers Builds + Deploy Hooks.

**Spec:** `docs/design/2026-09-20-website-design.md`

## Global Constraints

- Site URL `https://neural-sheet.quassum.com`; repository `https://github.com/bring-shrubbery/neural-sheet`; Worker name `neural-sheet-web`.
- One page, one column, max width 680 px, 16 px side gutters, no horizontal scroll at 375 px width.
- Colours are custom properties on `:root`: dark default `#131417` bg / `#E7E9EC` text / `#6E9BFF` accent; light theme under `@media (prefers-color-scheme: light)`. Body has an explicit background.
- Fonts: Inter Regular/Medium/SemiBold/Bold and JetBrains Mono NL Regular, copied from `app/NeuralSheet/Resources/Fonts` with their licence files, `font-display: swap`. No external stylesheet or script.
- Download control: build-time fetch of `https://api.github.com/repos/bring-shrubbery/neural-sheet/releases/latest`; asset whose name ends in `-macos-arm64.dmg`; on any failure the button links to `https://github.com/bring-shrubbery/neural-sheet/releases/latest` and the build still succeeds.
- `_redirects`: `/appcast.xml` → `https://github.com/bring-shrubbery/neural-sheet/releases/latest/download/appcast.xml` 302; `/download` → `https://github.com/bring-shrubbery/neural-sheet/releases/latest` 302.
- Release workflow: after publishing, `POST` `$CF_DEPLOY_HOOK_URL`; empty secret → `::warning::` and success; failed request → step fails.
- `release-changes.sh` treats `web/` like `docs/` (no app release).
- Commit messages: lowercase `area: what`; use `web:` for the site, `chore:` for CI/scripts, `docs:` for docs. Every commit body ends with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Never commit `web/node_modules`, `web/dist`, `web/.astro`, `web/.wrangler`.
- The spec says "Astro 5"; the current release is 7.3 and is what is used. Task 4 corrects the spec sentence.

---

### Task 1: Scaffold `web/` — project, config, static assets, redirects

**Files:**
- Create: `web/package.json`, `web/astro.config.mjs`, `web/tsconfig.json`, `web/vitest.config.ts`, `web/wrangler.jsonc`, `web/.nvmrc`, `web/.gitignore`, `web/public/_redirects`, `web/public/icon.png`, `web/public/favicon.png`, `web/public/apple-touch-icon.png`, `web/public/og.png`, `web/public/screenshot.png`, `web/public/fonts/*`, `web/src/pages/index.astro` (placeholder, replaced in Task 3)
- Modify: `.gitignore` (root)

**Interfaces:**
- Produces: an `npm run build` that succeeds and writes `web/dist/`; `npm run check`; `npm run test` (Vitest, no tests yet); `npx wrangler deploy --dry-run` that reads `dist/`. Public asset paths used by Task 3: `/icon.png`, `/favicon.png`, `/apple-touch-icon.png`, `/og.png`, `/screenshot.png`, `/fonts/Inter-Regular.ttf`, `/fonts/Inter-Medium.ttf`, `/fonts/Inter-SemiBold.ttf`, `/fonts/Inter-Bold.ttf`, `/fonts/JetBrainsMonoNL-Regular.ttf`.

- [ ] **Step 1: Create the project files**

Work from the repository root.

```bash
mkdir -p web/public/fonts web/src/pages web/src/lib web/src/layouts web/src/styles

cat > web/package.json <<'EOF'
{
  "name": "neural-sheet-web",
  "private": true,
  "type": "module",
  "version": "0.0.0",
  "engines": {
    "node": ">=22.12.0"
  },
  "scripts": {
    "dev": "astro dev",
    "build": "astro build",
    "preview": "astro preview",
    "check": "astro check",
    "test": "vitest run",
    "astro": "astro"
  },
  "dependencies": {
    "astro": "^7.3.3"
  },
  "devDependencies": {
    "@astrojs/check": "^0.9.10",
    "typescript": "^6.0.3",
    "vitest": "^5.0.1",
    "wrangler": "^4.135.0"
  },
  "allowScripts": {
    "esbuild": true,
    "workerd": true
  }
}
EOF

cat > web/astro.config.mjs <<'EOF'
// @ts-check
import { defineConfig } from 'astro/config';

// https://astro.build/config
export default defineConfig({
  site: 'https://neural-sheet.quassum.com',
  output: 'static',
  trailingSlash: 'never',
  build: { format: 'file' },
});
EOF

cat > web/tsconfig.json <<'EOF'
{
  "extends": "astro/tsconfigs/strict",
  "include": [".astro/types.d.ts", "**/*"],
  "exclude": ["dist"]
}
EOF

cat > web/vitest.config.ts <<'EOF'
/// <reference types="vitest/config" />
import { getViteConfig } from 'astro/config';

export default getViteConfig({
  test: {
    include: ['src/**/*.test.ts'],
  },
});
EOF

cat > web/wrangler.jsonc <<'EOF'
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "neural-sheet-web",
  "compatibility_date": "2026-09-20",
  "assets": { "directory": "./dist" }
}
EOF

printf '22\n' > web/.nvmrc

cat > web/.gitignore <<'EOF'
# build output
dist/
# generated types
.astro/
# dependencies
node_modules/
# wrangler
.wrangler/
# logs
npm-debug.log*
# environment
.env
.env.*
EOF

cat > web/public/_redirects <<'EOF'
/appcast.xml  https://github.com/bring-shrubbery/neural-sheet/releases/latest/download/appcast.xml  302
/download     https://github.com/bring-shrubbery/neural-sheet/releases/latest  302
EOF

cat > web/src/pages/index.astro <<'EOF'
---
// Placeholder until Task 3 renders the real page.
---
<html lang="en"><head><meta charset="utf-8" /><title>NeuralSheet</title></head><body><h1>NeuralSheet</h1></body></html>
EOF
```

- [ ] **Step 2: Copy the assets and derive the icons**

```bash
cp docs/icon.png web/public/icon.png
cp docs/screenshot.png web/public/screenshot.png
cp app/NeuralSheet/Resources/Fonts/Inter-Regular.ttf app/NeuralSheet/Resources/Fonts/Inter-Medium.ttf \
   app/NeuralSheet/Resources/Fonts/Inter-SemiBold.ttf app/NeuralSheet/Resources/Fonts/Inter-Bold.ttf \
   app/NeuralSheet/Resources/Fonts/Inter-LICENSE.txt \
   app/NeuralSheet/Resources/Fonts/JetBrainsMonoNL-Regular.ttf app/NeuralSheet/Resources/Fonts/JetBrainsMono-OFL.txt \
   web/public/fonts/
sips -Z 32  docs/icon.png --out web/public/favicon.png >/dev/null
sips -Z 180 docs/icon.png --out web/public/apple-touch-icon.png >/dev/null
sips -Z 1024 docs/icon.png --out web/public/og.png >/dev/null
ls -l web/public web/public/fonts
```

Expected: `favicon.png` (32×32), `apple-touch-icon.png` (180×180), `og.png` (1024×1024), the two PNGs and seven font/licence files present.

- [ ] **Step 3: Root .gitignore**

Append to the root `.gitignore`, under a new `# Website` heading:

```
# Website
web/node_modules/
web/dist/
web/.astro/
web/.wrangler/
```

- [ ] **Step 4: Install, build, check, dry-run**

```bash
cd web && npm install --no-audit --no-fund && npm run check && npm run build && npx wrangler deploy --dry-run && cd ..
git status --short | grep -v '^?? web/' ; git status --short | grep 'web/' | grep -c 'node_modules\|dist/' || echo "ignored dirs are not listed: good"
```

Expected: `npm install` writes `web/package-lock.json`; `astro check` → 0 errors; `astro build` → `1 page(s) built`; the dry-run prints `Read N files from the assets directory …/web/dist` then `--dry-run: exiting now.`; the last command prints `0` then `ignored dirs are not listed: good` (nothing under `node_modules` or `dist` is untracked-visible).

- [ ] **Step 5: Commit**

```bash
git add .gitignore web
git commit -m "web: scaffold the astro site with the app's fonts, icons and the appcast redirect"
```

---

### Task 2: `src/lib/release.ts` — the latest release, typed, with tests

**Files:**
- Create: `web/src/lib/release.ts`
- Test: `web/src/lib/release.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export interface Release { version: string; notesURL: string; dmgURL: string; dmgBytes: number }
  export const latestReleaseAPI: string   // the API URL
  export const releasesPage: string       // https://github.com/bring-shrubbery/neural-sheet/releases/latest
  export function releaseFrom(json: unknown): Release | null
  export async function fetchLatestRelease(fetchImpl?: typeof fetch, token?: string): Promise<Release | null>
  export function formatMegabytes(bytes: number): string   // 4326140 → "4.3 MB"
  ```

- [ ] **Step 1: Write the failing tests**

```bash
cat > web/src/lib/release.test.ts <<'EOF'
import { describe, expect, it } from 'vitest';
import { fetchLatestRelease, formatMegabytes, releaseFrom, latestReleaseAPI } from './release';

const v100 = {
  tag_name: 'v1.0.0',
  html_url: 'https://github.com/bring-shrubbery/neural-sheet/releases/tag/v1.0.0',
  assets: [
    { name: 'NeuralSheet-v1.0.0-macos-arm64.zip', browser_download_url: 'https://example.invalid/zip', size: 4271794 },
    { name: 'NeuralSheet-v1.0.0-macos-arm64.dmg', browser_download_url: 'https://example.invalid/dmg', size: 4326140 },
    { name: 'appcast.xml', browser_download_url: 'https://example.invalid/appcast', size: 900 },
  ],
};

function respond(status: number, body: unknown): typeof fetch {
  return async () => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

describe('releaseFrom', () => {
  it('picks the dmg asset', () => {
    expect(releaseFrom(v100)).toEqual({
      version: 'v1.0.0',
      notesURL: 'https://github.com/bring-shrubbery/neural-sheet/releases/tag/v1.0.0',
      dmgURL: 'https://example.invalid/dmg',
      dmgBytes: 4326140,
    });
  });

  it('is null without a dmg asset', () => {
    expect(releaseFrom({ ...v100, assets: v100.assets.filter((a) => !a.name.endsWith('.dmg')) })).toBeNull();
  });

  it('is null for a body that is not a release', () => {
    expect(releaseFrom(null)).toBeNull();
    expect(releaseFrom('nope')).toBeNull();
    expect(releaseFrom({ tag_name: 'v1', assets: 'not-an-array' })).toBeNull();
    expect(releaseFrom({ tag_name: '', html_url: 'x', assets: v100.assets })).toBeNull();
  });
});

describe('fetchLatestRelease', () => {
  it('returns the release on 200', async () => {
    expect(await fetchLatestRelease(respond(200, v100))).toMatchObject({ version: 'v1.0.0' });
  });

  it('asks the API with the github accept header and a user agent, and a bearer token when given', async () => {
    let seen: { url: string; headers: Headers } | undefined;
    const spy: typeof fetch = async (input, init) => {
      seen = { url: String(input), headers: new Headers(init?.headers) };
      return new Response(JSON.stringify(v100), { status: 200 });
    };
    await fetchLatestRelease(spy, 'tok');
    expect(seen?.url).toBe(latestReleaseAPI);
    expect(seen?.headers.get('accept')).toBe('application/vnd.github+json');
    expect(seen?.headers.get('user-agent')).toBe('neural-sheet-web');
    expect(seen?.headers.get('authorization')).toBe('Bearer tok');
  });

  it('sends no authorization header without a token', async () => {
    let auth: string | null = 'unset';
    const spy: typeof fetch = async (_input, init) => {
      auth = new Headers(init?.headers).get('authorization');
      return new Response(JSON.stringify(v100), { status: 200 });
    };
    await fetchLatestRelease(spy);
    expect(auth).toBeNull();
  });

  it('is null on a non-2xx status', async () => {
    expect(await fetchLatestRelease(respond(403, { message: 'rate limited' }))).toBeNull();
    expect(await fetchLatestRelease(respond(404, { message: 'Not Found' }))).toBeNull();
  });

  it('is null when the request throws', async () => {
    const failing: typeof fetch = async () => { throw new Error('offline'); };
    expect(await fetchLatestRelease(failing)).toBeNull();
  });

  it('is null when the body is not json', async () => {
    const html: typeof fetch = async () => new Response('<html>', { status: 200 });
    expect(await fetchLatestRelease(html)).toBeNull();
  });
});

describe('formatMegabytes', () => {
  it('rounds to one decimal in decimal megabytes', () => {
    expect(formatMegabytes(4326140)).toBe('4.3 MB');
    expect(formatMegabytes(950000)).toBe('1.0 MB');
    expect(formatMegabytes(12345678)).toBe('12.3 MB');
  });
});
EOF
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web && npm test; cd ..`
Expected: FAIL — `Failed to resolve import "./release"`.

- [ ] **Step 3: Write the module**

```bash
cat > web/src/lib/release.ts <<'EOF'
/**
 * The latest GitHub release, read once at build time for the download control.
 * Every failure is `null`: the page then links to the Releases page, and the
 * build never depends on the API being up or unthrottled.
 */

export interface Release {
  /** The tag, e.g. `v1.0.0`. */
  version: string;
  /** The release page, for "Release notes". */
  notesURL: string;
  /** The `-macos-arm64.dmg` asset. */
  dmgURL: string;
  dmgBytes: number;
}

export const repository = 'bring-shrubbery/neural-sheet';
export const latestReleaseAPI = `https://api.github.com/repos/${repository}/releases/latest`;
export const releasesPage = `https://github.com/${repository}/releases/latest`;

const dmgSuffix = '-macos-arm64.dmg';

interface Asset { name: string; browser_download_url: string; size: number }

function isAsset(value: unknown): value is Asset {
  if (typeof value !== 'object' || value === null) return false;
  const a = value as Record<string, unknown>;
  return typeof a.name === 'string' && typeof a.browser_download_url === 'string' && typeof a.size === 'number';
}

/** The release described by an API response body, or null when it is not one we can use. */
export function releaseFrom(json: unknown): Release | null {
  if (typeof json !== 'object' || json === null) return null;
  const r = json as Record<string, unknown>;
  if (typeof r.tag_name !== 'string' || r.tag_name === '') return null;
  if (typeof r.html_url !== 'string' || !Array.isArray(r.assets)) return null;
  const dmg = r.assets.find((a) => isAsset(a) && a.name.endsWith(dmgSuffix));
  if (!isAsset(dmg)) return null;
  return { version: r.tag_name, notesURL: r.html_url, dmgURL: dmg.browser_download_url, dmgBytes: dmg.size };
}

/**
 * Fetches the latest release. `token`, when given, authenticates the request:
 * Workers Builds share egress addresses, and the unauthenticated limit is per address.
 */
export async function fetchLatestRelease(fetchImpl: typeof fetch = fetch, token?: string): Promise<Release | null> {
  const headers: Record<string, string> = {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'neural-sheet-web',
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  try {
    const response = await fetchImpl(latestReleaseAPI, { headers });
    if (!response.ok) return null;
    return releaseFrom(await response.json());
  } catch {
    return null;
  }
}

/** `4326140` → `4.3 MB` (decimal megabytes, one decimal, as Finder shows). */
export function formatMegabytes(bytes: number): string {
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}
EOF
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web && npm test && npm run check; cd ..`
Expected: `Tests  11 passed (11)`; `astro check` 0 errors, 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add web/src/lib/release.ts web/src/lib/release.test.ts
git commit -m "web: read the latest release at build time, with a null on every failure"
```

---

### Task 3: The page — layout, stylesheet, content, download control

**Files:**
- Create: `web/src/layouts/Base.astro`, `web/src/styles/global.css`, `web/src/components/Download.astro` (no `env.d.ts`: Astro's `ImportMetaEnv` already types `import.meta.env.GITHUB_TOKEN` as a string, verified with `astro check`)
- Modify: `web/src/pages/index.astro` (replace the placeholder)

**Interfaces:**
- Consumes: `fetchLatestRelease`, `formatMegabytes`, `releasesPage`, `Release` from `../lib/release`; the public asset paths from Task 1.
- Produces: `dist/index.html` containing the eight sections in order with ids `what`, `why`, `usage`, `models`, `build`, `contributing`, `credits`, `license`.

- [ ] **Step 1: The stylesheet**

```bash
cat > web/src/styles/global.css <<'EOF'
/* NeuralSheet website: one column, the app's graphite palette and typefaces. */

@font-face { font-family: 'Inter'; font-weight: 400; font-style: normal; font-display: swap; src: url('/fonts/Inter-Regular.ttf') format('truetype'); }
@font-face { font-family: 'Inter'; font-weight: 500; font-style: normal; font-display: swap; src: url('/fonts/Inter-Medium.ttf') format('truetype'); }
@font-face { font-family: 'Inter'; font-weight: 600; font-style: normal; font-display: swap; src: url('/fonts/Inter-SemiBold.ttf') format('truetype'); }
@font-face { font-family: 'Inter'; font-weight: 700; font-style: normal; font-display: swap; src: url('/fonts/Inter-Bold.ttf') format('truetype'); }
@font-face { font-family: 'JetBrains Mono NL'; font-weight: 400; font-style: normal; font-display: swap; src: url('/fonts/JetBrainsMonoNL-Regular.ttf') format('truetype'); }

:root {
  color-scheme: dark light;
  --bg: #131417;
  --bg-panel: #17181c;
  --bg-control: #1c1e23;
  --line: #24262c;
  --line-soft: #202227;
  --text-strong: #f2f4f7;
  --text: #e7e9ec;
  --text-muted: #9ba1ab;
  --text-dim: #6b7078;
  --accent: #6e9bff;
  --accent-text: #a8c2ff;
  --accent-fill: rgba(110, 155, 255, 0.12);
  --accent-fill-hover: rgba(110, 155, 255, 0.2);
  --warn-fill: rgba(255, 184, 92, 0.1);
  --warn-line: rgba(255, 184, 92, 0.35);
  --font-sans: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  --font-mono: 'JetBrains Mono NL', ui-monospace, SFMono-Regular, Menlo, monospace;
  --measure: 680px;
  --gutter: 16px;
  --radius: 10px;
}

@media (prefers-color-scheme: light) {
  :root {
    --bg: #f7f8fa;
    --bg-panel: #ffffff;
    --bg-control: #eef0f3;
    --line: #dee1e6;
    --line-soft: #e7e9ed;
    --text-strong: #0f1114;
    --text: #1b1d21;
    --text-muted: #5d626b;
    --text-dim: #7a808a;
    --accent: #2f66e8;
    --accent-text: #2557cc;
    --accent-fill: rgba(47, 102, 232, 0.08);
    --accent-fill-hover: rgba(47, 102, 232, 0.14);
    --warn-fill: rgba(201, 120, 0, 0.08);
    --warn-line: rgba(201, 120, 0, 0.35);
  }
}

*, *::before, *::after { box-sizing: border-box; }

html { -webkit-text-size-adjust: 100%; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: var(--font-sans);
  font-size: 16px;
  line-height: 1.6;
  font-feature-settings: 'cv11', 'ss01';
  overflow-x: hidden;
}

main {
  max-width: calc(var(--measure) + 2 * var(--gutter));
  margin: 0 auto;
  padding: 56px var(--gutter) 64px;
}

h1, h2, h3 { color: var(--text-strong); font-weight: 600; letter-spacing: -0.01em; margin: 0; }
h1 { font-size: 40px; line-height: 1.1; letter-spacing: -0.02em; }
h2 { font-size: 22px; line-height: 1.3; margin-bottom: 12px; }
p { margin: 0 0 14px; }
ul, ol { margin: 0 0 14px; padding-left: 22px; }
li { margin-bottom: 8px; }
li::marker { color: var(--text-dim); }
strong { color: var(--text-strong); font-weight: 600; }
a { color: var(--accent-text); text-decoration: none; }
a:hover { text-decoration: underline; text-underline-offset: 3px; }
hr { border: 0; border-top: 1px solid var(--line); margin: 0; }

section { padding: 44px 0 30px; border-top: 1px solid var(--line); }
section:first-of-type { border-top: 0; padding-top: 0; }

code, kbd, pre {
  font-family: var(--font-mono);
  font-size: 0.875em;
}
code, kbd {
  background: var(--bg-control);
  border: 1px solid var(--line-soft);
  border-radius: 5px;
  padding: 1px 5px;
  color: var(--text);
}
kbd { color: var(--text-strong); }
pre {
  background: var(--bg-panel);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 14px 16px;
  overflow-x: auto;
  line-height: 1.55;
  margin: 0 0 14px;
}
pre code { background: none; border: 0; padding: 0; font-size: inherit; }

table { width: 100%; border-collapse: collapse; margin: 0 0 14px; font-size: 15px; }
th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { color: var(--text-muted); font-weight: 500; font-size: 13px; letter-spacing: 0.02em; }
td.num { font-family: var(--font-mono); font-size: 14px; white-space: nowrap; }

.callout {
  border: 1px solid var(--warn-line);
  background: var(--warn-fill);
  border-radius: var(--radius);
  padding: 12px 16px;
  margin: 0 0 14px;
}
.callout p:last-child { margin-bottom: 0; }

.muted { color: var(--text-muted); }
.dim { color: var(--text-dim); font-size: 14px; }

/* Hero */
.hero { padding-top: 0; }
.hero .icon { width: 96px; height: 96px; display: block; margin-bottom: 20px; }
.hero .lead { font-size: 19px; line-height: 1.5; color: var(--text-muted); margin: 14px 0 24px; max-width: 34em; }
.hero .lead strong { color: var(--text); }
.hero .screenshot {
  display: block; width: 100%; height: auto;
  border: 1px solid var(--line); border-radius: var(--radius);
  margin-top: 32px;
}

/* Download control */
.download { margin: 0 0 6px; }
.download .button {
  display: inline-flex; align-items: center; gap: 10px;
  padding: 11px 18px;
  border: 1px solid var(--accent);
  background: var(--accent-fill);
  color: var(--accent-text);
  border-radius: var(--radius);
  font-weight: 600; font-size: 16px;
  text-decoration: none;
  transition: background-color 120ms ease;
}
.download .button:hover { background: var(--accent-fill-hover); text-decoration: none; }
.download .button svg { width: 18px; height: 18px; flex: none; }
.download .caption { margin: 10px 0 0; color: var(--text-dim); font-size: 14px; }
.download .caption a { color: var(--text-muted); }

/* Shortcuts line */
.shortcuts { color: var(--text-muted); font-size: 15px; line-height: 2; }
.shortcuts kbd { font-size: 13px; }

footer {
  max-width: calc(var(--measure) + 2 * var(--gutter));
  margin: 0 auto;
  padding: 0 var(--gutter) 48px;
  color: var(--text-dim);
  font-size: 14px;
  border-top: 1px solid var(--line);
}
footer .inner { padding-top: 20px; display: flex; flex-wrap: wrap; gap: 8px 20px; }
footer a { color: var(--text-muted); }

@media (max-width: 480px) {
  main { padding-top: 36px; }
  h1 { font-size: 32px; }
  h2 { font-size: 20px; }
  .hero .lead { font-size: 17px; }
  section { padding: 36px 0 24px; }
  table { font-size: 14px; }
  th, td { padding: 8px 6px; }
}
EOF
```

- [ ] **Step 2: The layout**

```bash
cat > web/src/layouts/Base.astro <<'EOF'
---
import '../styles/global.css';

interface Props {
  title: string;
  description: string;
}
const { title, description } = Astro.props;
const canonical = new URL(Astro.url.pathname, Astro.site);
const ogImage = new URL('/og.png', Astro.site);
---
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{title}</title>
    <meta name="description" content={description} />
    <link rel="canonical" href={canonical} />
    <link rel="icon" type="image/png" sizes="32x32" href="/favicon.png" />
    <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
    <meta name="theme-color" content="#131417" media="(prefers-color-scheme: dark)" />
    <meta name="theme-color" content="#f7f8fa" media="(prefers-color-scheme: light)" />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="NeuralSheet" />
    <meta property="og:title" content={title} />
    <meta property="og:description" content={description} />
    <meta property="og:url" content={canonical} />
    <meta property="og:image" content={ogImage} />
    <meta name="twitter:card" content="summary" />
    <meta name="twitter:title" content={title} />
    <meta name="twitter:description" content={description} />
    <meta name="twitter:image" content={ogImage} />
    <link rel="preload" href="/fonts/Inter-Regular.ttf" as="font" type="font/ttf" crossorigin />
    <link rel="preload" href="/fonts/Inter-SemiBold.ttf" as="font" type="font/ttf" crossorigin />
  </head>
  <body>
    <slot />
  </body>
</html>
EOF
```

- [ ] **Step 3: The download control**

```bash
cat > web/src/components/Download.astro <<'EOF'
---
import { formatMegabytes, releasesPage, type Release } from '../lib/release';

interface Props {
  release: Release | null;
}
const { release } = Astro.props;
const label = release ? `Download NeuralSheet ${release.version}` : 'Download NeuralSheet';
const href = release ? release.dmgURL : releasesPage;
---
<div class="download">
  <a class="button" href={href}>
    <svg viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
      <path d="M10 3v10m0 0 4-4m-4 4-4-4M4 16h12" />
    </svg>
    {label}
  </a>
  <p class="caption">
    macOS 26, Apple silicon
    {release && (
      <Fragment> · {formatMegabytes(release.dmgBytes)} · <a href={release.notesURL}>Release notes</a></Fragment>
    )}
  </p>
</div>
EOF
```

- [ ] **Step 4: The page**

```bash
cat > web/src/pages/index.astro <<'EOF'
---
import Base from '../layouts/Base.astro';
import Download from '../components/Download.astro';
import { fetchLatestRelease } from '../lib/release';

// Workers Builds share egress addresses; an optional token lifts the per-address limit.
// import.meta.env carries the build environment here (verified: a process env var is seen).
const release = await fetchLatestRelease(fetch, import.meta.env.GITHUB_TOKEN);
const repo = 'https://github.com/bring-shrubbery/neural-sheet';
const title = 'NeuralSheet — audio-to-MIDI transcription for macOS';
const description =
  'Record or drop a track, pick the instruments, and NeuralSheet turns it into MIDI you can play back, mix and drag into your DAW. Transcription runs entirely on your Mac.';
---
<Base title={title} description={description}>
  <main>
    <section class="hero">
      <img class="icon" src="/icon.png" width="96" height="96" alt="" />
      <h1>NeuralSheet</h1>
      <p class="lead">
        <strong>Audio-to-MIDI transcription as a native macOS app.</strong> Record or drop a track, pick the
        instruments, and NeuralSheet turns it into MIDI you can play back, mix, and drag straight into your
        DAW. Transcription runs entirely on your machine.
      </p>
      <Download release={release} />
      <img class="screenshot" src="/screenshot.png" width="2740" height="1712" alt="NeuralSheet transcribing a track: the waveform, the piano roll filling in, and the instrument mixer in the sidebar" />
    </section>

    <section id="what">
      <h2>What it does</h2>
      <ul>
        <li><strong>Record or load audio.</strong> Record from any input device, or drop a <code>.wav</code>, <code>.aiff</code>, <code>.flac</code>, <code>.mp3</code> or <code>.ogg</code> file onto the window.</li>
        <li><strong>Transcribe with MuScriptor.</strong> A 100M to 1.4B parameter transformer from Kyutai and Mirelo, running locally on the GPU through Metal. Restrict it to the instruments you know are in the mix, or let it detect them.</li>
        <li><strong>Watch the notes arrive.</strong> The piano roll fills in as each five-second chunk is decoded. You can start playing back the part that is done while the rest is still running.</li>
        <li><strong>Listen and mix.</strong> Play the transcription through the built-in synthesizer, blend it with the original audio, and set the level, mute and solo of every instrument.</li>
        <li><strong>Edit the notes.</strong> Move, resize, draw and erase notes, reassign them to other instruments, set velocities, snap and quantize to a tempo grid, with undo. Edits are saved with the session.</li>
        <li><strong>Get the MIDI out.</strong> Drag the result onto a track in your DAW, or export a multi-track <code>.mid</code> file with one track per instrument.</li>
      </ul>
    </section>

    <section id="why">
      <h2>Why a rewrite</h2>
      <p>
        NeuralSheet is a from-scratch Swift rewrite of <a href="https://github.com/DamRsn/NeuralNote">NeuralNote</a>
        by <a href="https://github.com/DamRsn">Damien Ronssin</a>, built to fix the two things that held the original
        back on the Mac: audio latency and interface smoothness. It keeps NeuralNote's design, behaviour and
        transcription engine, and replaces the cross-platform C++/JUCE application layer with SwiftUI, AppKit and
        AVAudioEngine.
      </p>
      <ul>
        <li><strong>Audio</strong> goes through one <code>AVAudioEngine</code> graph: a source node owns the clock and schedules synth notes one buffer ahead, sample-aligned with the original audio, with a 128-frame I/O buffer where the device allows it.</li>
        <li><strong>Drawing</strong> is done by AppKit views that repaint only the strip that changed. A ten-minute file scrolls at 120 Hz.</li>
        <li><strong>Everything else</strong> is SwiftUI, with the original palette, typography, metrics and interaction rules ported one for one.</li>
      </ul>
      <p class="muted">
        The transcription engine, <a href="https://github.com/DamRsn/muscriptor.cpp">muscriptor.cpp</a>, is unchanged and
        linked as a static library.
      </p>
    </section>

    <section id="usage">
      <h2>Usage</h2>
      <ol>
        <li><strong>Get some audio.</strong> Press record (or <kbd>r</kbd>) and play, or drop a file on the waveform area. Choose your input and output devices in the <strong>Audio</strong> menu.</li>
        <li><strong>Choose instruments.</strong> Use <strong>+</strong> in the sidebar to tick the instruments in the recording, or leave it on <em>Automatic</em>. Transcriptions are better when the model is told what to listen for.</li>
        <li><strong>Transcribe.</strong> The first run downloads a model. Progress shows in the status bar; you can cancel at any time.</li>
        <li><strong>Listen.</strong> Space plays and pauses. The <strong>ORIG / MIDI</strong> slider blends the source audio with the synthesized notes; each instrument has its own fader, mute and solo.</li>
        <li><strong>Edit.</strong> <kbd>⌘2</kbd> opens the Edit tab. <kbd>V</kbd> selects, <kbd>D</kbd> draws, <kbd>E</kbd> erases; drag notes, or their ends; <kbd>⌥</kbd>-drag duplicates; arrows nudge. Set the tempo and where bar 1 falls in the toolbar.</li>
        <li><strong>Export.</strong> Drag the <strong>MIDI</strong> button onto a track in your DAW, or use <strong>Export</strong> to save a <code>.mid</code> file. The export tempo sets how seconds map to beats.</li>
      </ol>
      <p class="shortcuts">
        <kbd>Space</kbd> play/pause · <kbd>⇧Space</kbd> go to start · <kbd>r</kbd> record · <kbd>m</kbd> mute ·
        <kbd>c</kbd> centre the playhead · <kbd>⇧⌫</kbd> clear · <kbd>⌘</kbd>+scroll or pinch to zoom ·
        <kbd>⌘1</kbd>/<kbd>⌘2</kbd> tabs · <kbd>⌘Z</kbd> undo · <kbd>⌘U</kbd> quantize · <kbd>⌘A</kbd> select all ·
        <kbd>⌘</kbd>-drag ignores snap
      </p>
    </section>

    <section id="models">
      <h2>Models</h2>
      <p>
        MuScriptor comes in three sizes. NeuralSheet downloads them from
        <a href="https://huggingface.co/DamRsn/muscriptor-gguf">DamRsn/muscriptor-gguf</a> on Hugging Face into
        <code>~/Library/NeuralSheet/models</code> (it also picks up models already in
        <code>~/Library/NeuralNote/models</code>). Downloads resume if interrupted and are verified by SHA-256.
      </p>
      <table>
        <thead>
          <tr><th>Size</th><th>Download</th><th>Speed on an M1 Pro</th><th>Notes</th></tr>
        </thead>
        <tbody>
          <tr><td>small</td><td class="num">209 MB</td><td class="num">~3.5× real time</td><td>Fastest</td></tr>
          <tr><td>medium</td><td class="num">618 MB</td><td class="num">~1.5× real time</td><td>Recommended</td></tr>
          <tr><td>large</td><td class="num">2.7 GB</td><td class="num">~0.5× real time</td><td>Best quality</td></tr>
        </tbody>
      </table>
      <div class="callout">
        <p>
          <strong>The model weights are not open source.</strong> Kyutai and Mirelo released them under
          <a href="https://creativecommons.org/licenses/by-nc/4.0/">CC BY-NC 4.0</a>: they may only be used
          <strong>non-commercially</strong>. NeuralSheet's own code is Apache-2.0, which does not extend to the weights.
        </p>
      </div>
      <p class="muted">
        Playback uses the General MIDI synthesizer built into macOS, so no soundfont is bundled. It sounds different from
        NeuralNote's MuseScore soundfont.
      </p>
    </section>

    <section id="build">
      <h2>Build from source</h2>
      <p>macOS 26 on Apple silicon, Xcode 27, and <a href="https://cmake.org/">CMake</a> (<code>brew install cmake</code>) for the transcription engine. The first build fetches ggml.</p>
      <pre><code>git clone --recurse-submodules https://github.com/bring-shrubbery/neural-sheet.git
cd neural-sheet/app
xcodebuild -scheme NeuralSheet -configuration Release build</code></pre>
      <p>
        Or open <code>app/NeuralSheet.xcodeproj</code> in Xcode and run the <strong>NeuralSheet</strong> scheme. The
        <a href={`${repo}#build-from-source`}>README</a> has the details, including the pure-Swift core package and its tests.
      </p>
    </section>

    <section id="contributing">
      <h2>Contributing</h2>
      <p>NeuralSheet is developed by a small team working with AI coding agents that we run and supervise ourselves. Because of that:</p>
      <ul>
        <li><strong>Feature requests, ideas and questions</strong> go to <a href={`${repo}/discussions`}>Discussions</a>. The most requested and best argued ideas are what we build next.</li>
        <li><strong>Bug reports</strong> go to <a href={`${repo}/issues`}>Issues</a>, using the template, for bugs you have reproduced yourself.</li>
        <li><strong>Pull requests are not accepted</strong> and are closed automatically.</li>
      </ul>
      <p class="muted"><a href={`${repo}/blob/main/CONTRIBUTING.md`}>CONTRIBUTING.md</a> explains the reasoning and the details.</p>
    </section>

    <section id="credits">
      <h2>Credits</h2>
      <p>
        NeuralSheet started on 2026-09-17 as a rewrite of <strong>NeuralNote v2</strong>. Everything a user sees, and the
        audio and MIDI logic underneath, follows NeuralNote's design; the Swift code was written new against a detailed
        inventory of its behaviour, and the note scheduler, resampler, waveform peaks, MIDI writer and piano-roll
        geometry are ports of the original C++.
      </p>
      <ul>
        <li><strong>NeuralNote v2</strong> was developed by <a href="https://github.com/DamRsn">Damien Ronssin</a>, with AI assistance.</li>
        <li><strong>NeuralNote v1</strong> was developed by Damien Ronssin and <a href="https://github.com/tiborvass">Tibor Vass</a>; its interface was designed by Perrine Morel.</li>
        <li><strong>muscriptor.cpp</strong>, the transcription engine, is by Damien Ronssin. <strong>MuScriptor</strong>, the model, is by Kyutai and Mirelo (<a href="https://arxiv.org/abs/2607.08168">paper</a>, <a href="https://github.com/muscriptor/muscriptor">project</a>).</li>
        <li><strong>NeuralSheet</strong> is by <a href="https://github.com/bring-shrubbery">Antoni Silvestrovic</a>, built with Claude Code.</li>
      </ul>
    </section>

    <section id="license">
      <h2>License</h2>
      <p>
        NeuralSheet's code is licensed under the <a href={`${repo}/blob/main/LICENSE`}>Apache License 2.0</a>, the same
        licence as NeuralNote. <a href={`${repo}/blob/main/NOTICE`}>NOTICE</a> records the origin of the work, and
        <a href={`${repo}/blob/main/THIRD_PARTY_NOTICES.md`}>THIRD_PARTY_NOTICES.md</a> lists every third-party
        component: muscriptor.cpp and ggml (MIT), PFFFT (BSD-style), stb_vorbis (public domain), and the Inter and
        JetBrains Mono typefaces (OFL 1.1).
      </p>
      <p class="muted">The MuScriptor model weights are <strong>CC BY-NC 4.0, non-commercial use only</strong>, and are downloaded separately at run time.</p>
    </section>
  </main>
  <footer>
    <div class="inner">
      <span>NeuralSheet</span>
      <a href={repo}>GitHub</a>
      <a href={`${repo}/releases`}>Releases</a>
      <a href={`${repo}/discussions`}>Discussions</a>
      <a href="https://quassum.com">Quassum</a>
    </div>
  </footer>
</Base>
EOF
```

- [ ] **Step 5: Build and check the output**

```bash
cd web && npm run check && npm run build && npm test && cd ..
grep -o 'Download NeuralSheet v[0-9.]*' web/dist/index.html
grep -o 'id="[a-z]*"' web/dist/index.html | tr '\n' ' '; echo
grep -c 'releases/download/v' web/dist/index.html
grep -o '<link rel="canonical" href="[^"]*"' web/dist/index.html
grep -c 'googleapis\|<script' web/dist/index.html || true
```

Expected: `astro check` 0 errors; build OK; 11 tests pass; the first grep prints `Download NeuralSheet v1.0.0` (or a newer tag — the real API is called; if it prints nothing because the API was throttled, the fallback rendered: check `grep -c 'releases/latest' web/dist/index.html` is ≥ 1 and note it in the report); the ids line lists `what why usage models build contributing credits license` in that order; `releases/download/v` count ≥ 1 when the API answered; canonical `https://neural-sheet.quassum.com/`; the last count is `0` (no external stylesheet, no script).

- [ ] **Step 6: Preview at phone width**

```bash
cd web && npx astro preview --port 4321 & sleep 3
curl -s http://localhost:4321/ | head -c 300; echo
curl -sI http://localhost:4321/screenshot.png | head -1
curl -sI http://localhost:4321/fonts/Inter-Regular.ttf | head -1
kill %1; cd ..
```

Expected: the HTML starts with `<!DOCTYPE html>`, both HEADs return `200`. (Astro's preview server does not apply `_redirects`; that is verified after deployment.) Visual review at 375 px and 1280 px is done by the maintainer or controller in a browser: sections readable, no horizontal scroll, the button and caption on one line at desktop width.

- [ ] **Step 7: Commit**

```bash
git add web/src
git commit -m "web: the landing page — hero with the live download, the readme's sections, the app's palette"
```

---

### Task 4: Repository wiring — CI, release workflow, change filter, docs

**Files:**
- Modify: `.github/workflows/ci.yml` (append a job), `.github/workflows/release.yml` (one step after "Publish the GitHub release"), `app/Scripts/release-changes.sh` (the `case`), `app/Scripts/release-changes-test.sh` (one row), `docs/release.md`, `README.md`, `CHANGELOG.md`, `docs/design/2026-09-20-website-design.md`
- Create: `web/README.md`

- [ ] **Step 1: CI job**

Append to `.github/workflows/ci.yml` under `jobs:` (same indentation as `app-build`):

```yaml
  web:
    name: Website
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: web
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version-file: web/.nvmrc
          cache: npm
          cache-dependency-path: web/package-lock.json
      - run: npm ci
      - run: npm run check
      - run: npm test
      - run: npm run build
```

- [ ] **Step 2: Release workflow deploy hook**

In `.github/workflows/release.yml`, insert between the "Publish the GitHub release" step and the "Summary" step:

```yaml
      - name: Rebuild the website
        env:
          CF_DEPLOY_HOOK_URL: ${{ secrets.CF_DEPLOY_HOOK_URL }}
        run: |
          if [ -z "$CF_DEPLOY_HOOK_URL" ]; then
            echo "::warning::CF_DEPLOY_HOOK_URL is not set; the website keeps offering the previous release until it is rebuilt (docs/release.md)"
            exit 0
          fi
          curl -fsS -X POST "$CF_DEPLOY_HOOK_URL" -o /dev/null
          echo "website rebuild requested"
```

Also add `CF_DEPLOY_HOOK_URL` to the header comment of the workflow if it lists the secrets (it points to docs/release.md; leave it if it does not list them).

- [ ] **Step 3: The change filter**

In `app/Scripts/release-changes.sh`, change the `case` line `docs/*|*.md|LICENSE|NOTICE) return 0 ;;` to `docs/*|web/*|*.md|LICENSE|NOTICE) return 0 ;;`, and in the header comment change "Documentation is docs/, any *.md, LICENSE, NOTICE and .github/ except the workflows." to "Documentation is docs/, the website under web/, any *.md, LICENSE, NOTICE and .github/ except the workflows."

In `app/Scripts/release-changes-test.sh`, add after the `check "nothing" ...` row:

```bash
check "website"          "web/src/pages/index.astro web/package.json" ""
check "website and app"  "web/src/pages/index.astro app/Scripts/build-engine.sh" "app/Scripts/build-engine.sh"
```

Run: `app/Scripts/release-changes-test.sh` → `all passed`; `actionlint .github/workflows/ci.yml .github/workflows/release.yml` → no output.

- [ ] **Step 4: `web/README.md`**

```bash
cat > web/README.md <<'EOF'
# NeuralSheet website

The one-page site at https://neural-sheet.quassum.com: an Astro static site that mirrors
the repository README, offers the latest release for download, and owns the URLs the app
depends on (`/appcast.xml` redirects to the release feed on GitHub).

## Develop

```sh
cd web
npm install
npm run dev        # http://localhost:4321
npm run check      # astro check (types)
npm test           # vitest
npm run build      # writes dist/
npm run preview    # serves dist/ (without the _redirects rules)
```

The download button is rendered at build time from the latest GitHub release. When the API is
unreachable or throttled the button links to the Releases page instead; the build never fails
because of it. Set `GITHUB_TOKEN` in the environment (any token, no scopes needed) to lift the
unauthenticated rate limit; Workers Builds share egress addresses, so set it there too.

## Deploy (Cloudflare Workers Builds)

One-time setup in the Cloudflare dashboard:

1. **Workers & Pages → Create → Import a repository** → `bring-shrubbery/neural-sheet`.
2. Build configuration: root directory `web`, build command `npm run build`, deploy command
   `npx wrangler deploy`, production branch `main`. Leave non-production branch builds off.
3. Optionally add a build environment variable `GITHUB_TOKEN` (see above).
4. **Settings → Domains & Routes → Add → Custom domain** → `neural-sheet.quassum.com`
   (the `quassum.com` zone must be on this account).
5. **Settings → Builds → Deploy Hooks → Create** for branch `main`, then in the repository:
   `gh secret set CF_DEPLOY_HOOK_URL` and paste the hook URL. The release workflow POSTs it
   after every app release so the download button shows the new version.

Every push to `main` that touches `web/` rebuilds the site. `wrangler.jsonc` is assets-only:
there is no Worker code, only `dist/` and the `_redirects` file in `public/`.

## Check a deployment

```sh
curl -I https://neural-sheet.quassum.com/appcast.xml   # 302 to the GitHub asset
curl -I https://neural-sheet.quassum.com/download      # 302 to the Releases page
```
EOF
```

- [ ] **Step 5: `docs/release.md`, README, CHANGELOG, spec**

`docs/release.md`: in "One-time setup: the secrets", after the sentence about the seven secrets, add a paragraph:

```
An eighth secret is optional: `CF_DEPLOY_HOOK_URL`, the Cloudflare Workers Builds deploy
hook for the website (see `web/README.md`). Without it the release still publishes, with a
warning, and the website keeps offering the previous version until it is rebuilt.
```

Root `README.md`:
- Replace the status note (`> [!NOTE] … **Status: v1 checkpoint (September 2026).** … build it from source. macOS 26 on Apple silicon only.`) with:
  ```
  > [!NOTE]
  > **Status: v1.0 (September 2026).** NeuralSheet has feature parity with the NeuralNote v2 standalone app. Download the latest release from [neural-sheet.quassum.com](https://neural-sheet.quassum.com) or the [Releases page](https://github.com/bring-shrubbery/neural-sheet/releases/latest); it is signed and notarized. macOS 26 on Apple silicon only.
  ```
- In "Repository layout", add a line `web/          The website (Astro), deployed to neural-sheet.quassum.com by Cloudflare Workers Builds` after the `docs/design/` line, and delete the sentence "Other folders (a website, for example) will sit beside `app/` as the project grows."
- In "Roadmap", delete the line `- Notarized releases`.

`CHANGELOG.md`, under `[Unreleased]` → `### Added`, append:
```
- A website at [neural-sheet.quassum.com](https://neural-sheet.quassum.com) (`web/`, Astro on Cloudflare) with the latest download and the `/appcast.xml` feed redirect.
```

`docs/design/2026-09-20-website-design.md`: change "`web/` is an Astro 5 project" to "`web/` is an Astro 7 project".

- [ ] **Step 6: Verify and commit**

```bash
actionlint .github/workflows/ci.yml .github/workflows/release.yml
app/Scripts/release-changes-test.sh | tail -1
app/Scripts/release-changes.sh "$(app/Scripts/release-version.sh --previous)" | grep -c '^web/' || echo "no web/ paths: good"
grep -n "Notarized releases\|Other folders" README.md || echo "README lines removed: good"
git add .github/workflows/ci.yml .github/workflows/release.yml app/Scripts/release-changes.sh app/Scripts/release-changes-test.sh docs/release.md README.md CHANGELOG.md docs/design/2026-09-20-website-design.md web/README.md
git commit -m "chore: ci builds the website; a release rebuilds it; web/ changes cut no app release"
```

Expected: actionlint silent; `all passed`; `0` / `no web/ paths: good`; `README lines removed: good`.

---

### Task 5: Verify and hand over

- [ ] **Step 1: Everything once more**

```bash
(cd web && npm ci --no-audit --no-fund && npm run check && npm test && npm run build && npx wrangler deploy --dry-run | tail -2)
app/Scripts/release-version-test.sh | tail -1; app/Scripts/release-changes-test.sh | tail -1
actionlint .github/workflows/*.yml && git status --short && echo clean
```

Expected: all green, `clean`.

- [ ] **Step 2: Report to the maintainer**

Nothing is pushed. List: the dashboard steps from `web/README.md` §Deploy (import repo with root `web`, custom domain, deploy hook → `CF_DEPLOY_HOOK_URL`); that pushing `main` triggers CI (which now builds the site) and no app release (the only `app/` change is the two scripts — note that `app/Scripts/release-changes.sh` *is* under `app/`, so this push **will** cut `v1.0.1`; say so plainly); and the two checks to run after the first deploy (`curl -I …/appcast.xml` → 302, and the Release run's "Rebuild the website" step).

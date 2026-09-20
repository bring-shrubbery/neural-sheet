# Website — design

A one-page static site for NeuralSheet at `https://neural-sheet.quassum.com`,
built with Astro in `web/` and deployed by Cloudflare Workers Builds from this
repository. It mirrors the README, offers the current release for download,
and owns the URLs the app will depend on (`/appcast.xml` for Sparkle).

## Site

- `web/` is an Astro 7 project, `output: 'static'`, TypeScript strict, npm
  with a committed lockfile, Node 22 (`.nvmrc`). No UI framework, no Tailwind:
  one global stylesheet.
- One page, one column, max width 680 px, 16 px side gutters, no horizontal
  scroll at phone width. Sections, in order, each condensed from the README:
  1. Hero: the app icon, "NeuralSheet", the one-line pitch, the download
     control (below), the screenshot.
  2. What it does (the six bullets).
  3. Why a rewrite (the paragraph and three bullets, shortened).
  4. Usage (the six steps) and the shortcut line.
  5. Models (the table) and the non-commercial notice.
  6. Build from source (requirements, the clone/build commands, a link to the
     repository for the rest).
  7. Contributing (Discussions for ideas, Issues for reproduced bugs, no
     pull requests) linking CONTRIBUTING.md.
  8. Credits and License, as in the README, with the same links.
- Identity follows the app: Inter (Regular, Medium and SemiBold, copied
  from `app/NeuralSheet/Resources/Fonts` with their licence, self-hosted with
  `font-display: swap`), JetBrains Mono NL for code, the graphite palette
  (`#131417` background, `#E7E9EC` text, `#6E9BFF` accent) as the default
  dark theme and a light theme via `prefers-color-scheme`. Colours are CSS
  custom properties on `:root`.
- `docs/icon.png` is copied to `web/public/icon.png`; favicon (32 px),
  apple-touch-icon (180 px) and an Open Graph image are derived from it at
  setup time with `sips` and committed. `<head>` carries title, description,
  canonical URL, Open Graph and Twitter card tags. `docs/screenshot.png` is
  copied to `web/public/screenshot.png`.

## The download control

- At build time `src/pages/index.astro` fetches
  `https://api.github.com/repos/bring-shrubbery/neural-sheet/releases/latest`
  (module-level `fetch`, `Accept: application/vnd.github+json`, a
  `User-Agent`). From the response it takes `tag_name`, `html_url`, and the
  asset whose name ends in `-macos-arm64.dmg` (its `browser_download_url` and
  `size`).
- Rendered as a primary button "Download NeuralSheet vX.Y.Z" linking to the
  DMG, with a caption "macOS 26, Apple silicon · N MB · Release notes" where
  "Release notes" links to `html_url`.
- If the request fails, returns a non-2xx status, or has no such asset, the
  button reads "Download NeuralSheet" and links to
  `https://github.com/bring-shrubbery/neural-sheet/releases/latest`; the
  caption is "macOS 26, Apple silicon". The build never fails because of the
  API. The fetch lives in `src/lib/release.ts` and returns a typed
  `Release | null` so it is testable and the page stays declarative.
- The site is rebuilt after every app release: the release workflow's last
  step `POST`s the Workers Builds deploy hook held in the secret
  `CF_DEPLOY_HOOK_URL`. When the secret is empty the step prints a warning
  and succeeds; a failed request fails the step (the release is already
  published by then).

## Redirects

`web/public/_redirects` (Workers static assets apply it):

```
/appcast.xml  https://github.com/bring-shrubbery/neural-sheet/releases/latest/download/appcast.xml  302
/download     https://github.com/bring-shrubbery/neural-sheet/releases/latest  302
```

`/appcast.xml` is the URL the app's Sparkle feed will use; it stays a
redirect until there is a reason to serve the feed from the site.

## Deployment

- `web/wrangler.jsonc`: `name: "neural-sheet-web"`, a compatibility date, and
  `assets: { directory: "./dist" }`; no `main`.
- Cloudflare Workers Builds, connected to this repository in the dashboard:
  root directory `web`, build command `npm run build`, deploy command
  `npx wrangler deploy`, production branch `main`, custom domain
  `neural-sheet.quassum.com`. Non-production branch builds off.
- `web/README.md` documents the dashboard setup, the deploy hook, and local
  development (`npm install`, `npm run dev`, `npm run build`, `npm run check`).

## Repository wiring

- `.github/workflows/ci.yml` gains a `web` job on `ubuntu-latest`:
  `actions/setup-node` with `.nvmrc` and npm cache, `npm ci`, `npm run check`
  (`astro check`), `npm run build`.
- `app/Scripts/release-changes.sh` ignores `web/` as it ignores `docs/`: a
  website change must not cut an app release. Its test gets a row.
- `.github/workflows/release.yml` gains the deploy-hook step after the
  release is published. `docs/release.md` lists `CF_DEPLOY_HOOK_URL` as an
  optional eighth secret.
- Root `README.md`: the status note says releases are on the Releases page
  and the website; "Notarized releases" leaves the roadmap; the layout
  section lists `web/`. `CHANGELOG.md` gets an Unreleased entry.
- `.gitignore` gains `web/node_modules/`, `web/dist/`, `web/.astro/`,
  `web/.wrangler/`.

## Testing

- `npm run check` and `npm run build` pass locally and in CI.
- `src/lib/release.ts` has a Vitest unit test with a stubbed `fetch`: the
  happy path picks the DMG asset; a 403, a network error and a release
  without a DMG asset all yield `null`.
- The built page is opened locally (`npm run preview`) at desktop and phone
  widths and checked for the sections above, the live version in the button,
  and no horizontal scroll.
- After the maintainer connects the repository: `curl -I
  https://neural-sheet.quassum.com/appcast.xml` returns 302 to the GitHub
  URL, and a release run's deploy-hook step logs a 2xx.

## Out of scope

Analytics, i18n, a blog or docs section, serving the appcast from the site.

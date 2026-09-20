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

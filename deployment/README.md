# Website security and publishing

The live website is GitHub Pages, built from `main:/docs`. HTTPS enforcement was
confirmed on October 9, 2026, both through the Pages API and the HTTP→HTTPS redirect.
Publish website changes through a pull request to `main`.
Do not deploy the repository root. Only `docs/` is public website content.

## Before publishing

```sh
cd /Users/jonathonbrown/Developer/HydroDrop
bash Scripts/website_preflight.sh
```

This checks every HTML page's policy, local links and fragments, image alt attributes,
metadata, sitemap and forbidden publish artifacts. It exercises seven negative/positive
regression cases and scans the website plus its locally available Git history using
Gitleaks with findings redacted. Install Gitleaks with `brew install gitleaks` if needed.
This guardrail must be run before publishing; it is not a configured GitHub Pages build gate.
GitHub secret scanning and push protection are already enabled on the repository.

For a preview with the prepared HTTP security headers and custom 404 behavior:

```sh
python3 Scripts/serve_website.py
```

The preview listens only on 127.0.0.1 and disables directory listing. It is not a production server.

## Enforced by the HTML once published

Every page includes an early Content Security Policy meta tag. Only local scripts,
styles and images are allowed. Inline handlers/scripts/styles, eval, connections,
frames, workers, plugin objects, base URL changes and form submissions are blocked.
Every page also uses `no-referrer`, including the bottle tag fallback, so its URL is
not sent as an outgoing referrer. There is no visitor input rendered as HTML. Duo invite fragments are validated and
rendered as text; the private suffix is never displayed or copied.

The site has no server API, login, admin routes, database, uploads, payment processing,
analytics or cookies. Theme preference is the only local storage value. Public
GitHub Pages assets returning `Access-Control-Allow-Origin: *` are not authenticated
resources and do not expose a session or private data.

## Hosting-dependent work still outstanding

`security-headers.json` specifies the response headers to apply on a header-capable
host or HTTPS reverse proxy. GitHub Pages does not consume this JSON or a `_headers`
file. Do not claim these headers are live merely because the file exists.

Required production headers:
- Content-Security-Policy (same policy as HTML, plus `frame-ancestors 'none'`)
- X-Frame-Options: DENY
- X-Content-Type-Options: nosniff
- Referrer-Policy: no-referrer
- Permissions-Policy disabling unused camera, microphone, location, payment, USB and Topics access
- Strict-Transport-Security: max-age=31536000

HSTS intentionally omits includeSubDomains and preload because other subdomains were
not audited. `frame-ancestors`, X-Frame-Options, Permissions-Policy and nosniff cannot
be implemented with HTML meta tags. This deployment does not change DNS or migrate hosting.
After choosing/configuring a host/proxy, verify all page responses, actual missing-URL
404 status, `/tap` routing and the Apple association file before changing DNS.

The app's `.well-known/apple-app-site-association` must continue to be served without
a redirect and as JSON. Preserve the bottle and Duo universal-link paths and public app-ads.txt.
Do not add rate limiting that interferes with Apple's association-file fetches.
There are no expensive website endpoints that require application rate limits or API spend caps.

## Images and content

```sh
python3 Scripts/export_website_mascots.py
python3 Scripts/optimize_website_images.py
```

The first command uses macOS SwiftUI; the second requires `cwebp` (`brew install webp`).
Native PNG source assets remain intact. The website serves lossless WebP mascot copies,
192px app icons and WebP screenshots. Review screenshots, dates and sitemap lastmod
when making content changes. Never replace actual app artwork with generated lookalikes.

## References

- https://docs.github.com/en/pages/getting-started-with-github-pages/securing-your-github-pages-site-with-https
- https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CSP
- https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/frame-ancestors
- https://developers.cloudflare.com/pages/configuration/headers/

# statusboard.am.guru

The project site lives in [`website/`](../website). It has no build step and no
dependencies — plain HTML, one stylesheet, one script.

| | |
| --- | --- |
| URL | <https://statusboard.am.guru> |
| Host | the `homeassistant` SSH host (`192.168.1.9`, Home Assistant OS) |
| Served from | `/share/statusboard` |
| Web server | Caddy, running as the Home Assistant add-on `c80c7555_caddy-2` |
| Config | `/addon_configs/c80c7555_caddy-2/Caddyfile` |
| Access log | `/share/caddy/logs/statusboard.log` |
| TLS | automatic, via the GoDaddy DNS-01 challenge in the shared `(common)` snippet |

`am.guru` has wildcard DNS, so the hostname resolved before the site existed;
only the Caddy site block was needed.

## Deploying a change

Nothing to do: push to `main`. The
[`Deploy website`](../.github/workflows/deploy-website.yml) workflow fires on
any commit that touches `website/`, on the same self-hosted runner as the app
release (`media` is on the LAN; a GitHub-hosted runner could reach neither the
runner nor `/share`). It needs no secrets — media already holds the SSH key for
the `homeassistant` alias.

The job validates, packages, publishes and then checks the live site:

1. **Validate.** Every required file is present and non-empty, there are no
   symlinks, and no page carries an inline `style="…"` attribute — see the CSP
   section below. Mismatched `?v=` asset versions across pages are a warning,
   not a failure.
2. **Package.** `COPYFILE_DISABLE=1 tar` with `.DS_Store` and `._*` excluded,
   then a SHA-256 of the archive, checked before it is sent.
3. **Publish.** The tree is extracted into `/share/.statusboard-deploy-<run>`,
   then swapped into place with `mv`. That swap is the only moment anything
   changes, so a half-copied tree is never reachable; the tree it replaced is
   kept at `/share/.statusboard-previous`, and a failed swap puts it back.
4. **Verify.** `https://statusboard.am.guru/` must come back 200 with exactly
   the `index.html` that was just shipped, retried three times.

`workflow_dispatch` re-runs it by hand — useful after restoring a backup.

To deploy without GitHub (the runner is down, or you're testing locally):

```bash
cd website && COPYFILE_DISABLE=1 tar czf - index.html privacy.html terms.html styles.css script.js favicon.svg og.png | ssh homeassistant 'tar xzf - -C /share/statusboard'
```

`COPYFILE_DISABLE=1` matters: without it macOS `tar` ships AppleDouble `._`
files alongside every real one. Note this copy is not atomic and does not
delete files removed from the repository — the workflow's swap does both.

Caddy serves files straight from disk, so a copy is live immediately — no
restart. Only edits to the **Caddyfile** need
`ha addons restart c80c7555_caddy-2`.

## The content security policy

The site block sets a strict policy — `default-src 'self'`, and notably
`style-src 'self'` with **no** `'unsafe-inline'`. That means **inline `style="…"`
attributes are blocked**, not just inline `<style>` blocks. Everything visual
has to live in `styles.css`; `.nothing`, `.requirements.spaced` and
`.legal-title` exist purely because they replaced inline styles. `img-src`
allows `data:` so the favicon and any inlined artwork keep working.

If a future change needs an inline style, add the class instead.

## The live demo

`script.js` renders a miniature working board — the clock really ticks and the
values really move. The device switcher reflows it the way the app does:
four columns on Mac and Apple TV, three on iPad, two on iPhone, one on the
watch, with detail-heavy panels always taking a full row. It mirrors
`WatchLayout` in `StatusBoardKit`, so if that reflow logic changes, this should
follow.

Reduced motion is respected: the simulated data stops, the marquee and pulse
stop, and reveal animations are skipped — but the clock keeps ticking.

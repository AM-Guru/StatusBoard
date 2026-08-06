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

```bash
cd website && COPYFILE_DISABLE=1 tar czf - index.html privacy.html terms.html styles.css script.js favicon.svg og.png | ssh homeassistant 'tar xzf - -C /share/statusboard'
```

`COPYFILE_DISABLE=1` matters: without it macOS `tar` ships AppleDouble `._`
files alongside every real one. Caddy serves files straight from disk, so a
copy is live immediately — no restart. Only edits to the **Caddyfile** need
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

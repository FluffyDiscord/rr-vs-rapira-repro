# rr-vs-rapira-repro

One identical bare Symfony 7.4 app served two ways — **RoadRunner** (nginx → FastCGI) and **Rapira**
(nginx → HTTP proxy) — to check whether a RoadRunner/Rapira latency gap seen on a real Sylius app
reproduces with no database, no Sylius, no assets. Two routes: `/` = `Response('ok')`, `/render` =
a Twig ~200-row table.

## What we found

On the bare app the gap is **not the runtime — it's the Rapira nginx proxy config.** Rapira's own
HTTP server is the fastest listener measured here. The committed `docker/nginx/rapira.conf` used a
bare `proxy_pass` with no upstream keepalive, so nginx opened one TCP connection per request and
burned **~730% CPU** (7+ cores) pushing ~14k req/s while Rapira's own workers stayed under 3 cores.

The fix — explicit `upstream { keepalive }` + `proxy_set_header Connection ""` + rr.conf-sized proxy
buffers — drops nginx to **~22% CPU** and lifts `/` from ~14k to ~20k req/s. `rapira.conf` now ships
with it.

## Numbers

Ryzen 7 9800X3D (8c/16t), `wrk -t4 -c16`, warm workers. Single-host loopback: `wrk`, nginx, and the
app share the same 16 threads, no network — not prod figures. Rps drifts a few percent run to run;
CPU (via `docker stats` per container, percent of one core) and ratios are the stable signal.

| Server     | Route     | Direct (no nginx) | via nginx (committed) | via nginx (fixed) |
|------------|-----------|------------------:|----------------------:|------------------:|
| RoadRunner | `/`       | 16.8k             | 14.0k                 | —                 |
| RoadRunner | `/render` | 8.4k              | 7.7k                  | —                 |
| Rapira     | `/`       | 58k               | 14.2k                 | **20.6k**         |
| Rapira     | `/render` | 15.6k             | 5.3k                  | ~5.1k             |

- **Rapira `/`**: the proxy was the whole gap — 58k direct, 14k committed, 20k fixed.
- **`/render`**: through nginx it is bound by the extra serialised proxy hop at `-c16` (latency, not
  nginx CPU); the fix does not change it, and Rapira-through-nginx stays below RoadRunner there.
- **RoadRunner's FastCGI front-end is cheap** — keeps 83–92% of its direct number, unchanged.
- **nginx version does not matter**: 1.27 / 1.30 / 1.31-alpine within noise with the fix. A bump is
  not a substitute — default upstream keepalive (since 1.29.7) applies only to an explicit
  `upstream{}` block, so 1.30/1.31 on the bare `proxy_pass` churned harder (>1300% CPU).

## Measured vs inferred

**Measured:** every req/s and CPU figure above; that the fix collapses nginx CPU 730% → ~22%; that a
version bump alone does not fix a bare `proxy_pass`.

**Scoped:** "the gap is the proxy, not the runtime" is for **this** bare app in `--mode dispatcher`
with a tiny object graph. It says nothing about Rapira **worker mode** with a large resident object
graph — a separate, real runtime cost (rapira-rs/rapira#82). This repo runs dispatcher mode, so it
neither reproduces nor contradicts that.

RR "direct" (`:8080`) is the http plugin — a different path than its proxied `:8081` route (FastCGI
to `:9000` internally). So RR direct − proxied is an **upper bound** on nginx cost, not nginx cost;
only Rapira's direct-vs-proxied comparison is apples-to-apples.

## Reproduce

```sh
docker compose up --build          # four services + two direct host ports

# via nginx                                    # direct, no nginx
wrk -t4 -c16 -d60s http://127.0.0.1:8091/      # Rapira      -> :8000
wrk -t4 -c16 -d60s http://127.0.0.1:8081/      # RoadRunner  -> :8080
# (repeat each with /render)
```

`-t4 -c16` matches the 4 workers per side. Run **one benchmark at a time** — direct and proxied
share the server's worker pool. To reproduce the pre-fix `committed` column, remove the
`upstream rapira_app {}` block from `docker/nginx/rapira.conf` (point `proxy_pass` straight at
`app-rapira:8000`) and drop `proxy_set_header Connection ""`.

## Environment

- **Servers**: `fluffydiscord/roadrunner-symfony-bundle` (nginx FastCGI) ·
  `fluffydiscord/rapira-symfony-bundle` `--mode dispatcher` (nginx HTTP proxy). Both bundles coexist
  in `config/bundles.php`; the compose `command` picks one.
- **Binaries**: `ghcr.io/roadrunner-server/roadrunner:2025.1.15`,
  `ghcr.io/rapira-rs/rapira:0.8.0-php8.5`, `nginx:1.27-alpine`. One PHP build serves both
  (`--enable-embed=shared` → Rapira `libphp.so`, `--enable-cli` → RoadRunner `php`).
- **Configs mirror sylius prod, not invented**: `.rr.yaml` verbatim from `7bcc50f^`; `rapira.toml`,
  `config/packages/*`, `docker/php/prod.ini`, `docker/nginx/rr.conf` from the same tree (DB blocks
  dropped — no database here); `docker/nginx/rapira.conf` = sylius master pattern **plus** the
  keepalive + buffers fix above.
- **Simplifications vs prod**: no database (`doctrine.preconnect` dropped, no pgsql); plain
  `MicroKernelTrait` (the two bundles' state-reset traits conflict, and a stateless app has nothing
  to reset).

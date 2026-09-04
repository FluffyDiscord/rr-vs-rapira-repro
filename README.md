# rr-vs-rapira-repro

Serves **one identical bare Symfony app** two ways, head to head:

- **RoadRunner** (`fluffydiscord/roadrunner-symfony-bundle`) behind nginx over **FastCGI**
- **Rapira** (`fluffydiscord/rapira-symfony-bundle`) behind nginx over an **HTTP reverse proxy**

## TL;DR

- **Rapira's own HTTP server is the fastest thing here** — the runtime was never the problem.
- **The Rapira nginx proxy was.** Committed `rapira.conf` had no upstream keepalive → one TCP
  handshake per request → nginx burned **~730% CPU**. Fix (`upstream { keepalive }` +
  `Connection ""` + buffers) → **~22% CPU**.
- **nginx version doesn't matter** (1.27 ≈ 1.30 ≈ 1.31) — the `upstream{}` block does.
- `/` req/s — Rapira: 58k direct, 14k → **20k** fixed via nginx. RoadRunner: 16.8k direct, 14k via
  nginx (FastCGI front-end already cheap).
- Single-host loopback numbers. On `/render`, Rapira-through-nginx trails RoadRunner (serialised
  proxy hop, not fixable by config).

## Purpose

A real Sylius app showed a latency/throughput gap between RoadRunner and Rapira. **Does it
reproduce on a bare Symfony app** — no database, no Sylius, no assets, just per-request runtime
overhead plus a small render workload? Same app, PHP build, php.ini, and nginx layer per each
server's prod topology; only the runtime differs.

## The app

Fresh Symfony 7.4 skeleton (framework-bundle + twig + runtime), two routes:

| Route         | Response                                            | Measures                          |
|---------------|-----------------------------------------------------|-----------------------------------|
| `GET /`       | `new Response('ok')` (plain text)                   | per-request runtime overhead      |
| `GET /render` | Twig template looping ~200 rows into a table        | representative render work        |

Both bundles registered in `config/bundles.php`, coexisting: RoadRunner selected by `APP_RUNTIME`
in `.rr.yaml`; Rapira uses its vendor `worker.php` entrypoint (ignores `symfony/runtime`). The
compose service `command` picks the server.

## Topology

```
wrk -> http://127.0.0.1:8081/  -> nginx-rr     --FastCGI-->      app-rr      (rr serve -c .rr.yaml)
wrk -> http://127.0.0.1:8091/  -> nginx-rapira --HTTP proxy-->   app-rapira  (rapira serve --config rapira.toml)

wrk -> http://127.0.0.1:8080/  ---------------->                 app-rr      (RR http plugin, no nginx)
wrk -> http://127.0.0.1:8000/  ---------------->                 app-rapira  (Rapira HTTP server, no nginx)
```

The FastCGI-vs-HTTP-proxy front-end is part of the comparison — it mirrors each server's prod fronting.

## Running it

```sh
docker compose up --build      # all four services; waits for healthchecks
```

Confirm 200 through each nginx:

```sh
curl -i http://127.0.0.1:8081/          # RoadRunner  -> "ok"
curl -i http://127.0.0.1:8081/render    # RoadRunner  -> HTML table
curl -i http://127.0.0.1:8091/          # Rapira      -> "ok"
curl -i http://127.0.0.1:8091/render    # Rapira      -> HTML table
```

Inspect workers:

```sh
docker compose exec app-rr rr workers -c .rr.yaml     # 4 RoadRunner workers
docker compose logs app-rapira | grep -i dispatcher   # "dispatcher worker started"
```

## Benchmark commands

Install `wrk` on the host. Compare the two ports:

```sh
# RoadRunner
wrk -t4 -c16 -d60s http://127.0.0.1:8081/
wrk -t4 -c16 -d60s http://127.0.0.1:8081/render

# Rapira
wrk -t4 -c16 -d60s http://127.0.0.1:8091/
wrk -t4 -c16 -d60s http://127.0.0.1:8091/render
```

`-t4 -c16` matches the 4 workers each side (`num_workers: 4` / `processes = 4`).

## Direct (no-nginx) benchmarks

Ports `8080` (RR) / `8000` (Rapira) hit each server's own HTTP listener, no nginx — direct HTTP throughput:

```sh
# RoadRunner direct (http plugin)
wrk -t4 -c16 -d60s http://127.0.0.1:8080/
wrk -t4 -c16 -d60s http://127.0.0.1:8080/render

# Rapira direct (HTTP server)
wrk -t4 -c16 -d60s http://127.0.0.1:8000/
wrk -t4 -c16 -d60s http://127.0.0.1:8000/render
```

Direct-throughput numbers, **not** "nginx overhead":

- **Rapira**: proxied (`:8091`) and direct (`:8000`) hit the *same* HTTP server; direct − proxied =
  nginx front-end cost (nginx CPU + extra nginx→app hop + forwarded-header processing).
- **RoadRunner**: proxied (`:8081`) = **FastCGI** listener, direct (`:8080`) = **http-plugin** listener.
  RR direct − proxied folds in nginx cost *plus* the fcgi→http change — an **upper bound** on nginx
  cost, not nginx cost. A true "FastCGI minus nginx" needs a FastCGI load tool (`wrk` is HTTP-only).
- Direct hits reach the app as `http` (no forwarded `HTTPS` / `X-Forwarded-Proto`); harmless on these
  routes, but direct ≠ the prod request.
- Direct and proxied share one process + worker pool — **run one benchmark at a time**.

## Results

Ryzen 7 9800X3D (8c/16t), `wrk -t4 -c16`, warm workers. Single-host loopback — `wrk`, nginx, and
the app share the same 16 threads, no network; not prod/networked figures. Rps drifts a few percent
run to run (thermals, contention); CPU and ratios are the stable signal. CPU sampled via
`docker stats` per container during a steady 60 s run (percent of one core; 730% = 7.3 cores).

Requests/sec (`/` = plain `ok`, `/render` = ~32 KB table):

| Server     | Route     | Direct (no nginx) | via nginx (committed) | via nginx (fixed) |
|------------|-----------|------------------:|----------------------:|------------------:|
| RoadRunner | `/`       | 16.8k             | 14.0k                 | —                 |
| RoadRunner | `/render` | 8.4k              | 7.7k                  | —                 |
| Rapira     | `/`       | 58k               | 14.2k                 | **20.6k**         |
| Rapira     | `/render` | 15.6k             | 5.3k                  | ~5.1k             |

`fixed` = current `docker/nginx/rapira.conf`; RoadRunner's front-end unchanged. To reproduce the
`committed` column, remove the `upstream rapira_app {}` block (point `proxy_pass` straight at
`app-rapira:8000`) and drop `proxy_set_header Connection ""`.

- **On `/`, Rapira's proxied gap was the nginx config, not the runtime.** Rapira's own server does
  58k; the original `rapira.conf` (bare `proxy_pass`, no upstream keepalive) opened a fresh TCP
  connection per request — **~730% CPU (7+ cores)** for ~14k rps, near-saturating the host, while
  Rapira's own workers stayed under 3 cores.
- **The fix** — explicit `upstream { keepalive }` + `proxy_set_header Connection ""` + rr.conf-sized
  buffers → nginx **~22% CPU**, `/` ~20k. `/render` is unchanged within drift (5.3k → ~5.1k): through
  nginx it is bound by the serialised proxy hop at `-c16` (latency, not config or nginx CPU), and
  Rapira-through-nginx stays below RoadRunner there. Buffers only stop the 32 KB body spooling to a temp file.
- **Server-to-server (direct), Rapira leads** — `/` 58k, `/render` 15.6k, both above RoadRunner's
  direct http-plugin numbers. Through nginx, Rapira leads on `/` after the fix but trails RR on `/render`.
- **RoadRunner's FastCGI front-end is cheap** — keeps 83–92% of its direct number. Its `:8080` direct
  is the http plugin, not the `:8081` route (FastCGI to `:9000` internally) — so RR direct − proxied
  is an upper bound on nginx cost, not nginx cost.
- **nginx version does not matter.** With the fix, 1.27 / 1.30 / 1.31-alpine land within noise
  (~20k `/`). A bump ≠ the fix: default upstream keepalive (since 1.29.7) applies only to an
  explicit `upstream{}`, so 1.30/1.31 on the bare `proxy_pass` churned harder (>1300% CPU). Kept
  1.27-alpine.

## Where each config came from (not invented)

| File                                              | Source                                                                                     |
|---------------------------------------------------|--------------------------------------------------------------------------------------------|
| `.rr.yaml`                                         | sylius repo, verbatim from `git show 7bcc50f^:.rr.yaml`                                     |
| `config/packages/fluffy_discord_road_runner.yaml` | sylius `7bcc50f^`, minus the `doctrine.preconnect` block (no DB here)                       |
| `fluffydiscord/roadrunner-symfony-bundle: ^7.1.2` | sylius composer.json history                                                                |
| `rapira.toml`                                      | sylius repo `rapira.toml`, minus the `[http.sendfile]` block (no feed dir here)            |
| `config/packages/rapira.yaml`                      | sylius repo, `warmup.enabled: true` kept, `doctrine.preconnect` dropped (no DB)            |
| `docker/php/prod.ini`                              | opcache/JIT/memory/`ffi` block copied verbatim from sylius `.docker/app/prod.Dockerfile`   |
| `Dockerfile` PHP-from-source stage                 | `rapira-symfony-bundle/tests/docker/integration.Dockerfile` (Debian trixie, PHP 8.5.x embed)|
| `docker/nginx/rr.conf`                             | FastCGI pattern from sylius prod nginx at `7bcc50f^`                                        |
| `docker/nginx/rapira.conf`                         | HTTP-proxy pattern from sylius prod nginx on master; upstream keepalive + buffers added (see Results) |
| `rr` / `rapira` binaries                           | `ghcr.io/roadrunner-server/roadrunner:2025.1.15`, `ghcr.io/rapira-rs/rapira:0.8.0-php8.5`   |

## Intentional simplifications (vs. prod)

1. **No database.** `doctrine.preconnect` dropped from both configs; no pgsql extension. Isolates
   runtime overhead from DB connection behaviour.
2. **No runtime kernel trait.** `src/Kernel.php` is a plain `MicroKernelTrait`. The two bundles'
   state-reset traits conflict, and this stateless app has nothing to reset.

One PHP build serves both: `--enable-embed=shared` gives Rapira its `libphp.so`, `--enable-cli`
gives RoadRunner its `php` binary.

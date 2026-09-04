# rr-vs-rapira-repro

A minimal, reproducible benchmark that serves **one identical bare Symfony app** two ways and
lets you compare them head to head:

- **RoadRunner** (`fluffydiscord/roadrunner-symfony-bundle`) behind nginx over **FastCGI**
- **Rapira** (`fluffydiscord/rapira-symfony-bundle`) behind nginx over an **HTTP reverse proxy**

## Purpose

On our real Sylius app we measured a latency/throughput gap between RoadRunner and Rapira. This
repo isolates the question: **does that gap reproduce on a bare Symfony app**, with no database,
no Sylius, no assets — just the per-request runtime overhead of each server plus a small render
workload? Same app, same PHP build, same php.ini, same nginx layer per each server's real prod
topology. The only thing that differs is the runtime.

## The app

A fresh Symfony 7.4 skeleton (framework-bundle + twig + runtime), two routes:

| Route      | Response                                               | What it measures                              |
|------------|--------------------------------------------------------|-----------------------------------------------|
| `GET /`      | `new Response('ok')` (plain text)                      | pure per-request runtime overhead             |
| `GET /render`| a Twig template looping ~200 rows building a table    | representative render work, not network-bound |

Both runtime bundles are registered in `config/bundles.php` and **coexist**: RoadRunner is
selected at runtime by the `APP_RUNTIME` env in `.rr.yaml`; Rapira uses its own `worker.php`
entrypoint (from vendor) that ignores `symfony/runtime`. Only the compose service's `command`
decides which server actually runs.

## Topology

```
wrk -> http://127.0.0.1:8081/  -> nginx-rr     --FastCGI-->      app-rr      (rr serve -c .rr.yaml)
wrk -> http://127.0.0.1:8091/  -> nginx-rapira --HTTP proxy-->   app-rapira  (rapira serve --config rapira.toml)
```

The FastCGI-vs-HTTP-proxy front-end layer is deliberately part of the comparison — it mirrors how
each server is fronted in our real prod, and is part of the difference we measured.

## Running it

```sh
docker compose up --build      # brings up all four services; waits for healthchecks
```

Confirm both endpoints serve (200) through their own nginx:

```sh
curl -i http://127.0.0.1:8081/          # RoadRunner  -> "ok"
curl -i http://127.0.0.1:8081/render    # RoadRunner  -> HTML table
curl -i http://127.0.0.1:8091/          # Rapira      -> "ok"
curl -i http://127.0.0.1:8091/render    # Rapira      -> HTML table
```

Inspect the workers:

```sh
docker compose exec app-rr rr workers -c .rr.yaml     # 4 RoadRunner workers
docker compose logs app-rapira | grep -i dispatcher   # "dispatcher worker started"
```

## Benchmark commands

Run each against the same paths; compare the two ports. (Install `wrk` on the host first.)

```sh
# RoadRunner
wrk -t4 -c16 -d60s http://127.0.0.1:8081/
wrk -t4 -c16 -d60s http://127.0.0.1:8081/render

# Rapira
wrk -t4 -c16 -d60s http://127.0.0.1:8091/
wrk -t4 -c16 -d60s http://127.0.0.1:8091/render
```

`-t4 -c16` matches the 4 workers configured on both sides (`num_workers: 4` / `processes = 4`),
so neither server is starved of or flooded past its worker count.

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
| `docker/nginx/rapira.conf`                         | HTTP-proxy pattern from sylius prod nginx on master                                        |
| `rr` / `rapira` binaries                           | `ghcr.io/roadrunner-server/roadrunner:2025.1.15`, `ghcr.io/rapira-rs/rapira:0.8.0-php8.5`   |

## Intentional simplifications (vs. our real prod)

1. **No database.** The `doctrine.preconnect` blocks were dropped from both bundle configs and
   there is no pgsql extension. This isolates runtime overhead from DB connection behaviour.
2. **No runtime kernel trait.** `src/Kernel.php` is a plain `MicroKernelTrait` kernel. Neither
   bundle's state-reset kernel trait is added: the two traits conflict with each other, and this
   stateless app (no DB, no request-scoped services) has nothing for them to reset.

One PHP build serves both: `--enable-embed=shared` gives Rapira its `libphp.so`, `--enable-cli`
gives RoadRunner its `php` binary.

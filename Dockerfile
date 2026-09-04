# One app image that both RoadRunner and Rapira run. Rapira needs libphp.so (--enable-embed),
# RoadRunner needs the php CLI — a single from-source build with --enable-embed=shared
# --enable-cli gives both. Which server runs is chosen by the compose service CMD, not the image.
#
# Mirrors the real prod images:
#   - PHP 8.5.x from source on Debian trixie, the OS the Rapira binary is built against
#     (template: rapira-symfony-bundle/tests/docker/integration.Dockerfile)
#   - prod php.ini opcache/JIT/memory tuning copied verbatim from the sylius prod image
#   - the same pinned rr / rapira binaries we pull in prod

# ---------------------------------------------------------------------------
# Stage 1: build the PHP embed library + CLI from source
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS php-build

ARG PHP_VERSION=8.5.10
ARG PHP_SHA256=f5c0ac99b85b3d677de475c2e4f509f9b4f54663f3ee5a84d6d9481a521d4100

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl build-essential pkg-config autoconf bison re2c \
        libxml2-dev libssl-dev libcurl4-openssl-dev libonig-dev zlib1g-dev libicu-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/php
RUN curl -fsSL "https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz" -o php.tar.gz \
    && echo "${PHP_SHA256}  php.tar.gz" | sha256sum -c - \
    && tar xzf php.tar.gz --strip-components=1 \
    && rm php.tar.gz

# Extensions trimmed to what a Symfony + Twig app needs: no pgsql/gd/vips/redis.
RUN ./configure \
        --prefix=/usr/local \
        --with-config-file-path=/usr/local/etc/php \
        --with-config-file-scan-dir=/usr/local/etc/php/conf.d \
        --enable-embed=shared --enable-cli --enable-opcache \
        --enable-session --enable-mbstring --enable-tokenizer --enable-ctype \
        --enable-filter --enable-fileinfo --enable-phar --enable-posix --enable-pcntl \
        --enable-sockets \
        --with-openssl --with-curl --with-zlib --with-pcre-jit --with-iconv \
        --enable-dom --enable-xml --enable-simplexml --enable-xmlreader --enable-xmlwriter \
        --enable-intl \
        --without-sqlite3 --without-pdo-sqlite --disable-pdo \
    && make -j"$(nproc)" && make install \
    && mkdir -p /usr/local/etc/php/conf.d

# ---------------------------------------------------------------------------
# Stage 2: assemble the runtime with the app, both server binaries and prod php.ini
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS app

RUN apt-get update && apt-get install -y --no-install-recommends \
        libxml2 libssl3t64 libcurl4t64 libonig5 zlib1g libicu76 ca-certificates git unzip \
    && rm -rf /var/lib/apt/lists/*

COPY --from=php-build /usr/local/ /usr/local/
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
COPY --from=ghcr.io/roadrunner-server/roadrunner:2025.1.15 /usr/bin/rr /usr/local/bin/rr
COPY --from=ghcr.io/rapira-rs/rapira:0.8.0-php8.5 /usr/local/bin/rapira /usr/local/bin/rapira

# Prod php.ini (opcache/JIT/memory) copied verbatim from the sylius prod image.
COPY docker/php/prod.ini /usr/local/etc/php/php.ini

RUN php -v && rr --version && rapira --version

# The app user (uid 1000) that .rr.yaml's `server.user: app` forks its workers under.
RUN groupadd --gid 1000 app && useradd --uid 1000 --gid 1000 --create-home app

WORKDIR /usr/src/myapp

# Composer layer first so vendor is cached across app-source edits.
COPY composer.json composer.lock ./
ENV APP_ENV=prod
ENV APP_DEBUG=0
RUN --mount=type=cache,target=/root/.composer/cache \
    composer install --no-dev --optimize-autoloader --no-scripts --no-interaction

COPY . .

RUN composer dump-autoload --no-dev --optimize --classmap-authoritative \
    && php bin/console cache:warmup --env=prod \
    && mkdir -p var/cache var/log \
    && chown -R app:app /usr/src/myapp

EXPOSE 9000 8000

# Overridden per compose service: `rr serve -c .rr.yaml` or `rapira serve --config rapira.toml`.
CMD ["rr", "serve", "-c", ".rr.yaml"]

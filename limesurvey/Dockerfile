# syntax=docker/dockerfile:1
#
# LimeSurvey on PHP/Apache, running as www-data on port 8080.
# The code tree is immutable; only upload/, tmp/ and the generated config
# files (via symlinks into /var/lib/limesurvey) are writable at runtime.

ARG PHP_VERSION=8.3

# ---- Fetch and verify the release ----
FROM debian:bookworm-slim AS source
ARG LIMESURVEY_VERSION=7.10.0+261109
ARG LIMESURVEY_SHA256=372551db149955883c4942d492c6c252ca31e55ad53e0561e1576d6d18e7c217
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN curl -fsSL -o ls.tar.gz \
      "https://github.com/LimeSurvey/LimeSurvey/archive/refs/tags/${LIMESURVEY_VERSION}.tar.gz" \
 && echo "${LIMESURVEY_SHA256}  ls.tar.gz" | sha256sum -c - \
 && mkdir app \
 && tar xzf ls.tar.gz --strip-components=1 -C app \
 && rm ls.tar.gz \
 # Not needed at runtime: dev tooling, docs, tests. (node_modules stays:
 # LimeSurvey publishes JS packages from it at runtime.)
 && cd app \
 && rm -rf .claude .github .git* .editorconfig .scrutinizer.yml .travis.yml \
           docs tests phpunit.xml* psalm*.xml phpci.yml \
           phpcs.ruleset.xml gulpfile.js package.json yarn.lock \
           open-api-gen.php CONTRIBUTING.md \
 # Runtime config lives on a volume; the code tree only holds symlinks.
 && ln -s /var/lib/limesurvey/config.php   application/config/config.php \
 && ln -s /var/lib/limesurvey/security.php application/config/security.php

# ---- Runtime ----
FROM php:${PHP_VERSION}-apache-bookworm

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev \
      libzip-dev libicu-dev libldap2-dev libonig-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-configure ldap --with-libdir=lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH); \
    docker-php-ext-install -j"$(nproc)" gd zip intl ldap pdo_mysql opcache exif; \
    # keep runtime libs, drop -dev packages
    apt-mark manual libfreetype6 libjpeg62-turbo libpng16-16 libwebp7 libzip4 'libicu72' libldap-2.5-0; \
    apt-get purge -y --auto-remove \
      libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev \
      libzip-dev libicu-dev libldap2-dev libonig-dev; \
    rm -rf /var/lib/apt/lists/*; \
    a2enmod rewrite headers remoteip; \
    a2disconf other-vhosts-access-log serve-cgi-bin; \
    # Non-root Apache: listen on 8080, no privileged port needed.
    sed -ri 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf; \
    sed -ri '/Listen 443/d' /etc/apache2/ports.conf; \
    mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

COPY apache.conf /etc/apache2/sites-available/000-default.conf
COPY php.ini "$PHP_INI_DIR/conf.d/zz-limesurvey.ini"
COPY entrypoint.sh /usr/local/bin/limesurvey-entrypoint
COPY healthz.php /usr/local/share/limesurvey/healthz.php
COPY --from=source --chown=root:root /src/app /var/www/html

RUN set -eux; \
    chmod 0755 /usr/local/bin/limesurvey-entrypoint; \
    # Code is root-owned and read-only for www-data.
    chown root:root /var/www/html; \
    chmod -R a-w,u+w /var/www/html; \
    install -d -o www-data -g www-data -m 0750 /var/lib/limesurvey; \
    chown -R www-data:www-data /var/www/html/upload /var/www/html/tmp; \
    chmod -R u+w /var/www/html/upload /var/www/html/tmp; \
    # Apache runtime dirs must be writable by www-data (tmpfs in compose).
    install -d -o www-data -g www-data /var/run/apache2 /var/lock/apache2

ENV TZ=UTC \
    APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data \
    APACHE_PID_FILE=/var/run/apache2/apache2.pid \
    APACHE_RUN_DIR=/var/run/apache2 \
    APACHE_LOCK_DIR=/var/lock/apache2

USER www-data
WORKDIR /var/www/html
EXPOSE 8080
VOLUME ["/var/www/html/upload", "/var/lib/limesurvey"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["limesurvey-entrypoint"]
CMD ["apache2-foreground"]

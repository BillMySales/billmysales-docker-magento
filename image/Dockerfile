# Mage-OS (Magento Open Source distribution) on the official PHP-FPM Alpine image.
ARG PHP_VERSION=8.5

# ---------------------------------------------------------------------------
# Runtime base: PHP-FPM with the extensions Mage-OS and its dependencies
# require (sockets is needed by php-amqplib; ctype, curl, dom, hash, iconv,
# mbstring, openssl, simplexml, sodium and opcache are already in the base
# image).
# ---------------------------------------------------------------------------
FROM php:${PHP_VERSION}-fpm-alpine AS base
RUN set -eux; \
    # icu-data-full: locale data for intl (Alpine ships English only):
    # Magento formats prices, numbers and dates with intl, so any locale
    # but en_US would read "CLP 9,990" instead of e.g. "$9.990" (es_CL).
    apk add --no-cache su-exec icu-data-full; \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS freetype-dev icu-dev libjpeg-turbo-dev libpng-dev libwebp-dev \
        libxml2-dev libxslt-dev libzip-dev linux-headers; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" bcmath gd intl pdo_mysql soap sockets xsl zip; \
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
            | tr ',' '\n' | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .magento-rundeps $runDeps; \
    apk del --no-network .build-deps; \
    php -m | grep -qi -e '^intl$' -e '^xsl$'

# ---------------------------------------------------------------------------
# Build: Mage-OS with Composer, compiled for production mode (dependency
# injection and static content) without a database.
# ---------------------------------------------------------------------------
FROM base AS build
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
RUN apk add --no-cache git unzip

ARG MAGEOS_VERSION=3.5.0
# Modules to disable, space separated (e.g. the admin 2FA modules for development).
ARG MAGEOS_DISABLE_MODULES=""
# Locales and themes to deploy static content for.
ARG MAGEOS_LOCALES="en_US"
# (Mage-OS's admin uses MageOS/m137-admin-theme, a child of Magento/backend.)
ARG MAGEOS_THEMES="Magento/luma Magento/backend MageOS/m137-admin-theme"

ENV COMPOSER_MEMORY_LIMIT=-1 COMPOSER_ALLOW_SUPERUSER=1
WORKDIR /src
RUN --mount=type=cache,target=/root/.composer/cache \
    composer create-project --no-interaction --no-progress --no-dev \
        --repository-url=https://repo.mage-os.org/ \
        "mage-os/project-community-edition=${MAGEOS_VERSION}" /src

COPY build-scopes.php /tmp/build-scopes.php
RUN set -eux; \
    php bin/magento module:enable --all; \
    if [ -n "${MAGEOS_DISABLE_MODULES}" ]; then \
        # shellcheck disable=SC2086
        php bin/magento module:disable ${MAGEOS_DISABLE_MODULES}; \
    fi; \
    # Optimized autoloader *before* compiling: generated classes stay out of
    # the classmap (loaded from generated/code), so developer mode, which
    # regenerates them on demand, works with the same image.
    composer dump-autoload --no-dev --optimize; \
    php -d memory_limit=-1 bin/magento setup:di:compile; \
    # Static content needs the store scopes, normally read from the database:
    # add a fresh install's scopes temporarily, then restore config.php.
    cp app/etc/config.php /tmp/config.php; \
    php /tmp/build-scopes.php app/etc/config.php; \
    themes=""; for theme in ${MAGEOS_THEMES}; do themes="${themes} --theme=${theme}"; done; \
    # shellcheck disable=SC2086
    php -d memory_limit=-1 bin/magento setup:static-content:deploy -f --jobs="$(nproc)" ${themes} ${MAGEOS_LOCALES}; \
    cp /tmp/config.php app/etc/config.php; \
    rm -rf var/* pub/media/catalog/* ; \
    # Build id: `setup` syncs the code (and runs setup:upgrade) whenever it
    # changes, also for a rebuild of the same version.
    echo "${MAGEOS_VERSION} $(date -u +%Y%m%dT%H%M%SZ)" > .build; \
    chown -R www-data:www-data /src

# ---------------------------------------------------------------------------
# Final image: the compiled project in /usr/src/magento. The stack's `setup`
# service syncs it to the code volume whenever the version changes (keeping
# app/etc/env.php, var/ and pub/media) and runs the database upgrade.
# ---------------------------------------------------------------------------
FROM base AS final
# rsync: used by `setup` to sync the code to the code volume.
RUN apk add --no-cache rsync
COPY opcache.ini /usr/local/etc/php/conf.d/opcache-recommended.ini
COPY --from=build /src /usr/src/magento
RUN mkdir -p /var/www/magento && chown www-data:www-data /var/www/magento

ARG MAGEOS_VERSION=3.5.0
ENV MAGEOS_VERSION=${MAGEOS_VERSION}
WORKDIR /var/www/magento

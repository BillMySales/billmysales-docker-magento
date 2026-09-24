#!/bin/sh
# Installs or upgrades Mage-OS and applies the stack's environment.
#
# Runs as root on every `docker compose up` and is safe to repeat:
# - Syncs the compiled code from the image to the code volume whenever the
#   image changes (its build id: a new version, or a rebuild with other
#   modules/themes), keeping app/etc/env.php, var/, pub/media and app/code.
# - Installs Mage-OS (setup:install) if the database is empty; otherwise runs
#   setup:upgrade after an image change (new version, modules or themes).
# - Applies URL, admin path, database credentials and SMTP from the
#   environment, and one-time initial settings (store name, country,
#   indexers on schedule).
# - MAGE_MODE=developer (for module development, see overrides/module.yaml)
#   switches to developer mode and enables MAGE_ENABLE_MODULES.
set -eu

CODE=/var/www/magento
SRC=/usr/src/magento
STACK=/usr/local/share/stack/scripts
cd "${CODE}"

as_www() { su-exec www-data "$@"; }
magento() { as_www php -d memory_limit="${PHP_CLI_MEMORY_LIMIT}" bin/magento --no-interaction "$@"; }
db() { as_www php "${STACK}/db.php" "$@"; }
flush=0

# Sets a config value only if it differs (config:set needs a cache flush).
set_config() {
    if [ "$(magento config:show "$1" 2>/dev/null || true)" != "$2" ]; then
        magento config:set "$1" "$2" > /dev/null
        echo "    $1 updated"
        flush=1
    fi
}

# Code from the image. Never touches env.php, media, var/ or app/code (local
# modules, possibly mounted from the host: --delete must not reach them). In
# developer mode, generated code and static files are built on demand, so the
# image's compiled ones are not copied.
sync_code() {
    if [ "${MAGE_MODE}" = developer ]; then
        dev_excludes="--exclude /generated/ --exclude /pub/static/"
    else
        dev_excludes=""
    fi
    # shellcheck disable=SC2086 # dev_excludes is a list of options
    # The markers (.build, .version) are written last, after a successful run.
    rsync -a --delete \
        --exclude /.build --exclude /.version \
        --exclude /app/etc/env.php --exclude /app/code/ --exclude /pub/media/ --exclude /var/ \
        ${dev_excludes} "${SRC}/" "${CODE}/"
    mkdir -p var pub/media pub/static generated app/code
    chown www-data:www-data var pub/media pub/static generated app/code
}

# The mount points may be root-owned (e.g. new bind mounts), and files created
# by root (docker compose exec, restores) would block Magento's permission
# checks: fix owners, only where they don't match (fast on big media dirs).
chown www-data:www-data "${CODE}"
mkdir -p pub/media var
find pub/media var app/etc ! -user www-data -exec chown www-data:www-data {} + 2>/dev/null || true

image_changed=0
if [ "$(cat .build 2>/dev/null || true)" != "$(cat "${SRC}/.build")" ]; then
    echo "==> Syncing Mage-OS code: image $(cat "${SRC}/.build") (was: $(cat .build 2>/dev/null || echo none))"
    sync_code
    image_changed=1
fi

case "${MAGE_URL}" in https://*) secure=1 ;; *) secure=0 ;; esac
url="${MAGE_URL%/}/"

# Separate assignments: with `set -e`, a failing helper aborts setup here.
installed="$(db installed)"
if [ -z "${installed}" ]; then
    echo "==> Installing Mage-OS ${MAGEOS_VERSION} at ${url}"
    rm -f app/etc/env.php
    if [ "${secure}" = 1 ]; then
        secure_options="--base-url-secure=${url} --use-secure=1 --use-secure-admin=1"
    else
        secure_options="--use-secure=0 --use-secure-admin=0"
    fi
    # shellcheck disable=SC2086 # secure_options is a list of options
    magento setup:install \
        --base-url="${url}" ${secure_options} \
        --db-host="${DB_HOST}" --db-name="${DB_NAME}" \
        --db-user="${DB_USER}" --db-password="${DB_PASSWORD}" \
        --admin-user="${MAGE_ADMIN_USER}" --admin-password="${MAGE_ADMIN_PASSWORD}" \
        --admin-email="${MAGE_ADMIN_EMAIL}" \
        --admin-firstname=Admin --admin-lastname=Store \
        --backend-frontname="${MAGE_ADMIN_PATH}" \
        --language="${MAGE_LOCALE}" --currency="${MAGE_CURRENCY}" \
        --timezone="${PHP_TIMEZONE}" --use-rewrites=1 \
        --search-engine=opensearch --opensearch-host="${OPENSEARCH_HOST}" \
        --opensearch-port="${OPENSEARCH_PORT}" --opensearch-index-prefix=magento \
        --session-save=files
    flush=1
elif [ "${image_changed}" = 1 ]; then
    echo "==> Upgrading database for Mage-OS ${MAGEOS_VERSION} ($(cat .version 2>/dev/null || echo unknown) before)"
    magento setup:upgrade --keep-generated
    flush=1
fi
# setup:install/upgrade may clean generated code and static files: restore them.
if [ "${flush}" = 1 ] && [ "${MAGE_MODE}" = production ]; then
    sync_code
fi

# Mode: production (compiled code and static files from the image) or developer.
if ! magento deploy:mode:show | grep -q "mode: ${MAGE_MODE}"; then
    echo "==> Switching to ${MAGE_MODE} mode"
    magento deploy:mode:set "${MAGE_MODE}" --skip-compilation > /dev/null
    if [ "${MAGE_MODE}" = production ]; then
        sync_code
    fi
    flush=1
fi

# Extra modules (developer mode): enable them and register them in the database.
if [ -n "${MAGE_ENABLE_MODULES}" ]; then
    to_enable=""
    for module in ${MAGE_ENABLE_MODULES}; do
        if ! magento module:status "${module}" | grep -q "Module is enabled"; then
            to_enable="${to_enable} ${module}"
        fi
    done
    if [ -n "${to_enable}" ]; then
        echo "==> Enabling modules:${to_enable}"
        # shellcheck disable=SC2086 # list of module names
        magento module:enable ${to_enable}
        magento setup:upgrade
        flush=1
    fi
fi

# Markers last: a failed sync, install or upgrade is retried on the next run.
cp "${SRC}/.build" .build
echo "${MAGEOS_VERSION}" > .version
chown www-data:www-data .build .version

echo "==> Applying environment (env.php, URLs, SMTP)"
before="$(cksum < app/etc/env.php)"
magento setup:config:set \
    --backend-frontname="${MAGE_ADMIN_PATH}" \
    --db-host="${DB_HOST}" --db-name="${DB_NAME}" \
    --db-user="${DB_USER}" --db-password="${DB_PASSWORD}" > /dev/null
if [ "${before}" != "$(cksum < app/etc/env.php)" ]; then
    echo "    app/etc/env.php updated"
    flush=1
fi
set_config web/unsecure/base_url "${url}"
set_config web/secure/base_url "${url}"
set_config web/secure/use_in_frontend "${secure}"
set_config web/secure/use_in_adminhtml "${secure}"

if [ -n "${SMTP_HOST}" ]; then
    case "$(echo "${SMTP_SECURE}" | tr '[:upper:]' '[:lower:]')" in
        tls) ssl=tls ;;
        ssl) ssl=ssl ;;
        *) ssl= ;;
    esac
    set_config system/smtp/transport smtp
    set_config system/smtp/host "${SMTP_HOST}"
    # shellcheck disable=SC2153 # set by compose
    set_config system/smtp/port "${SMTP_PORT}"
    set_config system/smtp/ssl "${ssl}"
    if [ -n "${SMTP_USER}" ]; then
        set_config system/smtp/auth login
        set_config system/smtp/username "${SMTP_USER}"
        # Encrypted in the database: compare the stored hash via config:show is
        # not possible, so the password is (re)written on every run.
        magento config:set system/smtp/password "${SMTP_PASSWORD}" > /dev/null
    else
        set_config system/smtp/auth none
    fi
    if [ -n "${SMTP_FROM}" ]; then
        set_config trans_email/ident_general/email "${SMTP_FROM}"
    fi
fi

initialized="$(db get docker_stack/initialized)"
if [ -z "${initialized}" ]; then
    echo "==> Initial settings"
    set_config general/store_information/name "${MAGE_STORE_NAME}"
    set_config general/country/default "${MAGE_COUNTRY}"
    set_config general/locale/code "${MAGE_LOCALE}"
    magento indexer:set-mode schedule > /dev/null
    magento indexer:reindex > /dev/null
    db set docker_stack/initialized "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    flush=1
fi

if [ "${flush}" = 1 ]; then
    echo "==> Flushing cache"
    magento cache:flush > /dev/null
fi

echo "==> Done: Mage-OS ${MAGEOS_VERSION}"
echo "    Store: ${url}"
echo "    Admin: ${url}${MAGE_ADMIN_PATH} (${MAGE_ADMIN_USER})"

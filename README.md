Mage-OS Docker stack
====================

Docker Compose stack for a [Mage-OS](https://mage-os.org) store (the
community distribution of Magento Open Source, installed without Adobe
Marketplace keys), usable for local development and for simple production
deployments (a single server). Maintained by
[BillMySales](https://www.billmysales.com).

| Component  | Image                                        | Default version        |
|------------|----------------------------------------------|------------------------|
| Web server | `caddy:<ver>-alpine`                         | 2.11                   |
| Mage-OS    | built from `image/` (`php:<ver>-fpm-alpine`) | 3.5.0 (Magento 2.4.9) / PHP 8.5 |
| Database   | `mariadb`                                    | 12.3 (LTS)             |
| Search     | `opensearchproject/opensearch`               | 3.8.0                  |
| Mailpit    | `axllent/mailpit` (optional, dev)            | v1.31                  |

Versions follow Magento 2.4.9's system requirements: PHP 8.5, MariaDB 12.3
(recommended), OpenSearch 3 (required: Magento has no database search, and
the installer only accepts `opensearch` or `elasticsearch8`).
There is no maintained Mage-OS Docker image (`mage-os/dockerfiles` is empty),
so `image/Dockerfile` builds one: Mage-OS installed with Composer from
`repo.mage-os.org`, dependency injection compiled and static content
deployed at build time, so the image is ready for production mode (~810 MB).
It includes `icu-data-full` (Alpine's ICU has English locale data only):
Magento formats prices, numbers and dates with `intl`, so with any locale
but `en_US` CLP would read `CLP 9,990` instead of `$9.990` (`es_CL`).

Requirements
------------

- Docker Engine 24+ with the Compose v2 plugin (`docker compose`, 2.24+).
- **RAM: 8 GB for Docker** (Docker Desktop: Settings > Resources). The stack
  uses about 1.4 GB idle (OpenSearch alone ~1 GB), more during installs,
  upgrades and image builds. With 4 GB the kernel killed processes (OpenSearch,
  other containers) during installs.
- **Disk:** about 5 GB for images and volumes, plus room for builds. OpenSearch
  blocks index creation over 95% and shard allocation over 90% of its own
  disk (the host's disk with `overrides/local-dirs.yaml`).
- Development: ports 8103, 8403 and 8025 free on the host.
- Production: a server with ports 80 and 443 reachable, and a DNS record for
  the store's domain pointing to it.
- The first `up` builds the image (5–7 minutes: Composer, compilation, static
  content).

Quick start (development)
-------------------------

```shell
cp .env.dev.example .env
docker compose up -d
docker compose logs -f setup   # wait for "==> Done"
```

- Store: http://localhost:8103
- Admin: http://localhost:8103/admin_dev (user `admin`, password `admin12345`)
- Mailpit (every email the store sends): http://localhost:8025

The development template builds a separate image (`mageos-fpm-dev`) without
the admin two-factor authentication module (`Magento_TwoFactorAuth`): 2FA
can only be turned off by disabling the module, which needs a recompile
(`MAGEOS_DISABLE_MODULES`). Production keeps 2FA.

Production
----------

```shell
cp .env.prod.example .env
# Fill in MAGE_URL, SITE_ADDRESS, DB_PASSWORD, DB_ROOT_PASSWORD,
# MAGE_ADMIN_PASSWORD, MAGE_ADMIN_EMAIL and MAGE_ADMIN_PATH.
# Recommended: the SMTP_* values (without SMTP_HOST no emails are sent).
docker compose up -d
```

- With `SITE_ADDRESS` set to the domain, Caddy gets a Let's Encrypt certificate
  and renews it automatically (certificates live in the `caddy_data` volume).
- Behind an existing Traefik (no host ports), use `overrides/traefik.yaml`
  (see [Overrides](#overrides)).
- Compose refuses to start while a required value is missing.
- Configure SMTP (recommended, not required): without `SMTP_HOST` no emails
  are sent (the image has no local mail server).
- **Two-factor authentication is on**: the first admin login asks to set up a
  2FA provider (Google Authenticator by default), with a link sent by email,
  so configure SMTP first. The admin REST token endpoint also requires it.
- Use a hard-to-guess admin path (`MAGE_ADMIN_PATH`: letters, digits and
  underscores).
- The `backup` profile is enabled by default in the production template.

Services
--------

| Service      | Profile   | Role                                                           |
|--------------|-----------|----------------------------------------------------------------|
| `db`         |           | MariaDB, data in the `db_data` volume.                         |
| `opensearch` |           | Search engine, single node, internal only.                     |
| `setup`      |           | One-shot job (`scripts/setup.sh`), runs on every `up`.         |
| `magento`    |           | PHP-FPM + Mage-OS (port 9000, internal).                       |
| `cron`       |           | Runs `bin/magento cron:run` every minute (indexers, emails,    |
|              |           | queue consumers, cleanups).                                    |
| `caddy`      |           | Web server and TLS, the only published ports (80, 443).        |
| `backup`     | `backup`  | DB dump + media and `env.php` on a schedule.                   |
| `mailpit`    | `mailpit` | Development SMTP server that catches all mail.                 |
| `console`    | `tools`   | `bin/magento`, not started by `up`.                            |

Volumes:

| Volume            | Mounted at                    | Contents                                   |
|-------------------|-------------------------------|--------------------------------------------|
| `code`            | `/var/www/magento`            | The project, synced from the image; keeps  |
|                   |                               | `app/etc/env.php` (database credentials,   |
|                   |                               | encryption key), `var/` and `app/code/`.   |
| `media`           | `/var/www/magento/pub/media`  | Product images and uploads.                |
| `db_data`         | `/var/lib/mysql`              | Database.                                  |
| `opensearch_data` | `/usr/share/opensearch/data`  | Search indices (rebuildable).              |

### What `setup` does

- Syncs the compiled code from the image to the `code` volume (`rsync`)
  whenever the image changes (its build id in `.build`: a new version, or a
  rebuild with other modules, themes or locales), never touching `env.php`,
  media, `var/` or `app/code/`.
- Empty database: `setup:install` (URL, admin, `MAGE_LOCALE`, `MAGE_CURRENCY`,
  timezone, OpenSearch, admin path). After an image change:
  `setup:upgrade --keep-generated`. The markers are written last, so a failed
  sync, install or upgrade is retried on the next `up`. **Upgrading Mage-OS is changing
  `MAGEOS_VERSION` and running `docker compose up -d --build`** (back up
  first).
- Sets the mode (`MAGE_MODE`: production, or developer for module
  development).
- On every run: admin path and database credentials in `env.php`
  (`setup:config:set`), base URLs and HTTPS from `MAGE_URL`, and, when
  `SMTP_HOST` is set, the mail settings from `SMTP_*`.
- Once: store name, default country, locale, indexers on "Update by
  schedule" and a full reindex; stores `docker_stack/initialized`, so later
  changes in the admin are kept.
- Fixes file owners that don't match `www-data` (files created by
  `docker compose exec` as root would block Magento's permission checks).

Common commands
---------------

```shell
docker compose ps                                  # every service "healthy", setup "Exited (0)"
docker compose logs -f caddy magento cron          # web server, PHP and cron logs
docker compose run --rm console indexer:status     # any bin/magento command
docker compose run --rm console cache:flush
docker compose exec -u www-data magento sh         # shell as the web user
docker compose exec db mariadb -u magento -p magento   # SQL shell
docker compose down                                # stop, keep data
docker compose down -v                             # stop and DELETE all data
```

Use `-u www-data` with `docker compose exec`: files created as root in `var/`
or `pub/media` break Magento until the next `setup` run fixes their owner.

Backups
-------

With the `backup` profile, the `backup` service writes
`<timestamp>-db.sql.gz` and `<timestamp>-files.tar.gz` (`pub/media` and
`app/etc/env.php`, which holds the encryption key needed to read stored
secrets; the code comes from the image) to the `backups` volume (or
`./data/backups` with `overrides/local-dirs.yaml`) at start and then every
`BACKUP_INTERVAL_HOURS`, and deletes files older than `BACKUP_KEEP_DAYS`.
Files are readable by their owner only. Search indices are rebuilt by
reindexing.

```shell
docker compose run --rm --no-deps backup now                  # back up now
docker compose run --rm --no-deps backup list                 # list timestamps
docker compose stop magento cron                    # recommended while restoring
docker compose run --rm --no-deps backup restore <timestamp>  # restore DB, media and env.php
docker compose up -d
docker compose run --rm console cache:flush
docker compose run --rm console indexer:reindex     # if search results are stale
```

`--no-deps` keeps the command from starting `setup` first (with damaged
data `setup` fails and the restore would never run); the database must
be running (`docker compose up -d db` if the stack is down).

Overrides
---------

Optional compose files in `overrides/`, enabled with `COMPOSE_FILE` in `.env`
(several are combined with `:`). Each file documents its variables.

```shell
COMPOSE_FILE=compose.yaml:overrides/traefik.yaml:overrides/local-dirs.yaml
```

| File                         | Purpose                                                           |
|------------------------------|-------------------------------------------------------------------|
| `overrides/traefik.yaml`     | Publish through an existing Traefik on a shared external network: |
|                              | no host ports, Traefik terminates TLS (`TRAEFIK_HOST`, ...).      |
| `overrides/local-dirs.yaml`  | Database, OpenSearch, code, media, Caddy and backups in local     |
|                              | directories (`DATA_DIR`, default `./data`).                       |
| `overrides/module.yaml`      | Develop a module live: mounted into `app/code`, developer mode,   |
|                              | enabled by `setup` (`MODULE_PATH`, `MODULE_DIR`, `MODULE_NAME`).  |

With `overrides/module.yaml`, Magento runs in developer mode: code and static
files are generated on first use (slower pages), and changes to the module's
PHP, templates and web assets are picked up without rebuilding. Removing the
override switches back to production mode on the next `up`. To ship a module
to production, add it to the image.

A local `compose.override.yaml` (gitignored) is also loaded automatically by
Docker Compose, for changes specific to one machine.

Configuration
-------------

Every variable is documented in `.env.prod.example`. Main groups:

- **Site and network**: `MAGE_URL`, `SITE_ADDRESS`, `HTTP_BIND`, `HTTP_PORT`,
  `HTTPS_PORT`.
- **Credentials and admin** (required): `DB_PASSWORD`, `DB_ROOT_PASSWORD`,
  `MAGE_ADMIN_PASSWORD` (letters and numbers, 7+ characters),
  `MAGE_ADMIN_EMAIL`, `MAGE_ADMIN_PATH`; `MAGE_ADMIN_USER`. The admin user,
  password and email are only used by the installer: changing them later
  doesn't change the account.
- **Store** (first install only): `MAGE_STORE_NAME`, `MAGE_LOCALE`,
  `MAGE_CURRENCY` (default `CLP`), `MAGE_COUNTRY`; `PHP_TIMEZONE` (the store's
  time zone on the first install, PHP's `date.timezone` on every start).
- **Versions and image**: `MAGEOS_VERSION`, `PHP_VERSION`, `MAGEOS_IMAGE`,
  `MAGEOS_DISABLE_MODULES`, `MAGEOS_LOCALES` and `MAGEOS_THEMES` (static
  content built into the image: every locale/theme a store or admin user uses
  must be listed; the admin uses Mage-OS's `MageOS/m137-admin-theme`, and in
  production mode a missing theme shows pages without styles), `OPENSEARCH_VERSION`, `CADDY_VERSION`, `MARIADB_VERSION`.
- **PHP and OpenSearch**: `MAGE_MODE`, `PHP_DISPLAY_ERRORS`,
  `PHP_MEMORY_LIMIT` (web), `PHP_CLI_MEMORY_LIMIT` (setup, cron, console),
  `UPLOAD_MAX_SIZE` (PHP and Caddy), the FPM pool, `OPENSEARCH_HEAP`.
- **Mail**: `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`,
  `SMTP_PASSWORD`, `SMTP_FROM` (General Contact sender) — Magento's built-in
  SMTP transport.
- **Resources and logs**: `*_MEMORY_LIMIT` per service (including `setup`),
  `LOG_MAX_SIZE`, `LOG_MAX_FILE` (Docker log rotation).

Files:

| File                                   | Purpose                                                     |
|----------------------------------------|-------------------------------------------------------------|
| `image/Dockerfile`                     | Mage-OS image (base, build, final stages).                  |
| `image/build-scopes.php`               | Build only: store scopes for static content without a DB.   |
| `image/opcache.ini`                    | OPcache (timestamps checked only in developer mode).        |
| `config/caddy/Caddyfile`               | Web server, TLS, static/media rules, allowed PHP entry points. |
| `config/php/php.ini`, `fpm-pool.conf`  | PHP limits, timezone, errors; FPM pool sizing.              |
| `scripts/setup.sh`                     | Sync, install, upgrade, mode, environment.                  |
| `scripts/db.php`                       | Install detection and the stack's markers.                  |
| `scripts/cron.sh`, `scripts/backup.sh` | Cron; backups and restore.                                  |

Notes:

- The Caddyfile is translated from Magento's `nginx.conf.sample`: web root
  `pub/`, only Magento's entry points run PHP (`index`, `get`, `static`,
  `health_check`, `errors/*`), versioned static URLs, missing static files
  through `static.php` and missing media through `get.php`, private media and
  the web setup blocked.
- Caddy's healthcheck uses the home page: Magento 2.4.9's `health_check.php`
  reports the installer's own cache configuration as invalid (500).
- Only `en_US` is installed; other languages need language packs, added to the
  image with `MAGEOS_LOCALES`.
- Mage-OS has no Adobe IMS modules.
- Customizing the image: the `sockets` extension (needed by `php-amqplib`)
  needs `linux-headers` to build.
- From inside the containers, the host machine is reachable as
  `host.docker.internal`.

Security
--------

- Client IP headers: PHP gets only the real client IP (as Caddy sees it) in
  `REMOTE_ADDR`, `X-Forwarded-For` and `X-Real-IP`, and no `Client-Ip`,
  `Cf-Connecting-Ip` or `X-Forwarded-Port` (a client could forge them): Magento stores
  `X-Forwarded-For` with each order and reads `Client-Ip`/`X-Forwarded-For` in
  places.
- No default secrets: compose fails if the required passwords are missing. The
  development template uses public passwords; never use it on a server.
- PHP errors are never shown to visitors (`display_errors` off unless
  `PHP_DISPLAY_ERRORS=On`, only in the development template).
- Production mode, compiled code from the image, two-factor authentication for
  the admin, custom admin path, only Magento's PHP entry points executable,
  private media and the web setup blocked, PHP version not exposed, security
  headers.
- PHP gets the real client IP in `REMOTE_ADDR` (logs, login protection) also
  behind Traefik or another proxy on a private network.
- Only Caddy (and Mailpit in development) publishes ports; the database and
  OpenSearch are internal (OpenSearch without its security plugin, so never
  publish it). `HTTP_BIND` defaults to `127.0.0.1`.
- Not included: a web application firewall, login rate limiting, Varnish, or
  off-site backup copies.

Validation
----------

What was checked for this stack (2026-09-24, Docker Desktop with 8 GB):

- Clean start (`down -v` + `up -d`, image already built) in about 70 s: every
  service `healthy`, `setup` `Exited (0)`, no kernel OOM kills; a second run
  makes no changes.
- Storefront, admin, catalog search (OpenSearch) `200`; versioned static files;
  web setup, `env.php`, private media, other PHP files `403`; CLP, Chile,
  `America/Santiago`.
- Admin login and dashboard with all static files (`MageOS/m137-admin-theme`);
  admin REST token (development); a customer created through the REST API →
  welcome email delivered to Mailpit; cron jobs run.
- A setting changed in the admin survives `setup`; changing `MAGE_URL` updates
  the base URLs (and back).
- Upgrade: 3.4.0 installed, then `MAGEOS_VERSION=3.5.0` → code synced,
  `setup:upgrade`, data kept. A rebuild of the same version (new build id)
  also reaches an existing install.
- Backup, retention and restore (including the encryption key in `env.php`).
- Production image: HTTPS with `SITE_ADDRESS=localhost` (HTTP/2, all links
  HTTPS), production mode, 2FA enforced.
- Overrides: Traefik v3.6 routing with no host ports, local directories
  (including backups), a module mounted in developer mode, its static file
  generated on demand and a live edit picked up.
- Not tested: issuing a real Let's Encrypt certificate (needs a public domain),
  the 2FA setup flow in the browser.

Resource usage
--------------

Idle, after a few requests: OpenSearch ~960 MiB, MariaDB ~200 MiB, PHP-FPM
~150 MiB, Caddy ~16 MiB, cron ~2 MiB between runs (about 1.4 GiB in total).

License
-------

[MIT](LICENSE).

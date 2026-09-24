#!/bin/sh
# Runs Magento's cron (bin/magento cron:run: indexers, emails, queue
# consumers, cleanups...) every CRON_INTERVAL seconds.
set -u

HEARTBEAT=/tmp/cron-heartbeat
CODE=/var/www/magento

case "${1:-run}" in
    health)
        # Healthy if the loop completed a pass within 3 intervals.
        [ -n "$(find "${HEARTBEAT}" -mmin -"$(( (CRON_INTERVAL * 3 + 59) / 60 ))" 2>/dev/null)" ]
        exit
        ;;
esac

echo "==> Running Magento cron every ${CRON_INTERVAL}s"
while :; do
    if [ -f "${CODE}/app/etc/env.php" ]; then
        php -d memory_limit="${PHP_CLI_MEMORY_LIMIT}" "${CODE}/bin/magento" cron:run > /tmp/cron-last.log 2>&1 \
            || { echo "Cron failed:" >&2; tail -5 /tmp/cron-last.log >&2; }
    fi
    touch "${HEARTBEAT}"
    sleep "${CRON_INTERVAL}"
done

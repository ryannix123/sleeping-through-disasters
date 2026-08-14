#!/usr/bin/env bash
# Entrypoint for Odoo on OpenShift — Sleeping Through Disasters build.
#
# Forked from ryannix123/odoo-on-openshift. Behaviour that is unchanged:
#   - tolerates the arbitrary UID OpenShift assigns under the restricted SCC
#   - renders /etc/odoo/odoo.conf from environment variables
#   - waits for PostgreSQL, initialises the database on first boot only
#
# Added for multi-cluster DR:
#   1. Standby guard. If PostgreSQL is still in recovery (a CloudNativePG
#      replica that has not been promoted yet), the container waits rather
#      than trying to initialise or write. This matters during failover,
#      when Odoo can be scheduled before promotion has finished.
#   2. ATTACHMENT_LOCATION. Setting this to "db" stores attachments in
#      PostgreSQL instead of the filestore, so attachments ride the same
#      replication stream as the rest of the data. That closes the window
#      where the database references files VolSync has not yet copied.
#      See docs/ARCHITECTURE.md.
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Arbitrary UID handling.
# OpenShift runs the container as a random UID with no /etc/passwd entry.
# Several Python libraries (and Odoo's session code) call getpwuid() and fail
# with "cannot find name for user id".
# ---------------------------------------------------------------------------
if ! whoami &>/dev/null; then
    if [ -w /etc/passwd ]; then
        echo "odoo:x:$(id -u):0:Odoo user:/var/lib/odoo:/sbin/nologin" >> /etc/passwd
    else
        export NSS_WRAPPER_PASSWD=/tmp/passwd
        export NSS_WRAPPER_GROUP=/etc/group
        cp /etc/passwd /tmp/passwd 2>/dev/null || touch /tmp/passwd
        echo "odoo:x:$(id -u):0:Odoo user:/var/lib/odoo:/sbin/nologin" >> /tmp/passwd
    fi
fi

export HOME=/var/lib/odoo

# ---------------------------------------------------------------------------
# 2. Configuration.
# ---------------------------------------------------------------------------
DB_HOST="${DB_HOST:-odoo-db-rw}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-odoo}"
DB_PASSWORD="${DB_PASSWORD:-odoo}"
DB_NAME="${DB_NAME:-odoo}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"           # Odoo "master" password
WITHOUT_DEMO="${WITHOUT_DEMO:-all}"
WORKERS="${WORKERS:-0}"
LIST_DB="${LIST_DB:-False}"

# DR-specific.
#   file (default) — attachments on the filestore PVC, replicated by VolSync
#   db             — attachments inside PostgreSQL, replicated with the data
ATTACHMENT_LOCATION="${ATTACHMENT_LOCATION:-file}"
# How long to wait for a standby to be promoted before giving up (seconds).
STANDBY_WAIT="${STANDBY_WAIT:-600}"

CONF=/etc/odoo/odoo.conf
cat > "${CONF}" <<EOF
[options]
admin_passwd = ${ADMIN_PASSWORD}
db_host = ${DB_HOST}
db_port = ${DB_PORT}
db_user = ${DB_USER}
db_password = ${DB_PASSWORD}
db_name = ${DB_NAME}
dbfilter = ^${DB_NAME}\$
data_dir = /var/lib/odoo
addons_path = /opt/odoo/src/addons,/opt/odoo/src/odoo/addons,/mnt/extra-addons
list_db = ${LIST_DB}
proxy_mode = True
workers = ${WORKERS}
without_demo = ${WITHOUT_DEMO}
log_level = info
EOF

echo ">> Rendered ${CONF}:"
grep -v -E 'password|passwd' "${CONF}" | sed 's/^/   /'

export PGPASSWORD="${DB_PASSWORD}"
psql_q() {
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -tAc "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 3. Wait for PostgreSQL to accept connections.
# ---------------------------------------------------------------------------
echo ">> Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT} ..."
for i in $(seq 1 60); do
    if pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -q; then
        echo ">> PostgreSQL is accepting connections."
        break
    fi
    if [ "${i}" -eq 60 ]; then
        echo "!! PostgreSQL not ready after 120s, exiting." >&2
        exit 1
    fi
    sleep 2
done

# ---------------------------------------------------------------------------
# 4. Standby guard (DR).
# A CloudNativePG replica cluster answers connections but is read-only. Odoo
# cannot run against it, and must never try to initialise it. Wait for the
# promotion to land instead of failing in a confusing way.
# ---------------------------------------------------------------------------
in_recovery() { [ "$(psql_q 'SELECT pg_is_in_recovery();')" = "t" ]; }

if in_recovery; then
    echo ">> PostgreSQL is a read-only standby — this cluster has not been promoted."
    echo ">> Waiting up to ${STANDBY_WAIT}s for promotion before starting Odoo."
    waited=0
    while in_recovery; do
        if [ "${waited}" -ge "${STANDBY_WAIT}" ]; then
            echo "!! Still a standby after ${STANDBY_WAIT}s. Refusing to start." >&2
            echo "!! Promote the CloudNativePG cluster first:" >&2
            echo "!!   spec.replica.enabled: false   (see docs/FAILOVER.md)" >&2
            exit 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    echo ">> Standby promoted after ${waited}s — continuing."
fi

# ---------------------------------------------------------------------------
# 5. First-boot initialisation.
# If ir_module_module is absent the database is fresh and we install base.
# On a promoted standby the schema is already there, so this is skipped.
# ---------------------------------------------------------------------------
db_initialized() {
    psql_q "SELECT to_regclass('public.ir_module_module');" | grep -q "ir_module_module"
}

# Idempotent: keeps the attachment storage mode in sync with the environment
# on every boot, so flipping the deployment variable is enough to change it.
apply_attachment_location() {
    case "${ATTACHMENT_LOCATION}" in
        db|file) ;;
        *) echo "!! ATTACHMENT_LOCATION must be 'db' or 'file', got '${ATTACHMENT_LOCATION}' — skipping." >&2
           return 0 ;;
    esac
    echo ">> Setting ir_attachment.location = ${ATTACHMENT_LOCATION}"
    psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -q <<SQL || \
        echo "!! Could not set ir_attachment.location; set it in Settings > Technical > System Parameters."
INSERT INTO ir_config_parameter (key, value, create_date, write_date)
VALUES ('ir_attachment.location', '${ATTACHMENT_LOCATION}', now(), now())
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, write_date = now();
SQL
    if [ "${ATTACHMENT_LOCATION}" = "db" ]; then
        echo ">> Attachments will be stored in PostgreSQL. Existing filestore"
        echo "   files are migrated lazily by Odoo as records are touched; run"
        echo "   the storage migration from the UI to move them all at once."
    fi
}

if [ "${1:-odoo}" = "odoo" ]; then
    if db_initialized; then
        echo ">> Existing Odoo database detected — skipping initialisation."
    else
        echo ">> Fresh database — initialising base modules (demo data: ${WITHOUT_DEMO})."
        odoo -c "${CONF}" -d "${DB_NAME}" -i base \
            --without-demo="${WITHOUT_DEMO}" --stop-after-init

        ADMIN_LOGIN_PASSWORD="${ADMIN_LOGIN_PASSWORD:-admin}"
        echo ">> Setting admin login password."
        echo "admin_user = env['res.users'].browse(2); admin_user.login = 'admin'; admin_user.password = '${ADMIN_LOGIN_PASSWORD}'; env.cr.commit()" \
            | odoo shell -c "${CONF}" -d "${DB_NAME}" --no-http 2>/dev/null || \
            echo "!! Could not auto-set admin password; use the master password to set it via the UI."
        echo ">> Initialisation complete."
    fi

    apply_attachment_location

    echo ">> Starting Odoo."
    exec odoo -c "${CONF}"
fi

# Passthrough for any other command (e.g. `oc rsh` debugging).
exec "$@"

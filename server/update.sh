#!/bin/bash

set -euo pipefail

REPO="aspanta/keyport"
BRANCH="main"

ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

INSTALL_DIR="/opt/keyport"
APP_DIR="${INSTALL_DIR}/app"
BIN_DIR="${INSTALL_DIR}/bin"
CONFIG_FILE="${INSTALL_DIR}/keyport.conf"
UPDATE_FILE="${INSTALL_DIR}/update.sh"

SERVICE="keyport.service"
HEALTH_URL="http://127.0.0.1:8000/health"

die() {
    echo "keyport update: $*" >&2
    exit 1
}

info() {
    echo "keyport update: $*"
}

cleanup() {
    if [[ -n "${TMPDIR_KEYPORT:-}" && -d "${TMPDIR_KEYPORT}" ]]; then
        rm -rf "${TMPDIR_KEYPORT}"
    fi
}

trap cleanup EXIT

#
# Preconditions
#

if [[ "${EUID}" -ne 0 ]]; then
    die "must be run as root"
fi

for command in curl tar python3 sha256sum systemctl mariadb; do
    command -v "${command}" >/dev/null 2>&1 \
        || die "required command not found: ${command}"
done

[[ -d "${INSTALL_DIR}" ]] \
    || die "Keyport is not installed in ${INSTALL_DIR}"

[[ -d "${APP_DIR}" ]] \
    || die "application directory not found: ${APP_DIR}"

[[ -d "${BIN_DIR}" ]] \
    || die "binary directory not found: ${BIN_DIR}"

[[ -r "${CONFIG_FILE}" ]] \
    || die "configuration not readable: ${CONFIG_FILE}"

systemctl cat "${SERVICE}" >/dev/null 2>&1 \
    || die "systemd service not found: ${SERVICE}"

#
# Read database configuration.
#

read_config_value() {
    local name="$1"
    local line

    line="$(grep -m1 "^${name}=" "${CONFIG_FILE}")" \
        || return 1

    printf '%s' "${line#*=}"
}

DB_SOCKET="$(read_config_value DB_SOCKET)" \
    || die "DB_SOCKET is missing from ${CONFIG_FILE}"

DB_NAME="$(read_config_value DB_NAME)" \
    || die "DB_NAME is missing from ${CONFIG_FILE}"

DB_USER="$(read_config_value DB_USER)" \
    || die "DB_USER is missing from ${CONFIG_FILE}"

DB_PASSWORD="$(read_config_value DB_PASSWORD)" \
    || die "DB_PASSWORD is missing from ${CONFIG_FILE}"

[[ "${DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] \
    || die "DB_NAME contains unsupported characters"

#
# Temporary workspace.
#

TMPDIR_KEYPORT="$(mktemp -d)"

ARCHIVE="${TMPDIR_KEYPORT}/keyport.tar.gz"
SOURCE_DIR="${TMPDIR_KEYPORT}/source"

mkdir -p "${SOURCE_DIR}"

#
# Download current main snapshot.
#

info "downloading ${REPO} ${BRANCH}"

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --output "${ARCHIVE}" \
    "${ARCHIVE_URL}" \
    || die "failed to download repository archive"

tar \
    --extract \
    --gzip \
    --file "${ARCHIVE}" \
    --directory "${SOURCE_DIR}" \
    --strip-components=1 \
    || die "failed to extract repository archive"

SERVER_SOURCE="${SOURCE_DIR}/server"
APP_SOURCE="${SERVER_SOURCE}/app"
BIN_SOURCE="${SERVER_SOURCE}/bin"
MIGRATIONS_SOURCE="${SERVER_SOURCE}/sql/migrations"
UPDATE_SOURCE="${SERVER_SOURCE}/update.sh"

[[ -d "${APP_SOURCE}" ]] \
    || die "downloaded repository does not contain server/app"

[[ -d "${BIN_SOURCE}" ]] \
    || die "downloaded repository does not contain server/bin"

[[ -f "${UPDATE_SOURCE}" ]] \
    || die "downloaded repository does not contain server/update.sh"

#
# Validate downloaded code.
#

info "validating downloaded files"

while IFS= read -r -d '' file; do
    python3 -m py_compile "${file}" \
        || die "Python validation failed: ${file#${SOURCE_DIR}/}"
done < <(
    find "${APP_SOURCE}" "${BIN_SOURCE}" \
        -type f \
        -name '*.py' \
        -print0
)

if [[ -f "${APP_SOURCE}/app.py" ]]; then
    python3 -m py_compile "${APP_SOURCE}/app.py" \
        || die "application validation failed"
fi

if [[ -f "${BIN_SOURCE}/keyport" ]]; then
    python3 -m py_compile "${BIN_SOURCE}/keyport" \
        || die "administration CLI validation failed"
fi

bash -n "${UPDATE_SOURCE}" \
    || die "update script validation failed"

#
# Prepare MariaDB client configuration.
#
# The password is kept out of process arguments.
#

MYSQL_CNF="${TMPDIR_KEYPORT}/mysql.cnf"

cat > "${MYSQL_CNF}" <<MYSQL_EOF
[client]
user=${DB_USER}
password=${DB_PASSWORD}
socket=${DB_SOCKET}
database=${DB_NAME}
MYSQL_EOF

chmod 0600 "${MYSQL_CNF}"

mysql_exec() {
    mariadb \
        --defaults-extra-file="${MYSQL_CNF}" \
        --batch \
        --skip-column-names \
        "$@"
}

#
# Verify database connectivity before changing anything.
#

info "checking database connection"

mysql_exec --execute="SELECT 1;" >/dev/null \
    || die "cannot connect to Keyport database"

#
# Bootstrap migration tracking.
#

info "checking migration infrastructure"

mysql_exec <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     VARCHAR(255) NOT NULL,
    checksum    CHAR(64) NOT NULL,
    applied_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (version)
) ENGINE=InnoDB
  DEFAULT CHARSET=ascii
  COLLATE=ascii_bin;
SQL

#
# Validate migrations and build the pending migration list.
#

PENDING_FILE="${TMPDIR_KEYPORT}/pending-migrations"
: > "${PENDING_FILE}"

if [[ -d "${MIGRATIONS_SOURCE}" ]]; then
    while IFS= read -r migration; do
        filename="$(basename "${migration}")"

        if [[ ! "${filename}" =~ ^[0-9]{3}-[a-z0-9][a-z0-9-]*\.sql$ ]]; then
            die "invalid migration filename: ${filename}"
        fi

        checksum="$(sha256sum "${migration}" | awk '{print $1}')"

        version_hex="$(
            printf '%s' "${filename}" |
            od -An -tx1 |
            tr -d ' \n'
        )"

        stored_checksum="$(
            mysql_exec \
                --execute="
                    SELECT checksum
                    FROM schema_migrations
                    WHERE version = CONVERT(0x${version_hex} USING ascii);
                "
        )"

        if [[ -n "${stored_checksum}" ]]; then
            if [[ "${stored_checksum}" != "${checksum}" ]]; then
                die "migration checksum mismatch: ${filename}"
            fi

            continue
        fi

        printf '%s\n' "${migration}" >> "${PENDING_FILE}"

    done < <(
        find "${MIGRATIONS_SOURCE}" \
            -maxdepth 1 \
            -type f \
            -name '*.sql' \
            -print |
        LC_ALL=C sort
    )
fi

#
# Stage complete app/bin trees.
#

STAGED_APP="${TMPDIR_KEYPORT}/app"
STAGED_BIN="${TMPDIR_KEYPORT}/bin"

cp -a "${APP_SOURCE}" "${STAGED_APP}"
cp -a "${BIN_SOURCE}" "${STAGED_BIN}"

#
# Apply pending migrations.
#
# Migrations must be safe to run once and must remain compatible with
# the previously deployed application. MariaDB DDL may perform implicit
# commits, so migrations are not automatically rolled back.
#

if [[ -s "${PENDING_FILE}" ]]; then
    while IFS= read -r migration; do
        filename="$(basename "${migration}")"
        checksum="$(sha256sum "${migration}" | awk '{print $1}')"

        version_hex="$(
            printf '%s' "${filename}" |
            od -An -tx1 |
            tr -d ' \n'
        )"

        info "applying migration ${filename}"

        mysql_exec < "${migration}" \
            || die "migration failed: ${filename}"

        mysql_exec \
            --execute="
                INSERT INTO schema_migrations (version, checksum)
                VALUES (
                    CONVERT(0x${version_hex} USING ascii),
                    '${checksum}'
                );
            " \
            || die "migration applied but could not be recorded: ${filename}"

    done < "${PENDING_FILE}"
else
    info "no pending migrations"
fi

#
# Prepare new production trees on the same filesystem as the
# installed application.
#

APP_NEW="${INSTALL_DIR}/.app.new"
BIN_NEW="${INSTALL_DIR}/.bin.new"

APP_OLD="${INSTALL_DIR}/.app.old"
BIN_OLD="${INSTALL_DIR}/.bin.old"

rm -rf \
    "${APP_NEW}" \
    "${BIN_NEW}" \
    "${APP_OLD}" \
    "${BIN_OLD}"

cp -a "${STAGED_APP}" "${APP_NEW}"
cp -a "${STAGED_BIN}" "${BIN_NEW}"

#
# Apply production ownership and permissions.
#

chown -R root:keyport "${APP_NEW}" "${BIN_NEW}"

find "${APP_NEW}" \
    -type d \
    -exec chmod 0750 {} +

find "${APP_NEW}" \
    -type f \
    -exec chmod 0640 {} +

find "${BIN_NEW}" \
    -type d \
    -exec chmod 0750 {} +

find "${BIN_NEW}" \
    -type f \
    -exec chmod 0755 {} +

#
# Rollback helper.
#

rollback_application() {
    info "rolling back application files"

    systemctl stop "${SERVICE}" >/dev/null 2>&1 || true

    rm -rf "${APP_DIR}" "${BIN_DIR}"

    if [[ -d "${APP_OLD}" ]]; then
        mv "${APP_OLD}" "${APP_DIR}"
    fi

    if [[ -d "${BIN_OLD}" ]]; then
        mv "${BIN_OLD}" "${BIN_DIR}"
    fi

    if systemctl start "${SERVICE}" >/dev/null 2>&1; then
        if systemctl is-active --quiet "${SERVICE}"; then
            info "previous application restored and started"
        else
            info "WARNING: previous application restored but service is not active"
        fi
    else
        info "WARNING: previous application restored but failed to start"
    fi
}

#
# Switch app/bin trees.
#

info "deploying application"

mv "${APP_DIR}" "${APP_OLD}"
mv "${BIN_DIR}" "${BIN_OLD}"

mv "${APP_NEW}" "${APP_DIR}"
mv "${BIN_NEW}" "${BIN_DIR}"

#
# Restart new application.
#

info "restarting ${SERVICE}"

if ! systemctl restart "${SERVICE}"; then
    rollback_application
    die "update failed during service restart"
fi

if ! systemctl is-active --quiet "${SERVICE}"; then
    rollback_application
    die "updated service is not active"
fi

#
# Health check.
#

info "checking application health"

HEALTH_OK=0

for attempt in 1 2 3 4 5; do
    if curl \
        --fail \
        --silent \
        --show-error \
        --max-time 5 \
        "${HEALTH_URL}" \
        >/dev/null
    then
        HEALTH_OK=1
        break
    fi

    sleep 1
done

if [[ "${HEALTH_OK}" -ne 1 ]]; then
    rollback_application
    die "updated application failed health check"
fi

#
# New application is healthy.
# Update the updater itself only now.
#

UPDATE_NEW="${INSTALL_DIR}/.update.sh.new"

install \
    -o root \
    -g root \
    -m 0755 \
    "${UPDATE_SOURCE}" \
    "${UPDATE_NEW}"

mv -f "${UPDATE_NEW}" "${UPDATE_FILE}"

ln -sfn "${INSTALL_DIR}/bin/keyport" /usr/local/sbin/keyport
ln -sfn "${UPDATE_FILE}" /usr/local/sbin/keyport-update

#
# Deployment succeeded. Old application trees are no longer needed.
#

rm -rf "${APP_OLD}" "${BIN_OLD}"

info "update complete"

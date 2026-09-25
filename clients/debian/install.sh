#!/bin/bash

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/aspanta/keyport/main/clients/debian"

INSTALL_DIR="/opt/keyport-client"
CONFIG_FILE="${INSTALL_DIR}/keyport-client.conf"

CLIENT_URL="${BASE_URL}/keyport-client"
CONFIG_URL="${BASE_URL}/keyport-client.conf.example"
UPDATE_URL="${BASE_URL}/update.sh"

CLIENT_FILE="${INSTALL_DIR}/keyport-client"
UPDATE_FILE="${INSTALL_DIR}/update.sh"

CLIENT_LINK="/usr/local/sbin/keyport-client"
UPDATE_LINK="/usr/local/sbin/keyport-client-update"

die() {
    echo "keyport-client install: $*" >&2
    exit 1
}

info() {
    echo "keyport-client install: $*"
}

cleanup() {
    if [[ -n "${TMPDIR_KEYPORT:-}" && -d "${TMPDIR_KEYPORT}" ]]; then
        rm -rf "${TMPDIR_KEYPORT}"
    fi
}

trap cleanup EXIT

if [[ "${EUID}" -ne 0 ]]; then
    die "must be run as root"
fi

if [[ ! -r /etc/os-release ]]; then
    die "cannot determine operating system"
fi

. /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
    die "this installer supports Debian only"
fi

info "installing required packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    python3 \
    python3-cryptography

TMPDIR_KEYPORT="$(mktemp -d)"

CLIENT_SOURCE="${TMPDIR_KEYPORT}/keyport-client"
CONFIG_SOURCE="${TMPDIR_KEYPORT}/keyport-client.conf.example"
UPDATE_SOURCE="${TMPDIR_KEYPORT}/update.sh"

info "downloading Keyport client from main"

curl -fsSL "${CLIENT_URL}" -o "${CLIENT_SOURCE}" \
    || die "failed to download keyport-client"

curl -fsSL "${CONFIG_URL}" -o "${CONFIG_SOURCE}" \
    || die "failed to download keyport-client.conf.example"

curl -fsSL "${UPDATE_URL}" -o "${UPDATE_SOURCE}" \
    || die "failed to download update.sh"

info "validating downloaded files"

python3 -m py_compile "${CLIENT_SOURCE}" \
    || die "client validation failed"

bash -n "${UPDATE_SOURCE}" \
    || die "update script validation failed"

python3 - <<'PY' \
    || die "python cryptography package is not usable"
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
AESGCM.generate_key(bit_length=256)
PY

mkdir -p "${INSTALL_DIR}"
chmod 0755 "${INSTALL_DIR}"

install \
    -o root \
    -g root \
    -m 0755 \
    "${CLIENT_SOURCE}" \
    "${CLIENT_FILE}"

install \
    -o root \
    -g root \
    -m 0755 \
    "${UPDATE_SOURCE}" \
    "${UPDATE_FILE}"

if [[ ! -e "${CONFIG_FILE}" ]]; then
    info "creating initial configuration"

    install \
        -o root \
        -g root \
        -m 0644 \
        "${CONFIG_SOURCE}" \
        "${CONFIG_FILE}"

    CONFIG_CREATED=1
else
    info "preserving existing configuration"
    CONFIG_CREATED=0
fi

ln -sfn "${CLIENT_FILE}" "${CLIENT_LINK}"
ln -sfn "${UPDATE_FILE}" "${UPDATE_LINK}"

info "installation complete"

if [[ "${CONFIG_CREATED}" -eq 1 ]]; then
    echo
    echo "Configuration:"
    echo "  ${CONFIG_FILE}"
    echo
    echo "Configure KEYPORT_URL, KEYPORT_SCOPE, KEYPORT_API_KEY,"
    echo "and KEYPORT_KEK_BASE64 before using the client."
    echo
    echo "The configuration was created with mode 0644"
    echo "and is readable by all local users."
fi

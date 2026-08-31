#!/bin/bash
set -e

sudo mkdir -p /var/lib/devbox/{claude,cursor,codex,grok,gradle}
# gradle/ is pruned: Gradle fills it as this user anyway, and it holds the
# read-only host mounts, which chown would fail on.
sudo find /var/lib/devbox -path /var/lib/devbox/gradle -prune -o -exec chown "$(id -u):$(id -g)" {} +
sudo chown "$(id -u):$(id -g)" /var/lib/devbox/gradle

# Persist user configs and shell history in the devbox volume so they survive
# container recreation.
#
# The scheme for each file: the real copy lives in the volume, and ~/<file> is
# just a symlink to it. So whatever the user edits goes into the volume and is
# kept across rebuilds. On first run (empty volume) we prime the volume copy:
#
#   - If the image ships a template (e.g. .zshrc / .bashrc baked by this
#     Dockerfile), copy that template into the volume — the user starts from it.
#   - If there is no template AND the file is REQUIRED (the history files: they
#     can't exist at build time — nobody has typed anything yet), create it
#     EMPTY in the volume. This is only so the ~/<file> symlink has a real
#     target from the very first shell, so history writes land in the volume
#     immediately. (.zshrc/.bashrc always have a template, so this branch is
#     only ever hit by the history files.)
#   - If there is no template AND the file is OPTIONAL (.p10k.zsh, created later
#     by `p10k configure`), skip it — don't litter an empty stub; it gets
#     picked up automatically once it actually exists.
PERSIST_HOME=/var/lib/devbox/home
REQUIRED_CONFIGS=".bashrc .zshrc .profile .bash_history .zsh_history"
OPTIONAL_CONFIGS=".p10k.zsh"
mkdir -p "${PERSIST_HOME}"

persist_config() {
    local f="$1" optional="$2"
    local src="${HOME}/${f}" dst="${PERSIST_HOME}/${f}"
    if [ ! -e "${dst}" ]; then
        if [ -e "${src}" ] && [ ! -L "${src}" ]; then
            cp -a "${src}" "${dst}"            # image template -> volume
        elif [ "${optional}" = "optional" ]; then
            return 0                           # no template, optional -> skip
        else
            : > "${dst}"                       # no template, required -> empty
        fi
    fi
    ln -sfn "${dst}" "${src}"                  # ~/<file> -> volume copy
}

for f in ${REQUIRED_CONFIGS}; do persist_config "${f}" required; done
for f in ${OPTIONAL_CONFIGS}; do persist_config "${f}" optional; done

# Grok CLI: its binary lives inside ~/.grok (downloads/ + bin/ symlinks), so the
# whole dir is persisted in the volume. Seed it from the image default on first
# run, then symlink ~/.grok to the persisted copy (grok update stays in volume).
if [ -d "${HOME}/.grok-default" ] && [ ! -e "/var/lib/devbox/grok/config.toml" ]; then
    cp -an "${HOME}/.grok-default/." /var/lib/devbox/grok/ 2>/dev/null || true
fi
ln -sfn /var/lib/devbox/grok "${HOME}/.grok"

# gh keeps its auth token in ~/.config/gh, which is part of the container's
# writable layer — `gh auth login` would be lost on every recreation. Persist
# that dir under the volume's $HOME mirror, at gh's own native path.
mkdir -p "${PERSIST_HOME}/.config/gh" "${HOME}/.config"
ln -sfn "${PERSIST_HOME}/.config/gh" "${HOME}/.config/gh"

# Gradle writes into its own home in the volume: a home shared with the host
# corrupts its caches, the file locks don't hold across the VM boundary. Only
# the host's read-only caches-ro and gradle.properties are mounted into it.
ln -sfn "${GRADLE_USER_HOME}" "${HOME}/.gradle"

# A project's local.properties is shared with the host, so its sdk.dir holds a
# host path. Make that path resolve here too — one file then fits both sides,
# and the rest of local.properties (build flags) stays single-source.
if [ -n "${HOST_ANDROID_SDK:-}" ] && [ "${HOST_ANDROID_SDK}" != "${ANDROID_HOME}" ]; then
    sudo mkdir -p "$(dirname "${HOST_ANDROID_SDK}")"
    sudo ln -sfn "${ANDROID_HOME}" "${HOST_ANDROID_SDK}"
fi

# Merge a custom Java truststore (corp CAs) into the JDK cacerts so TLS to
# internal hosts — e.g. the Gradle artifact repository — is trusted instead of
# failing with "untrusted". The store is bind-mounted at a fixed path (compose
# defaults the source to /dev/null when unset, so a char device lands here and
# the -f guard skips it). Done here, not baked into the image: the published
# image must not carry a company's private CAs, and this way cert rotation
# needs no rebuild. keytool skips aliases that already exist, so restarts are a
# no-op; the JDK path is resolved at runtime, being architecture-specific.
JAVA_CACERTS_SRC=/etc/devbox/custom-cacerts
if [ -f "${JAVA_CACERTS_SRC}" ]; then
    jdk_cacerts="$(dirname "$(dirname "$(readlink -f "$(command -v keytool)")")")/lib/security/cacerts"
    if sudo keytool -importkeystore -noprompt \
            -srckeystore "${JAVA_CACERTS_SRC}" -srcstorepass "${HOST_JAVA_CACERTS_PASS:-changeit}" \
            -destkeystore "${jdk_cacerts}" -deststorepass changeit >/dev/null 2>&1; then
        echo "[java] merged custom CAs into the JDK truststore"
    else
        echo "[java] WARN: could not merge the custom truststore — check HOST_JAVA_CACERTS_PASS" >&2
    fi
fi

# --- VPN mode dispatch -------------------------------------------------------
NET_DIR=/usr/local/lib/devbox-net
case "${VPN_MODE:-}" in
    singbox)   "${NET_DIR}/mode-singbox.sh" ;;
    hostproxy) "${NET_DIR}/mode-hostproxy.sh" ;;
    wireguard) "${NET_DIR}/mode-wireguard.sh" ;;
    "")  echo "[vpn] FATAL: VPN_MODE is not set. Use singbox | hostproxy | wireguard." >&2; exit 1 ;;
    *)   echo "[vpn] FATAL: unknown VPN_MODE='${VPN_MODE}'. Use singbox | hostproxy | wireguard." >&2; exit 1 ;;
esac

# --- danted (SOCKS5 for the host), external interface per active mode ---------
IFACE="$(cat /run/devbox-vpn-iface 2>/dev/null || true)"
[ -n "$IFACE" ] || { echo "[vpn] FATAL: no active VPN interface recorded" >&2; exit 1; }
sed "s/__EXTERNAL_IFACE__/${IFACE}/" /etc/danted.conf.tmpl | sudo tee /etc/danted.conf >/dev/null
echo "[vpn] starting SOCKS5 (danted) on :1080 via ${IFACE}..."
sudo danted -f /etc/danted.conf -D || echo "[vpn] danted failed to start"

exec "$@"

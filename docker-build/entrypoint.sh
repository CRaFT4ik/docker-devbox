#!/bin/bash
set -e

sudo mkdir -p /var/lib/devbox/{claude,cursor,codex,grok}
sudo chown -R "$(id -u):$(id -g)" /var/lib/devbox

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

while IFS= read -r cfg; do
    [ -z "${cfg}" ] && continue
    iface="$(basename "${cfg}" .conf)"
    echo "[entrypoint] bringing up WireGuard interface ${iface}..."
    sudo wg-quick up "${iface}" || echo "[entrypoint] wg-quick up ${iface} failed"
done < <(sudo find /etc/wireguard -maxdepth 1 -type f -name '*.conf' 2>/dev/null)

if [ -f /etc/danted.conf ]; then
    echo "[entrypoint] starting SOCKS5 (danted) on :1080..."
    sudo danted -f /etc/danted.conf -D || echo "[entrypoint] danted failed to start"
fi

exec "$@"

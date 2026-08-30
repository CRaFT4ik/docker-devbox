FROM ubuntu:24.04

LABEL maintainer="Eldar T. <eldar.tim@gmail.com>"
LABEL description="devbox — AI coding sandbox (claude, codex, cursor, grok)"

ARG DEV_USER
ARG DEV_UID=1000
ARG DEV_GID=${DEV_UID}

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Europe/Moscow \
    LANG=en_US.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        wireguard-tools iproute2 iptables dante-server \
        curl wget iputils-ping dnsutils net-tools traceroute mtr-tiny \
        tcpdump nmap netcat-openbsd socat jq openssh-client rsync \
        git vim nano less sudo ca-certificates gnupg \
        build-essential pkg-config \
        python3 python3-pip python3-venv \
        zsh bash-completion unzip zip file tree htop procps \
        locales tzdata \
        openjdk-17-jdk-headless \
        gh \
    && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
    && ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime \
    && echo "Europe/Moscow" > /etc/timezone \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN npm install -g --omit=dev \
        @anthropic-ai/claude-code \
        @openai/codex

# sing-box (pinned) — TUN engine for the singbox/hostproxy VPN modes.
ARG SINGBOX_VERSION=1.13.14
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sha="f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697";; \
      arm64) sha="4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e";; \
      *) echo "unsupported arch: $arch" >&2; exit 1;; \
    esac; \
    url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/sb.tgz; \
    echo "${sha}  /tmp/sb.tgz" | sha256sum -c -; \
    tar -xzf /tmp/sb.tgz -C /tmp; \
    install -m 0755 "/tmp/sing-box-${SINGBOX_VERSION}-linux-${arch}/sing-box" /usr/local/bin/sing-box; \
    rm -rf /tmp/sb.tgz "/tmp/sing-box-${SINGBOX_VERSION}-linux-${arch}"; \
    /usr/local/bin/sing-box version

RUN if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu 2>/dev/null || true; fi \
    && if getent group "${DEV_GID}" >/dev/null; then groupmod -n "${DEV_USER}" "$(getent group ${DEV_GID} | cut -d: -f1)"; else groupadd -g "${DEV_GID}" "${DEV_USER}"; fi \
    && useradd -m -u "${DEV_UID}" -g "${DEV_GID}" -s /bin/bash "${DEV_USER}" \
    && usermod -aG sudo "${DEV_USER}" \
    && echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEV_USER}" \
    && chmod 440 "/etc/sudoers.d/${DEV_USER}" \
    && mkdir -p "/home/${DEV_USER}/Android/Sdk" "/home/${DEV_USER}/mnt/.work" /var/lib/devbox \
    && for d in claude cursor codex; do \
         ln -sfn "/var/lib/devbox/${d}" "/home/${DEV_USER}/.${d}"; \
       done \
    && chown -R "${DEV_USER}:${DEV_USER}" "/home/${DEV_USER}" /var/lib/devbox \
    && chown -h "${DEV_USER}:${DEV_USER}" /home/${DEV_USER}/.claude /home/${DEV_USER}/.cursor /home/${DEV_USER}/.codex

ENV CLAUDE_CONFIG_DIR=/home/${DEV_USER}/.claude

# Gradle writes to its own home in the volume and reads deps from the host's
# read-only cache mounted next to it. Set here, not in compose: `docker exec`
# inherits the image ENV, not what entrypoint.sh exports.
ENV GRADLE_USER_HOME=/var/lib/devbox/gradle \
    GRADLE_RO_DEP_CACHE=/var/lib/devbox/gradle/caches-ro \
    GRADLE_OPTS=-Dorg.gradle.vfs.watch=false

ENV HOME=/home/${DEV_USER} \
    ANDROID_HOME=/home/${DEV_USER}/Android/Sdk \
    ANDROID_SDK_ROOT=/home/${DEV_USER}/Android/Sdk \
    PATH=/home/${DEV_USER}/.local/bin:/home/${DEV_USER}/.grok/bin:/home/${DEV_USER}/Android/Sdk/platform-tools:/home/${DEV_USER}/Android/Sdk/cmdline-tools/latest/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER ${DEV_USER}
WORKDIR /home/${DEV_USER}

RUN curl -fsS https://cursor.com/install | bash \
    && ln -s "/home/${DEV_USER}/.local/bin/cursor-agent" "/home/${DEV_USER}/.local/bin/cursor"

# Official xAI Grok CLI. Its binary lives inside ~/.grok/downloads (with
# symlinks in ~/.grok/bin), so the whole ~/.grok is persisted in the devbox
# volume like .claude/.cursor/.codex. Install into a default dir baked in the
# image; entrypoint seeds the volume from it on first run and symlinks ~/.grok.
RUN curl -fsSL https://x.ai/cli/install.sh | bash \
    && mv "/home/${DEV_USER}/.grok" "/home/${DEV_USER}/.grok-default"

# Zsh: oh-my-zsh + Powerlevel10k theme + plugins (autosuggestions, syntax
# highlighting). Everything is cloned straight from github.com (the OMZ
# install.sh is fetched from raw.githubusercontent.com, which is unreliable in
# some regions and fails SILENTLY inside `sh -c "$(curl ...)"` — a failed curl
# yields an empty script that exits 0, leaving OMZ core uninstalled).
RUN ZSH_CUSTOM="/home/${DEV_USER}/.oh-my-zsh/custom" \
    && git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git \
        "/home/${DEV_USER}/.oh-my-zsh" \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
        "${ZSH_CUSTOM}/plugins/zsh-autosuggestions" \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
        "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting" \
    && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
        "${ZSH_CUSTOM}/themes/powerlevel10k" \
    && "${ZSH_CUSTOM}/themes/powerlevel10k/gitstatus/install" -f \
    && cat >> "/home/${DEV_USER}/.zshrc" <<'ZSHRC'

# --- devbox defaults ---
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-syntax-highlighting zsh-autosuggestions)

# history
HISTFILE="$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
setopt SHARE_HISTORY INC_APPEND_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE

source "$ZSH/oh-my-zsh.sh"

# history-based autosuggestions
ZSH_AUTOSUGGEST_STRATEGY=(history)

# Powerlevel10k config (.p10k.zsh) is shipped in the image; ascii mode, no Nerd Font.
[[ -f "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"

# agents (bypass approvals — safe here: this container is the isolated sandbox)
alias claude='claude --dangerously-skip-permissions'
alias codex='codex --dangerously-bypass-approvals-and-sandbox'
alias cursor='cursor --yolo'
alias grok='grok --permission-mode bypassPermissions'

# colors (GNU coreutils; the BSD LSCOLORS/ls -G form does not apply here)
export CLICOLOR=1
eval "$(dircolors -b 2>/dev/null)"
alias ls='ls --color=auto'
alias grep='grep --color=auto'

# welcome banner (interactive shells only)
[[ -o interactive && -r /etc/devbox-motd.sh ]] && /etc/devbox-motd.sh
ZSHRC

# Powerlevel10k config (ascii mode, no Nerd Font). Shipped as the image
# default; entrypoint seeds it into the volume so the user can tweak it.
COPY --chown=${DEV_USER}:${DEV_USER} .p10k.zsh /home/${DEV_USER}/.p10k.zsh

COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=root:root resolvconf-shim.sh /usr/local/sbin/resolvconf
COPY --chown=root:root danted.conf.tmpl /etc/danted.conf.tmpl
COPY --chown=root:root net/ /usr/local/lib/devbox-net/
COPY --chown=root:root devbox-motd.sh /etc/devbox-motd.sh
USER root
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/sbin/resolvconf /etc/devbox-motd.sh \
        /usr/local/lib/devbox-net/*.sh \
    && chmod 644 /etc/danted.conf.tmpl /usr/local/lib/devbox-net/singbox-base.json
USER ${DEV_USER}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["tail", "-f", "/dev/null"]

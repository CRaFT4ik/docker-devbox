#!/bin/bash
# Welcome banner for the devbox AI dev container. Shown on interactive login.
# Lists the AI coding agents baked into the image so users orient quickly.
#
# Author: Eldar T. <eldar.tim@gmail.com>

c_reset=$'\e[0m'; c_dim=$'\e[2m'; c_b=$'\e[1m'
c_cyan=$'\e[36m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_mag=$'\e[35m'

printf '%s\n' "${c_cyan}${c_b}╔══════════════════════════════════════════════════════════╗${c_reset}"
printf '%s\n' "${c_cyan}${c_b}║  devbox — AI coding sandbox                              ║${c_reset}"
printf '%s\n' "${c_cyan}${c_b}╚══════════════════════════════════════════════════════════╝${c_reset}"
printf '\n%s\n' "${c_b}Available AI agents:${c_reset}"
printf '  %sclaude%s      Claude Code            %s(skip-permissions alias)%s\n' "$c_grn" "$c_reset" "$c_dim" "$c_reset"
printf '  %scodex%s       OpenAI Codex CLI\n' "$c_grn" "$c_reset"
printf '  %scursor%s      Cursor agent           %s(a.k.a. cursor-agent)%s\n' "$c_grn" "$c_reset" "$c_dim" "$c_reset"
printf '  %sgrok%s        xAI Grok CLI           %s(run: grok login)%s\n' "$c_grn" "$c_reset" "$c_dim" "$c_reset"
printf '\n%sWork dir:%s %s~/mnt/.work%s   %sShell:%s zsh (history suggestions on)\n' \
    "$c_yel" "$c_reset" "$c_mag" "$c_reset" "$c_yel" "$c_reset"

# unobtrusive one-line system info
cpus=$(nproc 2>/dev/null || echo '?')
mem=$(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}')
read -r disk_used disk_size disk_pct < <(df -h "$HOME/mnt/.work" 2>/dev/null | awk 'NR==2{print $3, $2, $5}')
arch=$(uname -m 2>/dev/null)
printf '%s\n\n' "${c_dim}sys: ${cpus} cpu · ram ${mem} · ${arch} · disk ${disk_used}/${disk_size} (${disk_pct})${c_reset}"

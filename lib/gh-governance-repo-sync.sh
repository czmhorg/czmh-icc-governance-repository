#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Cílená distribuce nastavení obsahu a webhooku rep jednoho projektu –
# jádro workflow repo-sync (defs/defs-governance-repo.md, repo-sync issue;
# do 2026-09-24 codeowners-sync): nad nearchivovanými spravovanými repy
# zadaných projektů provede tutéž správu CODEOWNERS (lib/gh-governance-codeowners.sh)
# a webhooku (lib/gh-governance-webhooks.sh) jako denní reconcile a nic
# jiného. Spouští governance issue (jeden projekt) nebo push do
# conf.d/projects/** (projekty z cest změněných souborů).
# Závislosti: gh-common-defs.sh (_require_vars, topic migrace),
# lib/gh-governance-report.sh, lib/gh-governance-state.sh
# (_gh-governance-run-sha, _gh-governance-state-read),
# lib/gh-governance-reconcile.sh (_gh-governance-org-repos-list,
# _gh-governance-classify), lib/gh-governance-codeowners.sh
# (_gh-governance-reconcile-codeowners), lib/gh-governance-webhooks.sh
# (_gh-governance-reconcile-webhook).
[[ -n "${_GH_GOVERNANCE_REPO_SYNC_LOADED:-}" ]] && \
  declare -F _gh-governance-repo-sync-run >/dev/null && return 0
_GH_GOVERNANCE_REPO_SYNC_LOADED=1

_gh-governance-repo-sync-keys-from-paths() {
  # Odvodí klíče projektů z cest změněných souborů gov repa (push trigger
  # workflow repo-sync): `conf.d/projects/<key>.conf` (projekt) i
  # `conf.d/projects/<key>/<ghName>.conf` (nastavení repa) → <key>; hlubší
  # cesty a soubory bez přípony .conf se ignorují. Výstup bez duplicit,
  # setříděný LC_ALL=C. Nadmnožina nevadí (sync je idempotentní); klíč, který
  # v HEAD conf.d už neexistuje, ohlásí sync-run. Čistá funkce.
  # Použití: _gh-governance-repo-sync-keys-from-paths <cesty po řádcích> <array_ref>
  declare -n _kp_ref="$2"
  local _kp_line _kp_rest _kp_key
  local -A _kp_seen=()
  _kp_ref=()
  while IFS= read -r _kp_line; do
    [[ "$_kp_line" == conf.d/projects/* ]] || continue
    _kp_rest="${_kp_line#conf.d/projects/}"
    if [[ "$_kp_rest" == */* ]]; then
      _kp_key="${_kp_rest%%/*}"
      _kp_rest="${_kp_rest#*/}"
      [[ "$_kp_rest" == */* ]] && continue
    else
      _kp_key="${_kp_rest%.conf}"
    fi
    [[ "$_kp_rest" == *.conf && -n "$_kp_key" ]] || continue
    _kp_seen["$_kp_key"]=1
  done <<< "$1"
  [[ ${#_kp_seen[@]} -gt 0 ]] || return 0
  mapfile -t _kp_ref < <(printf '%s\n' "${!_kp_seen[@]}" | LC_ALL=C sort)
}

_gh-governance-repo-sync-run() {
  # Repo-sync zadaných projektů: nad nearchivovanými spravovanými repy
  # projektů volá _gh-governance-reconcile-codeowners
  # a _gh-governance-reconcile-webhook, každou se stejnou tolerancí selhání
  # jako reconcile-run (error `neuspesna reconciliace repa`, pokračuje).
  # Nic jiného nemění — ukazatel state/ čte jen pro heuristiku úrovně hlášení
  # a diff staré URL webhooku a neposouvá ho. Položky reportu navíc (jen
  # info): `projekt bez konfigurace` (klíč mimo conf.d HEAD), `codeowners
  # v migraci vynechano` a `webhook v migraci vynechano` (repo s topicem
  # migrace; funkce ho samy přeskočí), `projekt bez rep`. Report musí být
  # inicializován (_gh-governance-report-init). rc != 0 jen při selhání
  # infrastruktury běhu (checkout gov repa, výpis rep organizace).
  # Použití: _gh-governance-repo-sync-run <projectKey>...
  local _listing _name _archived _branch _topics _extra _class _value
  local _key _err_file _pointer _k
  local -A _wanted=() _seen=()
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX GH_PROJECT_TOPIC_PREFIX || return 1
  if [[ $# -eq 0 ]]; then
    echo "Chyba: Zadej aspoň jeden projectKey." >&2
    return 1
  fi
  _gh-governance-run-sha >/dev/null || return 1
  for _k in "$@"; do
    if [[ -z "${_GH_CONF[projects/$_k/domain]:-}" ]]; then
      _gh-governance-report-add info "projekt bez konfigurace" "$_k" \
        "projekt v conf.d (HEAD) neexistuje — vynechán"
      continue
    fi
    _wanted["$_k"]=1
  done
  [[ ${#_wanted[@]} -gt 0 ]] || return 0
  _listing=$(_gh-governance-org-repos-list) || {
    echo "Chyba: Výpis rep organizace '$GITHUB_ORG' selhal." >&2
    return 1
  }
  while IFS=$'\t' read -r _name _archived _branch _topics _extra; do
    [[ -n "$_name" ]] || continue
    IFS=$'\t' read -r _class _value <<< "$(_gh-governance-classify "$_name" "$_topics")"
    [[ "$_class" == spravovane && -n "${_wanted[$_value]:-}" ]] || continue
    [[ "$_archived" == true ]] && continue
    _key="$_value"
    _seen["$_key"]=1
    if [[ ",$_topics," == *",${_BB_MIGRATION_TOPIC_MARKER},"* ]]; then
      _gh-governance-report-add info "codeowners v migraci vynechano" \
        "${GITHUB_ORG}/${_name}" \
        "repo s topicem ${_BB_MIGRATION_TOPIC_MARKER} — CODEOWNERS se nezapisuje, dorovná se po uzavření migrace"
      _gh-governance-report-add info "webhook v migraci vynechano" \
        "${GITHUB_ORG}/${_name}" \
        "repo s topicem ${_BB_MIGRATION_TOPIC_MARKER} — webhook se nezakládá, dorovná se po uzavření migrace"
    fi
    _pointer=$(_gh-governance-state-read "$_name" 2>/dev/null) || _pointer=""
    _err_file=$(mktemp) || return 1
    if ! _gh-governance-reconcile-codeowners "$_name" "$_branch" "$_key" \
        "$_topics" "$_pointer" 2>"$_err_file"; then
      _gh-governance-report-add error "neuspesna reconciliace repa" \
        "${GITHUB_ORG}/${_name}" "správa CODEOWNERS: $(tail -n 1 "$_err_file")"
    fi
    rm -f "$_err_file"
    _err_file=$(mktemp) || return 1
    if ! _gh-governance-reconcile-webhook "$_name" "$_key" "$_topics" "$_pointer" \
        2>"$_err_file"; then
      _gh-governance-report-add error "neuspesna reconciliace repa" \
        "${GITHUB_ORG}/${_name}" "správa webhooku: $(tail -n 1 "$_err_file")"
    fi
    rm -f "$_err_file"
  done <<< "$_listing"
  while IFS= read -r _k; do
    [[ -n "$_k" && -z "${_seen[$_k]:-}" ]] || continue
    _gh-governance-report-add info "projekt bez rep" "$_k" \
      "projekt nemá žádné nearchivované spravované repo"
  done < <(printf '%s\n' "${!_wanted[@]}" | LC_ALL=C sort)
  return 0
}

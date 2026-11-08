#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Cílená distribuce nastavení obsahu, webhooku, souborů workflow a příznaků
# rep jednoho projektu – jádro workflow repo-sync (defs/defs-governance-repo.md,
# repo-sync issue; do 2026-09-24 codeowners-sync): nad nearchivovanými
# spravovanými repy zadaných projektů provede tutéž správu CODEOWNERS
# (lib/gh-governance-codeowners.sh), webhooku (lib/gh-governance-webhooks.sh),
# souborů workflow (lib/gh-governance-workflows.sh) a příznaků repa
# (lib/gh-governance-repo-flags.sh) jako denní reconcile a nic jiného.
# Spouští governance issue (jeden projekt) nebo push do conf.d/projects/**
# a conf.d/workflows/** (projekty z cest změněných souborů; změněná šablona →
# projekty, jejichž klíč workflows ji odkazuje).
# Závislosti: gh-common-defs.sh (_require_vars, topic migrace),
# lib/gh-conf.sh (_gh-conf-projects-using-workflow),
# lib/gh-governance-report.sh (_gh-governance-report-tolerate),
# lib/gh-governance-state.sh (_gh-governance-run-sha, _gh-governance-state-read),
# lib/gh-governance-reconcile.sh (_gh-governance-org-repos-list,
# _gh-governance-classify), lib/gh-governance-codeowners.sh
# (_gh-governance-reconcile-codeowners), lib/gh-governance-webhooks.sh
# (_gh-governance-reconcile-webhook), lib/gh-governance-workflows.sh
# (_gh-governance-reconcile-workflows), lib/gh-governance-repo-flags.sh
# (_gh-governance-reconcile-repo-flags).
[[ -n "${_GH_GOVERNANCE_REPO_SYNC_LOADED:-}" ]] && \
  declare -F _gh-governance-repo-sync-run >/dev/null && return 0
_GH_GOVERNANCE_REPO_SYNC_LOADED=1

_gh-governance-repo-sync-keys-from-paths() {
  # Odvodí klíče projektů z cest změněných souborů gov repa (push trigger
  # workflow repo-sync): `conf.d/projects/<key>.conf` (projekt) i
  # `conf.d/projects/<key>/<ghName>.conf` (nastavení repa) → <key>;
  # `conf.d/workflows/<název>.yml` (šablona workflow) → projekty, jejichž
  # klíč workflows (projektu nebo kteréhokoli nastavení repa v HEAD conf.d,
  # _gh-conf-projects-using-workflow) šablonu odkazuje — smazanou šablonu
  # žádný projekt neodkazuje (parser by ji odmítl) → nic, osiřelé soubory
  # uklidí noční reconcile. Hlubší cesty a jiné přípony se ignorují. Výstup
  # bez duplicit, setříděný LC_ALL=C. Nadmnožina nevadí (sync je idempotentní);
  # klíč, který v HEAD conf.d už neexistuje, ohlásí sync-run. Offline nad _GH_CONF.
  # Použití: _gh-governance-repo-sync-keys-from-paths <cesty po řádcích> <array_ref>
  declare -n _kp_ref="$2"
  local _kp_line _kp_rest _kp_key
  local -A _kp_seen=()
  local -a _kp_using=()
  _kp_ref=()
  while IFS= read -r _kp_line; do
    if [[ "$_kp_line" == conf.d/workflows/*.yml && "$_kp_line" != conf.d/workflows/*/* ]]; then
      _kp_rest="${_kp_line#conf.d/workflows/}"
      _gh-conf-projects-using-workflow "${_kp_rest%.yml}" _kp_using
      for _kp_key in "${_kp_using[@]}"; do _kp_seen["$_kp_key"]=1; done
      continue
    fi
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
  # projektů volá _gh-governance-reconcile-codeowners, -webhook, -workflows
  # a -repo-flags, každou se stejnou tolerancí selhání jako reconcile-run
  # (_gh-governance-report-tolerate: error `neuspesna reconciliace repa`,
  # pokračuje). Nic jiného nemění — ukazatel state/ čte jen pro heuristiku
  # úrovně hlášení a diff staré URL webhooku a neposouvá ho. Položky reportu
  # navíc (jen info): `projekt bez konfigurace` (klíč mimo conf.d HEAD),
  # `codeowners v migraci vynechano`, `webhook v migraci vynechano`
  # a `workflow v migraci vynechano` (repo s topicem migrace; funkce ho samy
  # přeskočí — i příznaky repa, bez vlastní položky), `projekt bez rep`.
  # Report musí být inicializován (_gh-governance-report-init). rc != 0 jen
  # při selhání infrastruktury běhu (checkout gov repa, výpis rep organizace).
  # Použití: _gh-governance-repo-sync-run <projectKey>...
  local _listing _name _archived _branch _topics _extra _class _value
  local _key _pointer _k _mig _repo_path
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
    _repo_path="${GITHUB_ORG}/${_name}"
    if _bb-migration-topic-present "$_topics" "$_BB_MIGRATION_TOPIC_MARKER"; then
      # Položky `<typ>|<co se neděje>`; detail má jednotnou stavbu.
      for _mig in \
          "codeowners v migraci vynechano|CODEOWNERS se nezapisuje" \
          "webhook v migraci vynechano|webhook se nezakládá" \
          "workflow v migraci vynechano|soubory workflow se nezapisují"; do
        _gh-governance-report-add info "${_mig%%|*}" "$_repo_path" \
          "repo s topicem ${_BB_MIGRATION_TOPIC_MARKER} — ${_mig#*|}, dorovná se po uzavření migrace"
      done
    fi
    _pointer=$(_gh-governance-state-read "$_name" 2>/dev/null) || _pointer=""
    _gh-governance-report-tolerate "$_repo_path" "správa CODEOWNERS" \
      _gh-governance-reconcile-codeowners "$_name" "$_branch" "$_key" "$_topics" "$_pointer"
    _gh-governance-report-tolerate "$_repo_path" "správa webhooku" \
      _gh-governance-reconcile-webhook "$_name" "$_key" "$_topics" "$_pointer"
    _gh-governance-report-tolerate "$_repo_path" "správa workflow" \
      _gh-governance-reconcile-workflows "$_name" "$_branch" "$_key" "$_topics" "$_pointer"
    _gh-governance-report-tolerate "$_repo_path" "správa příznaků repa" \
      _gh-governance-reconcile-repo-flags "$_name" "$_key" "$_topics" "$_pointer"
  done <<< "$_listing"
  while IFS= read -r _k; do
    [[ -n "$_k" && -z "${_seen[$_k]:-}" ]] || continue
    _gh-governance-report-add info "projekt bez rep" "$_k" \
      "projekt nemá žádné nearchivované spravované repo"
  done < <(printf '%s\n' "${!_wanted[@]}" | LC_ALL=C sort)
  return 0
}

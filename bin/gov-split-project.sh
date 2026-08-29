#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Entry skript workflow split-project (docs/implementovano/navrh/rozdeleni-projektu.md,
# fáze 2); spustitelný i lokálně nad checkoutem gov repa. Hromadný přesun
# rep podle mapy splits/*.tsv schválené PR: sekvenčně per repo (každé
# dokončit celé před dalším), fail-fast při selhání – běh je restartovatelný
# (hotová repa přeskočí, polopřesunutá dokončí). Souhrn per repo včetně
# upozornění na ruční odchylky jde do $GITHUB_STEP_SUMMARY (v Actions),
# jinak na stdout.

_gov_sp_show_help() {
  echo "Syntaxe: gov-split-project.sh --map splits/<mapa>.tsv --project <projectKey>"
  echo "Účel:    Hromadný přesun rep zdrojového projektu podle mapy"
  echo "         (řádky ghName<TAB>newProjectKey[<TAB>keep]): pro každé repo"
  echo "         tytéž kroky jako move-repository (rename, topic, politika,"
  echo "         state/, manifest, zrušení redirectu – 'keep' ho ponechá)."
  echo ""
  echo "Volby:"
  echo "  --map SOUBOR      Cesta k mapě v gov repu (jen splits/*.tsv)."
  echo "  --project KLÍČ    Zdrojový projectKey (mapované ghName mu patří)."
  echo ""
  echo "Příklad: bash governance/bin/gov-split-project.sh --map splits/2026-08-26-bbpkid.tsv --project bbpkid"
  echo ""
  echo "Práva:   admin na repech projektu (rename, topicy, politika), push do"
  echo "         gov repa (state/), issues v gov repu a delete-repository."
}

_gov_sp_map=""
_gov_sp_project=""
_gov_sp_expect=""
for _gov_sp_a in "$@"; do
  if [[ -n "$_gov_sp_expect" ]]; then
    case "$_gov_sp_expect" in
      map)     _gov_sp_map="$_gov_sp_a" ;;
      project) _gov_sp_project="$_gov_sp_a" ;;
    esac
    _gov_sp_expect=""
    continue
  fi
  case "$_gov_sp_a" in
    --help)    _gov_sp_show_help; exit 0 ;;
    --map)     _gov_sp_expect=map ;;
    --project) _gov_sp_expect=project ;;
    *) echo "Chyba: Neznámý argument '$_gov_sp_a' (viz --help)." >&2; exit 1 ;;
  esac
done
if [[ -n "$_gov_sp_expect" ]]; then
  echo "Chyba: Volba --$_gov_sp_expect vyžaduje hodnotu." >&2
  exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/gov-env.sh"

# Vstupy z workflow_dispatch přicházejí přes env – validace regexy před
# prvním použitím (žádná interpolace do run:, schéma jako issue workflows).
if ! _gh-match "$_gov_sp_map" '^splits/[A-Za-z0-9._-]+\.tsv$'; then
  echo "Chyba: --map musí být cesta splits/<název>.tsv v gov repu (je '$_gov_sp_map')." >&2
  exit 1
fi
if ! _gh-match "$_gov_sp_project" "$_GH_PROJECT_KEY_REGEX"; then
  echo "Chyba: --project '$_gov_sp_project' neodpovídá formátu projectKey (defs/defs.md)." >&2
  exit 1
fi
_gov_sp_mhn=""
_bb-require-pk "$_gov_sp_project" _gov_sp_mhn || exit 1
_gov_sp_root=$(_gh-governance-checkout-root) || exit 1
_gov_sp_map_path="$_gov_sp_root/$_gov_sp_map"
_gh-governance-split-map-check "$_gov_sp_map_path" "$_gov_sp_project" || exit 1

_gov_sp_rows=()
_gh-governance-split-map-rows "$_gov_sp_map_path" _gov_sp_rows || exit 1
_gov_sp_total=${#_gov_sp_rows[@]}
echo "Rozdělení projektu '$_gov_sp_project' dle mapy $_gov_sp_map: $_gov_sp_total rep."

_gov-sp-summary() {
  # Markdown řádek/oddíl do step summary (v Actions), jinak na stdout.
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  else
    printf '%s\n' "$@"
  fi
}

_gov-sp-summary "# split-project: $_gov_sp_project ($_gov_sp_map)" ""

_gov_sp_i=0
_gov_sp_moved=0
_gov_sp_skipped=0
for _gov_sp_row in "${_gov_sp_rows[@]}"; do
  _gov_sp_i=$(( _gov_sp_i + 1 ))
  IFS=$'\t' read -r _gov_sp_name _gov_sp_dst _gov_sp_redirect <<< "$_gov_sp_row"
  echo "[$_gov_sp_i/$_gov_sp_total] $_gov_sp_name → $_gov_sp_dst (redirect: $_gov_sp_redirect)"
  # Restart běhu: hotová repa (nové jméno + nový topic + přesunutý ukazatel)
  # se přeskakují; polopřesunutá dokončí _gh-governance-move-run.
  _gov_sp_state=""
  declare -A _gov_sp_info=()
  if ! _gh-governance-move-detect "$_gov_sp_project" "$_gov_sp_name" "$_gov_sp_dst" \
      _gov_sp_state _gov_sp_info; then
    _gov-sp-summary "## $_gov_sp_name" "" "**CHYBA**: detekce stavu selhala – běh ukončen."
    exit 1
  fi
  if [[ "$_gov_sp_state" == done \
      && ! -f "$_gov_sp_root/state/${GH_REPO_PREFIX}-${_gov_sp_project}-${_gov_sp_name}" ]]; then
    echo "  Už přesunuto – přeskakuji."
    _gov_sp_skipped=$(( _gov_sp_skipped + 1 ))
    _gov-sp-summary "## $_gov_sp_name" "" "Už přesunuto do \`$_gov_sp_dst\` – přeskočeno." ""
    continue
  fi
  declare -A _gov_sp_sum=()
  if ! _gh-governance-move-run "$_gov_sp_project" "$_gov_sp_name" "$_gov_sp_dst" \
      "$_gov_sp_redirect" _gov_sp_sum; then
    # Fail-fast: stav je restartovatelný, nový dispatch naváže.
    _gov-sp-summary "## $_gov_sp_name" "" \
      "**CHYBA**: přesun selhal (${_gov_sp_sum[error_type]:-provozní chyba}) – běh ukončen; po nápravě spusť workflow znovu."
    exit 1
  fi
  _gov_sp_moved=$(( _gov_sp_moved + 1 ))
  _gov-sp-summary "## $_gov_sp_name" "" "$(_gh-governance-move-comment _gov_sp_sum)" ""
done

_gov-sp-summary "---" "Hotovo: přesunuto $_gov_sp_moved, přeskočeno $_gov_sp_skipped z $_gov_sp_total rep."
echo "Hotovo: přesunuto $_gov_sp_moved, přeskočeno $_gov_sp_skipped z $_gov_sp_total rep."
exit 0

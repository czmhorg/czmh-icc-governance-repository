#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Labely governance issue v gov repu (defs/defs-governance-repo.md): jeden
# zdroj pravdy pro názvy a popisy labelů, podle nichž workflows vybírají
# issue (create-repo, …, reconcile-report) a s nimiž klienti issue zakládají
# (gh issue create --label). Label je součást nasazené verze kódu, ne
# bootstrapu: nové workflow = nový label, proto labely zakládá gov-sync.sh
# před pushem kódu, gov-init.sh týmž voláním (deploy je v initu volitelný)
# a denní reconcile chybějící label hlásí (warning `chybejici label gov repa`).
# Závislosti: gh-common-defs.sh (GITHUB_ORG_HOSTNAME); gh label list/create
# vyžadují write do gov repa.
[[ -n "${_GH_GOVERNANCE_LABELS_LOADED:-}" ]] && \
  declare -F _gh-governance-labels-ensure >/dev/null && return 0
_GH_GOVERNANCE_LABELS_LOADED=1

_GH_GOVERNANCE_LABEL_ORDER=(create-repo archive-repo unarchive-repo move-repo rename-repo track-delete repo-sync reconcile-report)
declare -A _GH_GOVERNANCE_LABELS=(
  [create-repo]="Požadavek na založení repozitáře (workflow new-repository)"
  [archive-repo]="Požadavek na archivaci repozitáře (workflow archive-repository)"
  [unarchive-repo]="Požadavek na zrušení archivace (workflow unarchive-repository)"
  [move-repo]="Požadavek na přesun repozitáře do jiného projektu (workflow move-repository)"
  [rename-repo]="Požadavek na přejmenování repozitáře v projektu (workflow rename-repository)"
  [track-delete]="Sledování smazání repozitáře (workflow track-delete)"
  [repo-sync]="Požadavek na distribuci CODEOWNERS a webhooku do rep projektu (workflow repo-sync)"
  [reconcile-report]="Denní reconcile report (workflow daily-reconcile)"
)

_gh-governance-labels-missing() {
  # Vypíše na stdout názvy labelů governance issue, které v repu chybí
  # (jeden na řádek, v pořadí _GH_GOVERNANCE_LABEL_ORDER). rc 1 = výpis
  # labelů selhal (repo nedostupné, chybějící právo).
  # Použití: _gh-governance-labels-missing <org/repo>
  local _repo="$1" _existing _name
  _existing=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh label list --repo "$_repo" \
    --limit 200 --json name --jq '.[].name') || return 1
  for _name in "${_GH_GOVERNANCE_LABEL_ORDER[@]}"; do
    grep -qFx -- "$_name" <<< "$_existing" || echo "$_name"
  done
}

_gh-governance-labels-ensure() {
  # Založí chybějící labely governance issue a u existujících sjednotí popis
  # (gh label create --force); idempotentní. Každý label ohlásí řádkem
  # "<prefix>label '<název>' – vytvořen | už existuje (popis sjednocen)."
  # Použití: _gh-governance-labels-ensure <org/repo> [<prefix hlášek>]
  local _repo="$1" _prefix="${2:-}" _missing _name _state
  _missing=$(_gh-governance-labels-missing "$_repo") || {
    echo "Chyba: Výpis labelů repa '$_repo' selhal." >&2
    return 1
  }
  for _name in "${_GH_GOVERNANCE_LABEL_ORDER[@]}"; do
    GH_HOST="$GITHUB_ORG_HOSTNAME" gh label create "$_name" --repo "$_repo" --force \
      --description "${_GH_GOVERNANCE_LABELS[$_name]}" >/dev/null || {
      echo "Chyba: Založení labelu '$_name' v repu '$_repo' selhalo." >&2
      return 1
    }
    _state="už existuje (popis sjednocen)"
    grep -qFx -- "$_name" <<< "$_missing" && _state="vytvořen"
    echo "${_prefix}label '$_name' – $_state."
  done
}

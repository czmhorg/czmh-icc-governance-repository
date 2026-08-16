#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Ukazatel posledního aplikovaného stavu konfigurace (defs/defs.md, návrh
# docs/navrh/governance/governance-repo.md): soubor state/<ghRepoName> v gov
# repu, obsah = jeden řádek s plným SHA commitu gov repa, jehož konfigurace
# byla na repo naposledy úspěšně aplikována. Modul pracuje nad lokálním
# checkoutem gov repa (kořen = rodič adresáře conf.d, viz _GH_COMMON_CONF_D).
# Závislosti: gh-common-defs.sh (_GH_COMMON_CONF_D, _GH_CONF, _require_vars),
# lib/gh-conf.sh (_gh-conf-parse-file), lib/gh-repository-policy.sh
# (_gh-validate-admin-team, _gh-jenkins-delete,
#  _gh-repository-policy-live-admin-removal-safe).
[[ -n "${_GH_GOVERNANCE_STATE_LOADED:-}" ]] && \
  declare -F _gh-governance-state-read >/dev/null && return 0
_GH_GOVERNANCE_STATE_LOADED=1

_GH_GOVERNANCE_SHA_REGEX='^[0-9a-f]{40}$'

_gh-governance-checkout-root() {
  # Vypíše kořen lokálního checkoutu gov repa (rodič adresáře conf.d).
  # Použití: _gh-governance-checkout-root
  local _root
  _root="$(dirname "$_GH_COMMON_CONF_D")"
  if ! git -C "$_root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Chyba: '$_root' není git checkout gov repa – ukazatel /state/ vyžaduje checkout (nastav GH_CONFD_ROOT na conf.d checkoutu gov repa)." >&2
    return 1
  fi
  printf '%s\n' "$_root"
}

_gh-governance-run-sha() {
  # Zafixuje (při prvním volání) a vypíše SHA HEAD checkoutu gov repa –
  # celý běh pracuje s jedinou verzí konfigurace (RUN_SHA).
  # Použití: _gh-governance-run-sha
  local _root _sha
  if [[ -z "${_GH_GOVERNANCE_RUN_SHA:-}" ]]; then
    _root=$(_gh-governance-checkout-root) || return 1
    _sha=$(git -C "$_root" rev-parse HEAD 2>/dev/null)
    if [[ ! "$_sha" =~ $_GH_GOVERNANCE_SHA_REGEX ]]; then
      echo "Chyba: Nepodařilo se zjistit SHA HEAD checkoutu gov repa ('$_sha')." >&2
      return 1
    fi
    _GH_GOVERNANCE_RUN_SHA="$_sha"
  fi
  printf '%s\n' "$_GH_GOVERNANCE_RUN_SHA"
}

_gh-governance-state-read() {
  # Přečte ukazatel state/<ghRepoName> z checkoutu gov repa a vypíše SHA.
  # rc: 0 = OK, 1 = ukazatel neexistuje (adopce), 2 = nevalidní obsah/chyba.
  # Použití: _gh-governance-state-read <ghRepoName>
  local _repo_name="$1" _root _file _sha=""
  _root=$(_gh-governance-checkout-root) || return 2
  _file="$_root/state/$_repo_name"
  [[ -f "$_file" ]] || return 1
  IFS= read -r _sha < "$_file" || true
  _sha="${_sha%$'\r'}"
  if [[ ! "$_sha" =~ $_GH_GOVERNANCE_SHA_REGEX ]]; then
    echo "Chyba: state/$_repo_name neobsahuje validní SHA commitu (je '$_sha')." >&2
    return 2
  fi
  printf '%s\n' "$_sha"
}

_gh-governance-state-write() {
  # Zapíše ukazatel state/<ghRepoName> do checkoutu gov repa (jen pracovní
  # kopie; commit+push provádí _gh-governance-state-push jednou na konci běhu).
  # Použití: _gh-governance-state-write <ghRepoName> <sha>
  local _repo_name="$1" _sha="$2" _root
  if [[ ! "$_sha" =~ $_GH_GOVERNANCE_SHA_REGEX ]]; then
    echo "Chyba: Ukazatel pro '$_repo_name' musí být plné SHA commitu (je '$_sha')." >&2
    return 1
  fi
  _root=$(_gh-governance-checkout-root) || return 1
  mkdir -p "$_root/state" || return 1
  printf '%s\n' "$_sha" > "$_root/state/$_repo_name"
}

_gh-governance-state-push() {
  # Commitne všechny změny pod state/ jedním commitem a pushne; při odmítnutí
  # pushe rebase-retry (max 5×). Při konfliktu vyhrává vzdálená verze (-X ours
  # při rebase) – ukazatel smí být „starší", nikdy „novější" než realita;
  # repo dokonverguje příští běh. Bez změn nedělá nic. Selhání pushe nevrací
  # už aplikované změny – volající ho reportuje jako error.
  # Použití: _gh-governance-state-push <commit message>
  local _msg="$1" _root _attempt
  _root=$(_gh-governance-checkout-root) || return 1
  [[ -d "$_root/state" ]] || return 0
  git -C "$_root" add -A state/ || return 1
  git -C "$_root" diff --cached --quiet && return 0
  git -C "$_root" commit -m "$_msg" >/dev/null || return 1
  for _attempt in 1 2 3 4 5; do
    git -C "$_root" push >/dev/null 2>&1 && return 0
    if [[ "$_attempt" == 5 ]]; then
      break
    fi
    echo "Varovani: Push ukazatelů /state/ odmítnut (pokus $_attempt/5), zkouším rebase." >&2
    git -C "$_root" pull --rebase -X ours >/dev/null 2>&1 || {
      git -C "$_root" rebase --abort >/dev/null 2>&1
      echo "Chyba: Rebase při pushi ukazatelů /state/ selhal." >&2
      return 1
    }
  done
  echo "Chyba: Push ukazatelů /state/ selhal po 5 pokusech." >&2
  return 1
}

_gh-governance-conf-teams-at-commit() {
  # Naplní nameref pole slugy týmů z klíče repository_teams projektu ve verzi
  # konfigurace daného commitu gov repa. Starou verzi čte přes `git show` a
  # parsuje reuse _gh-conf-parse-file (žádný druhý parser); data ukládá do
  # _GH_CONF pod izolovaný namespace "at-<sha>". Soubor v dané verzi nemusí
  # existovat → prázdný seznam (rc 0).
  # rc: 0 = OK, 1 = chyba (git/parsování) – volající nesmí nic odebírat.
  # Použití: local -a _t=(); _gh-governance-conf-teams-at-commit <sha> <projectKey> _t
  local _sha="$1" _key="$2" _root _content _tmp _k _rest _item
  declare -n _teams_ref="$3"
  local -a _errs=()
  _teams_ref=()
  _root=$(_gh-governance-checkout-root) || return 1
  _content=$(git -C "$_root" show "$_sha:conf.d/projects/$_key.conf" 2>/dev/null) || return 0
  _tmp=$(mktemp) || return 1
  printf '%s\n' "$_content" > "$_tmp"
  for _k in "${!_GH_CONF[@]}"; do
    [[ "$_k" == "at-$_sha/$_key/"* ]] && unset "_GH_CONF[$_k]"
  done
  _gh-conf-parse-file "$_tmp" "projects/$_key.conf@$_sha" "at-$_sha" "$_key" _errs
  rm -f "$_tmp"
  if [[ ${#_errs[@]} -gt 0 ]]; then
    printf '%s\n' "${_errs[@]}" >&2
    echo "Chyba: Konfiguraci projects/$_key.conf ve verzi $_sha nelze naparsovat." >&2
    return 1
  fi
  _rest="${_GH_CONF[at-$_sha/$_key/repository_teams]:-},"
  while [[ "$_rest" == *,* ]]; do
    _item="${_rest%%,*}"
    _rest="${_rest#*,}"
    [[ -n "$_item" ]] && _teams_ref+=("${_item%%|*}")
  done
  return 0
}

_gh-governance-teams-to-remove() {
  # Naplní nameref pole týmy k odebrání: {týmy v repository_teams na SHA
  # ukazatele} − {týmy na RUN_SHA}. Pojistka: tým z aktuálně načteného
  # repository_teams (_GH_CONF) se do seznamu nikdy nedostane.
  # Použití: local -a _rm=(); _gh-governance-teams-to-remove <projectKey> <pointer_sha> <run_sha> _rm
  local _key="$1" _old_sha="$2" _new_sha="$3" _team _new_csv _current
  declare -n _rm_ref="$4"
  local -a _old_teams=() _new_teams=()
  _rm_ref=()
  _gh-governance-conf-teams-at-commit "$_old_sha" "$_key" _old_teams || return 1
  _gh-governance-conf-teams-at-commit "$_new_sha" "$_key" _new_teams || return 1
  _new_csv=",$(IFS=,; echo "${_new_teams[*]-}"),"
  _current=",${_GH_CONF[projects/$_key/repository_teams]:-},"
  for _team in "${_old_teams[@]}"; do
    [[ "$_new_csv" == *",$_team,"* ]] && continue
    [[ "$_current" == *",$_team|"* ]] && continue
    _rm_ref+=("$_team")
  done
  return 0
}

_gh-governance-teams-remove() {
  # Odebere z repa týmy z nameref pole (volat až po úspěšném kompletním
  # assignu politiky). Pojistky: tým z aktuálního repository_teams se nikdy
  # neodebírá; před odebráním týmu s živým admin právem ověří, že na repu
  # zůstává jiný admin tým; DELETE 404-tolerantně. Odebrané týmy vypisuje
  # po řádcích na stdout (podklad pro report).
  # Použití: _gh-governance-teams-remove <repo_path> <projectKey> <teams_array_name>
  local _repo_path="$1" _key="$2" _team _permission _observed _current
  declare -n _rm_teams_ref="$3"
  local -A _live=()
  [[ ${#_rm_teams_ref[@]} -gt 0 ]] || return 0
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME || return 1
  _observed=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/teams" \
    --paginate --jq '.[] | [.slug, .permission] | @tsv') || return 1
  while IFS=$'\t' read -r _team _permission; do
    [[ -n "$_team" ]] && _live["$_team"]="$_permission"
  done <<< "$_observed"
  _current=",${_GH_CONF[projects/$_key/repository_teams]:-},"
  for _team in "${_rm_teams_ref[@]}"; do
    [[ "$_current" == *",$_team|"* ]] && continue
    [[ -v _live["$_team"] ]] || continue
    if [[ "${_live[$_team]}" == admin ]]; then
      if ! _gh-repository-policy-live-admin-removal-safe "$_repo_path" "$_team"; then
        echo "Chyba: Tým '$_team' je jediný admin tým repa '$_repo_path' – neodebírám." >&2
        return 1
      fi
    fi
    _gh-jenkins-delete "orgs/$GITHUB_ORG/teams/$_team/repos/$_repo_path" "$_key" || return 1
    printf '%s\n' "$_team"
  done
  return 0
}

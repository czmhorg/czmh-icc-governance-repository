#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Klasifikace rep organizace a per-repo reconciliace pro workflow
# daily-reconcile (defs/defs.md – Report kontroly konzistence, návrh
# docs/navrh/governance/governance-repo.md). Průchod výpisem rep organizace
# (GET /orgs/{org}/repos, ne Search – axiom kapacity pro celou org neplatí
# a search je eventually consistent).
# Závislosti: gh-common-defs.sh, lib/gh-conf.sh, lib/gh-repository-policy.sh,
# lib/gh-governance-state.sh, lib/gh-governance-repo-ops.sh
# (_gh-governance-ghp-topics, _gh-governance-apply-policy-and-state),
# lib/gh-governance-report.sh.
[[ -n "${_GH_GOVERNANCE_RECONCILE_LOADED:-}" ]] && \
  declare -F _gh-governance-classify >/dev/null && return 0
_GH_GOVERNANCE_RECONCILE_LOADED=1

# Prahy počtů rep projektu (axiom Kapacita projektu, defs/defs.md):
# warning ≥ 900, error > 1000. Env-přepsatelné kvůli offline testům a
# ověření prahů v pískovišti s pár repy – produkční hodnoty jsou závazné
# z defs.md a přepisovat se nesmí.
# POC-ONLY: přepsání prahů využívá jen PoC ověření (kritérium 7).
: "${GH_GOVERNANCE_CAPACITY_WARN:=900}"
: "${GH_GOVERNANCE_CAPACITY_MAX:=1000}"

_gh-governance-classify() {
  # Klasifikuje repo organizace dle defs/defs.md – čistá offline funkce nad
  # názvem, topics a načteným _GH_CONF. Vypíše "<třída>\t<hodnota>":
  #   spravovane|zbloudile|divoke → hodnota = ghProjectKey,
  #   osirele → hodnota = p z topicu ghp-<p> (p není GH projekt),
  #   viceznacne|zadne → hodnota = "-" (zadne = žádné zjištění).
  # Použití: _gh-governance-classify <repoName> <topicsCSV>
  local _name="$1" _topics="$2" _ghp_count _ghp _p _rest
  _gh-governance-ghp-topics "$_topics" _ghp_count _ghp
  if [[ $_ghp_count -gt 1 ]]; then
    printf 'viceznacne\t-\n'
    return 0
  fi
  if [[ $_ghp_count -eq 1 ]]; then
    _p="${_ghp#"$GH_PROJECT_TOPIC_PREFIX"}"
    if [[ -z "${_GH_CONF[projects/$_p/business_service]:-}" ]]; then
      printf 'osirele\t%s\n' "$_p"
    elif [[ "$_name" == "${GH_REPO_PREFIX}-${_p}-"* ]]; then
      printf 'spravovane\t%s\n' "$_p"
    else
      printf 'zbloudile\t%s\n' "$_p"
    fi
    return 0
  fi
  # Bez topicu ghp-*: divoké jen při názvu dle konvence existujícího projektu.
  if [[ "$_name" == "${GH_REPO_PREFIX}-"* ]]; then
    _rest="${_name#"${GH_REPO_PREFIX}-"}"
    _p="${_rest%%-*}"
    if [[ "$_rest" == *-* && -n "${_GH_CONF[projects/$_p/business_service]:-}" ]]; then
      printf 'divoke\t%s\n' "$_p"
      return 0
    fi
  fi
  printf 'zadne\t-\n'
}

_gh-governance-capacity-level() {
  # Vypíše úroveň zjištění pro počet rep jedné podmnožiny projektu:
  # error (> max), warning (≥ warn), ok. Čistá funkce (offline testy).
  # Použití: _gh-governance-capacity-level <počet>
  local _n="$1"
  if [[ $_n -gt $GH_GOVERNANCE_CAPACITY_MAX ]]; then
    echo error
  elif [[ $_n -ge $GH_GOVERNANCE_CAPACITY_WARN ]]; then
    echo warning
  else
    echo ok
  fi
}

_gh-governance-org-repos-list() {
  # Vypíše všechna repa organizace po řádcích
  # "name\tarchived\tdefault_branch\ttopicsCSV" (výpis rep organizace,
  # ne Search). Pole topics v listingu živě ověřit v M6 (fallback GraphQL).
  # Použití: _gh-governance-org-repos-list
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "orgs/$GITHUB_ORG/repos?per_page=100" \
    --paginate \
    --jq '.[] | [.name, ((.archived // false) | tostring), (.default_branch // ""), ((.topics // []) | join(","))] | @tsv'
}

_gh-governance-reconcile-repo() {
  # Reconciliace jednoho spravovaného nearchivovaného repa: check před
  # (detail driftu do reportu) → warningy „tým/ruleset přiřazený navíc" →
  # idempotentní aplikace policy → odebrání týmů dle diffu ukazatele →
  # zápis ukazatele do checkoutu (commit+push dělá běh jednou na konci).
  # rc != 0 → volající reportuje „neuspesna reconciliace repa" a pokračuje.
  # Použití: _gh-governance-reconcile-repo <repoName> <branch> <projectKey>
  local _name="$1" _branch="$2" _key="$3"
  local _repo_path="${GITHUB_ORG}/${_name}" _result="" _detail="" _adopted=false
  local _expected _observed _listing _team _permission _id _rsname
  local -a _removed=()
  local -A _expected_map=()

  _gh-repository-policy-check "$_repo_path" "$_branch" "$_key" _result _detail
  if [[ "$_result" == ERROR ]]; then
    echo "Chyba: Policy check repa '$_repo_path' selhal ($_detail)." >&2
    return 1
  fi

  # Warning: tým přiřazený navíc (ručně přiřazený nad rámec repository_teams;
  # neodebírá se – v žádné verzi konfigurace nebyl, v diffu se neobjeví).
  _expected=$(_gh-repository-policy-expected-teams "$_key") || return 1
  while IFS=$'\t' read -r _team _permission; do
    [[ -n "$_team" ]] && _expected_map["$_team"]=1
  done <<< "$_expected"
  _observed=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/teams" \
    --paginate --jq '.[] | .slug') || return 1
  while IFS= read -r _team; do
    [[ -n "$_team" && ! -v _expected_map["$_team"] ]] && \
      _gh-governance-report-add warning "tym prirazeny navic" "$_repo_path" "tým '$_team'"
  done <<< "$_observed"

  # Warning: ruleset přiřazený navíc (bez prefixu mh-policy-; neodebírá se).
  _listing=$(_gh-ruleset-list "$_repo_path") || return 1
  while IFS=$'\t' read -r _id _rsname; do
    [[ -n "$_id" && "$_rsname" != mh-policy-* ]] && \
      _gh-governance-report-add warning "ruleset prirazeny navic" "$_repo_path" "ruleset '$_rsname'"
  done <<< "$_listing"

  _gh-governance-apply-policy-and-state "$_repo_path" "$_name" "$_branch" "$_key" \
    _removed _adopted || return 1

  if [[ "$_adopted" == true ]]; then
    _gh-governance-report-add info "adopce repa" "$_repo_path" \
      "ukazatel založen; zjištěné rozdíly: ${_detail:--}"
  elif [[ "$_result" == DIFF ]]; then
    _gh-governance-report-add info "opraveny drift" "$_repo_path" "$_detail"
  fi
  for _team in "${_removed[@]}"; do
    _gh-governance-report-add info "opraveny drift" "$_repo_path" \
      "odebrán tým '$_team' dle diffu konfigurace"
  done
  return 0
}

_gh-governance-reconcile-run() {
  # Celý běh reconciliace: průchod výpisem rep organizace, klasifikace,
  # per-repo reconciliace (selhání jednoho repa běh nezastaví), počty rep
  # projektů s prahy, jeden commit+push ukazatelů na konci. Itemy zapisuje
  # do reportu (musí být inicializován _gh-governance-report-init).
  # rc != 0 jen při selhání infrastruktury běhu (výpis rep, checkout).
  # Použití: _gh-governance-reconcile-run
  local _listing _name _archived _branch _topics _extra _class _value _err_file
  local _key _n _level _subset
  local -A _count_archived=() _count_live=()
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX GH_PROJECT_TOPIC_PREFIX || return 1
  _gh-governance-run-sha >/dev/null || return 1
  _listing=$(_gh-governance-org-repos-list) || {
    echo "Chyba: Výpis rep organizace '$GITHUB_ORG' selhal." >&2
    return 1
  }

  while IFS=$'\t' read -r _name _archived _branch _topics _extra; do
    [[ -n "$_name" ]] || continue
    IFS=$'\t' read -r _class _value <<< "$(_gh-governance-classify "$_name" "$_topics")"
    case "$_class" in
      viceznacne)
        _gh-governance-report-add error "viceznacne repo" "$_name" \
          "více než jeden topic ${GH_PROJECT_TOPIC_PREFIX}*" ;;
      osirele)
        _gh-governance-report-add error "osirele repo" "$_name" \
          "topic ${GH_PROJECT_TOPIC_PREFIX}${_value}, '${_value}' není GH projekt" ;;
      zbloudile)
        _gh-governance-report-add error "zbloudile repo" "$_name" \
          "topic ${GH_PROJECT_TOPIC_PREFIX}${_value}, název mimo konvenci ${GH_REPO_PREFIX}-${_value}-*" ;;
      divoke)
        _gh-governance-report-add error "divoke repo" "$_name" \
          "název dle konvence projektu '${_value}', chybí topic ${GH_PROJECT_TOPIC_PREFIX}${_value}" ;;
      spravovane)
        _key="$_value"
        if [[ "$_archived" == true ]]; then
          _count_archived["$_key"]=$(( ${_count_archived[$_key]:-0} + 1 ))
          _gh-governance-report-add info "vynechane archivovane repo" \
            "${GITHUB_ORG}/${_name}" "archivované repo se přeskakuje, nic se nemění"
        else
          _count_live["$_key"]=$(( ${_count_live[$_key]:-0} + 1 ))
          _err_file=$(mktemp) || return 1
          if ! _gh-governance-reconcile-repo "$_name" "$_branch" "$_key" 2>"$_err_file"; then
            _gh-governance-report-add error "neuspesna reconciliace repa" \
              "${GITHUB_ORG}/${_name}" "$(tail -n 1 "$_err_file")"
          fi
          rm -f "$_err_file"
        fi ;;
      zadne) ;;
    esac
  done <<< "$_listing"

  # Počty rep projektu (archivovaná a nearchivovaná podmnožina zvlášť).
  for _key in "${_GH_CONF_PROJECT_KEYS[@]}"; do
    for _subset in nearchivovana archivovana; do
      if [[ "$_subset" == nearchivovana ]]; then
        _n="${_count_live[$_key]:-0}"
      else
        _n="${_count_archived[$_key]:-0}"
      fi
      _level=$(_gh-governance-capacity-level "$_n")
      case "$_level" in
        error)
          _gh-governance-report-add error "kapacita projektu prekrocena" "$_key" \
            "$_subset repa: $_n > $GH_GOVERNANCE_CAPACITY_MAX (porušení axiomu Kapacita projektu)" ;;
        warning)
          _gh-governance-report-add warning "kapacita projektu" "$_key" \
            "$_subset repa: $_n ≥ $GH_GOVERNANCE_CAPACITY_WARN (blíží se limit axiomu)" ;;
      esac
    done
  done

  # Jeden commit+push posunutých ukazatelů na konci běhu; selhání pushe je
  # error v reportu, aplikované změny se nevrací (ukazatel smí být „starší").
  if ! _gh-governance-state-push "daily-reconcile: posun ukazatelů"; then
    _gh-governance-report-add error "neuspesna reconciliace repa" \
      "${GITHUB_ORG}/${GH_GOVERNANCE_REPO}" "push ukazatelů /state/ selhal – ukazatele se posunou příštím během"
  fi
  return 0
}

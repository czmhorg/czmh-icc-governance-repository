#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Klasifikace rep organizace a per-repo reconciliace pro workflow
# daily-reconcile (defs/defs.md – Report kontroly konzistence).
# Průchod výpisem rep organizace
# (GET /orgs/{org}/repos, ne Search – axiom kapacity pro celou org neplatí
# a search je eventually consistent).
# Závislosti: gh-common-defs.sh, lib/gh-conf.sh, lib/gh-repository-policy.sh,
# lib/gh-governance-state.sh, lib/gh-governance-repo-ops.sh
# (_gh-governance-ghp-topics, _gh-governance-apply-policy-and-state),
# lib/gh-governance-report.sh, lib/gh-governance-manifest.sh (rebuild),
# lib/gh-governance-issue.sh (track-delete sweep; jen v GitHub Actions).
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
    if [[ -z "${_GH_CONF[projects/$_p/domain]:-}" ]]; then
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
    if [[ "$_rest" == *-* && -n "${_GH_CONF[projects/$_p/domain]:-}" ]]; then
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

_gh-governance-mhn-report-level() {
  # Čistá funkce (offline testy): úroveň položky reportu k property MHN po
  # aplikaci policy. Vypíše none (sedí, nebo adopce – rozdíl patří do položky
  # adopce repa), info-filled (property chyběla), info-moved (doména projektu
  # se od SHA ukazatele změnila = konvergence dle conf.d; i projekt, který na
  # SHA ukazatele neexistoval) nebo warning (conf.d se nezměnilo, a přesto
  # property neseděla = ruční změna v GH).
  # Použití: _gh-governance-mhn-report-level <observed> <expected> <mhn_at_pointer> <adopted:true|false>
  local _observed="$1" _expected="$2" _at_pointer="$3" _adopted="$4"
  if [[ "$_observed" == "$_expected" || "$_adopted" == true ]]; then
    echo none
  elif [[ -z "$_observed" ]]; then
    echo info-filled
  elif [[ "$_at_pointer" != "$_expected" ]]; then
    echo info-moved
  else
    echo warning
  fi
}

_gh-governance-reconcile-properties-report() {
  # Položky reportu k custom properties po aplikaci policy (property už jsou
  # srovnané): chybějící Deployment_Target → info; MHN dle
  # _gh-governance-mhn-report-level → info (doplněna / změna domain projektu)
  # nebo warning `rucne zmenena MHN property`. Při adopci položky nepřidává –
  # rozdíly vypíše přes nameref jako doplněk detailu položky `adopce repa`.
  # MHN na SHA ukazatele se čte jen je-li třeba; selhání čtení = konvergence
  # (info), nikdy ne chyba běhu.
  # Použití: _gh-governance-reconcile-properties-report <repo_path> <projectKey> <mhn_observed> <mhn_expected> <dt_observed> <pointer_sha> <adopted> <adoption_detail_name>
  local _repo_path="$1" _key="$2" _mhn="$3" _expected="$4" _dt="$5"
  local _pointer_sha="$6" _adopted="$7" _mhn_old _domain_old _level
  declare -n _adoption_detail_ref="$8"
  _adoption_detail_ref=""
  if [[ "$_adopted" == true ]]; then
    [[ "$_mhn" == "$_expected" ]] || \
      _adoption_detail_ref="MHN property nastavena ('$_expected')"
    [[ -n "$_dt" ]] || \
      _adoption_detail_ref+="${_adoption_detail_ref:+; }Deployment_Target property doplněna ('$GH_DEPLOYMENT_TARGET_DEFAULT')"
    return 0
  fi
  [[ -n "$_dt" ]] || _gh-governance-report-add info "opraveny drift" "$_repo_path" \
    "Deployment_Target property doplněna ('$GH_DEPLOYMENT_TARGET_DEFAULT')"
  _mhn_old="$_expected"
  if [[ -n "$_mhn" && "$_mhn" != "$_expected" ]]; then
    if _domain_old=$(_gh-governance-conf-domain-at-commit "$_pointer_sha" "$_key"); then
      _mhn_old="${_domain_old%%/*}"
    else
      _mhn_old=""
    fi
  fi
  _level=$(_gh-governance-mhn-report-level "$_mhn" "$_expected" "$_mhn_old" "$_adopted")
  case "$_level" in
    info-filled)
      _gh-governance-report-add info "opraveny drift" "$_repo_path" \
        "MHN property doplněna ('$_expected')" ;;
    info-moved)
      _gh-governance-report-add info "opraveny drift" "$_repo_path" \
        "MHN property '$_mhn' → '$_expected' dle změny domain projektu" ;;
    warning)
      _gh-governance-report-add warning "rucne zmenena MHN property" "$_repo_path" \
        "v GH bylo '$_mhn', nastaveno '$_expected' dle conf.d; příslušnost repa se mění jen v conf.d" ;;
  esac
  return 0
}

_gh-governance-reconcile-repo() {
  # Reconciliace jednoho spravovaného nearchivovaného repa: check před
  # (detail driftu do reportu) + stav před aplikací (ukazatel, property) →
  # idempotentní aplikace policy → odebrání týmů a Jenkins loginu dle diffu
  # ukazatele → zápis ukazatele do checkoutu (commit+push dělá běh jednou na
  # konci) → warningy „tým/ruleset/collaborator přiřazený navíc" → položky
  # reportu (adopce, opravený drift, ruční změna MHN).
  # rc != 0 → volající reportuje „neuspesna reconciliace repa" a pokračuje.
  # Použití: _gh-governance-reconcile-repo <repoName> <branch> <projectKey>
  local _name="$1" _branch="$2" _key="$3"
  local _repo_path="${GITHUB_ORG}/${_name}" _result="" _detail="" _adopted=false
  local _expected _observed _listing _team _permission _id _rsname _login _role
  local _expected_mhn _mhn_observed="" _dt_observed="" _pointer_sha="" _adoption_props=""
  local _removed_login=""
  local -a _removed=()
  local -A _expected_map=()

  _gh-repository-policy-check "$_repo_path" "$_branch" "$_key" _result _detail
  if [[ "$_result" == ERROR ]]; then
    echo "Chyba: Policy check repa '$_repo_path' selhal ($_detail)." >&2
    return 1
  fi
  # Stav před aplikací – rozlišení ruční změny MHN od konvergence: ukazatel
  # (jen soubor) a pozorované property (čtení navíc k policy checku, 1 GET).
  _expected_mhn=$(_gh-repository-policy-properties-expected-mhn "$_key") || return 1
  _gh-repository-policy-properties-read "$_repo_path" _mhn_observed _dt_observed || return 1
  _pointer_sha=$(_gh-governance-state-read "$_name" 2>/dev/null) || _pointer_sha=""

  _gh-governance-apply-policy-and-state "$_repo_path" "$_name" "$_branch" "$_key" \
    _removed _adopted _removed_login || return 1

  # Warningy se zjišťují až po aplikaci a odebrání – popisují stav na konci
  # běhu (tým odebraný tímto během dle diffu není „přiřazený navíc").

  # Warning: tým přiřazený navíc (ručně přiřazený nad rámec repository_teams;
  # neodebírá se – v žádné verzi konfigurace nebyl, v diffu se neobjeví).
  _expected=$(_gh-repository-policy-expected-teams "$_key") || return 1
  while IFS=$'\t' read -r _team _permission; do
    [[ -n "$_team" ]] && _expected_map["$_team"]=1
  done <<< "$_expected"
  # ghOrgSecurityManagersTeam je implicitní součást politiky — není tým navíc.
  _expected_map["$GH_SECURITY_MANAGERS_TEAM"]=1
  _observed=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/teams" \
    --paginate --jq '.[] | .slug') || return 1
  while IFS= read -r _team; do
    [[ -n "$_team" && ! -v _expected_map["$_team"] ]] && \
      _gh-governance-report-add warning "tym prirazeny navic" "$_repo_path" "tým '$_team'"
  done <<< "$_observed"

  # Warning: ruleset přiřazený navíc (bez prefixu ${GH_RULESET_PREFIX}-; neodebírá se).
  _listing=$(_gh-ruleset-list "$_repo_path") || return 1
  while IFS=$'\t' read -r _id _rsname; do
    [[ -n "$_id" && "$_rsname" != "${GH_RULESET_PREFIX}-"* ]] && \
      _gh-governance-report-add warning "ruleset prirazeny navic" "$_repo_path" "ruleset '$_rsname'"
  done <<< "$_listing"

  # Warning: collaborator přiřazený navíc (přímý collaborator mimo governance
  # bota a Jenkins login aktuální domény; neodebírá se – úklid na vyžádání
  # tools/remove-extra-collaborators.sh). Jenkins login staré domény odebral
  # tento běh dle diffu ukazatele výše, takže se tu už neobjeví.
  _listing=$(_gh-repository-policy-extra-collaborators-list "$_repo_path" "$_key") || return 1
  while IFS=$'\t' read -r _login _role; do
    [[ -n "$_login" ]] && _gh-governance-report-add warning "collaborator prirazeny navic" \
      "$_repo_path" "collaborator '$_login' ($_role)"
  done <<< "$_listing"

  _gh-governance-reconcile-properties-report "$_repo_path" "$_key" "$_mhn_observed" \
    "$_expected_mhn" "$_dt_observed" "$_pointer_sha" "$_adopted" _adoption_props
  if [[ "$_adopted" == true ]]; then
    _gh-governance-report-add info "adopce repa" "$_repo_path" \
      "ukazatel založen; zjištěné rozdíly: ${_detail:--}${_adoption_props:+; $_adoption_props}"
  elif [[ "$_result" == DIFF ]]; then
    # Rozdíl v property hlásí specifická položka výše; generické info zůstává
    # pro ostatní detaily (policy check hlásí první rozdíl v pořadí checků).
    case "$_detail" in
      "MHN property differs"|"Deployment_Target property missing") ;;
      *) _gh-governance-report-add info "opraveny drift" "$_repo_path" "$_detail" ;;
    esac
  fi
  for _team in "${_removed[@]}"; do
    _gh-governance-report-add info "opraveny drift" "$_repo_path" \
      "odebrán tým '$_team' dle diffu konfigurace"
  done
  [[ -n "$_removed_login" ]] && _gh-governance-report-add info "opraveny drift" "$_repo_path" \
    "odebrán Jenkins collaborator '$_removed_login' dle diffu konfigurace"
  return 0
}

_gh-governance-reconcile-dead-pointers() {
  # Vypíše názvy ukazatelů state/, jejichž repo není ve výpisu rep organizace
  # (mrtvý ukazatel – smazání minulo track-delete). Dotfiles (completion
  # manifest, .gitkeep) glob `*` přirozeně přeskakuje. Čistá offline funkce.
  # Použití: _gh-governance-reconcile-dead-pointers <listing_file>
  local _listing_file="$1" _root _file _name _rest
  local -A _org_repos=()
  _root=$(_gh-governance-checkout-root) || return 1
  [[ -d "$_root/state" ]] || return 0
  while IFS=$'\t' read -r _name _rest; do
    [[ -n "$_name" ]] && _org_repos["$_name"]=1
  done < "$_listing_file"
  for _file in "$_root/state/"*; do
    [[ -f "$_file" ]] || continue
    _name="${_file##*/}"
    [[ -v _org_repos["$_name"] ]] || printf '%s\n' "$_name"
  done
  return 0
}

_gh-governance-track-delete-sweep() {
  # Pojistka za workflow track-delete: projde otevřené track-delete issues
  # starší než 1 den. Repo už neexistuje → idempotentní úklid (ukazatel,
  # řádek manifestu), zavření issue a info item; repo stále existuje → error
  # `zaseknute smazani repa` + komentář; nevalidní tělo → zavření not_planned.
  # Běží jen v GitHub Actions (lokální běh nemá issues RW ani jq).
  # Použití: _gh-governance-track-delete-sweep <listing_file>
  local _listing_file="$1" _cutoff _issues _number _created _created_s _body
  local _name _rest
  local -A _org_repos=()
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_GOVERNANCE_REPO || return 1
  while IFS=$'\t' read -r _name _rest; do
    [[ -n "$_name" ]] && _org_repos["$_name"]=1
  done < "$_listing_file"
  _cutoff=$(( $(date +%s) - 86400 ))
  _issues=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue list \
    --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" --label track-delete --state open \
    --json number,createdAt --jq '.[] | [(.number|tostring), .createdAt] | @tsv') || {
    echo "Chyba: Výpis otevřených track-delete issues selhal." >&2
    return 1
  }
  while IFS=$'\t' read -r _number _created; do
    [[ -n "$_number" ]] || continue
    _created_s=$(date -d "$_created" +%s 2>/dev/null) || continue
    (( _created_s <= _cutoff )) || continue
    _body=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue view "$_number" \
      --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" --json body --jq .body) || continue
    local -A _td=()
    if ! _gh-governance-track-delete-body-parse "$_body" _td; then
      _gh-governance-issue-close-rejected "$_number" "${_td[reject]:-unexpected_line}" || true
      continue
    fi
    if [[ -v _org_repos["${_td[repo_name]}"] ]]; then
      _gh-governance-report-add error "zaseknute smazani repa" \
        "${GITHUB_ORG}/${_td[repo_name]}" \
        "track-delete issue #$_number starší než 1 den, repo stále existuje – zamítnuté/zaseknuté smazání, ruční kontrola"
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "$_number" \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
        --body "Repo stále existuje více než 1 den po žádosti o smazání – zamítnuté nebo zaseknuté smazání, nutná ruční kontrola." \
        >/dev/null || true
    else
      _gh-governance-state-remove "${_td[repo_name]}" || continue
      _gh-governance-manifest-remove "${_td[project_key]}" "${_td[gh_name]}" || continue
      _gh-governance-issue-close-done "$_number" \
        "Repo zaniklo; ukazatel /state/ i řádek completion manifestu uklizeny nočním reconcile." || true
      _gh-governance-report-add info "track-delete vyrizen reconcilem" \
        "${GITHUB_ORG}/${_td[repo_name]}" "issue #$_number zavřeno, artefakty uklizeny"
    fi
  done <<< "$_issues"
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
  local _key _n _level _subset _listing_file _dead _manifest_added=0 _manifest_removed=0
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

  # Přestavba completion manifestu z už načteného listingu (žádné další API)
  # a navazující kontroly nad týmž listingem; vše jede jedním pushem níže.
  _listing_file=$(mktemp) || return 1
  printf '%s\n' "$_listing" > "$_listing_file"
  if _gh-governance-manifest-rebuild "$_listing_file" _manifest_added _manifest_removed; then
    if (( _manifest_added > 0 || _manifest_removed > 0 )); then
      _gh-governance-report-add info "obnoven completion manifest" \
        "${GITHUB_ORG}/${GH_GOVERNANCE_REPO}" "+${_manifest_added}/−${_manifest_removed} řádků"
    fi
  else
    _gh-governance-report-add error "neuspesna reconciliace repa" \
      "${GITHUB_ORG}/${GH_GOVERNANCE_REPO}" "přestavba completion manifestu selhala"
  fi

  # Mrtvé ukazatele state/ (repo v organizaci už neexistuje): jen hlášení,
  # ukazatel se neodstraňuje (viz defs/defs.md).
  while IFS= read -r _dead; do
    [[ -n "$_dead" ]] || continue
    _gh-governance-report-add warning "mrtvy ukazatel state" "$_dead" \
      "ukazatel state/ existuje, repo v organizaci ne (smazání minulo track-delete)"
  done <<< "$(_gh-governance-reconcile-dead-pointers "$_listing_file")"

  # Pojistka za track-delete (guard na GitHub Actions je uvnitř).
  _gh-governance-track-delete-sweep "$_listing_file" || \
    _gh-governance-report-add error "neuspesna reconciliace repa" \
      "${GITHUB_ORG}/${GH_GOVERNANCE_REPO}" "track-delete sweep selhal"
  rm -f "$_listing_file"

  # Jeden commit+push posunutých ukazatelů na konci běhu; selhání pushe je
  # error v reportu, aplikované změny se nevrací (ukazatel smí být „starší").
  if ! _gh-governance-state-push "daily-reconcile: posun ukazatelů"; then
    _gh-governance-report-add error "neuspesna reconciliace repa" \
      "${GITHUB_ORG}/${GH_GOVERNANCE_REPO}" "push ukazatelů /state/ selhal – ukazatele se posunou příštím během"
  fi
  return 0
}

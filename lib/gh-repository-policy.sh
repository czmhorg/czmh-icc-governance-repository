#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

[[ -n "${_GH_REPOSITORY_POLICY_LOADED:-}" ]] && \
  declare -F _gh-repository-policy-check >/dev/null && return 0
_GH_REPOSITORY_POLICY_LOADED=1

_gh-jenkins-policy-resolve() {
  local _key="$1" _login_name="$2" _configured_name="$3" _decision_name="$4"
  local _mhn
  declare -n _login_ref="$_login_name" _configured_ref="$_configured_name"
  declare -n _decision_ref="$_decision_name"

  _login_ref=""
  _configured_ref=false
  _decision_ref=disallowed
  _mhn=$(_mhn_for_key "$_key") || {
    echo "Chyba: projectKey '$_key' neni nakonfigurovan v zadnem MHN." >&2
    return 1
  }
  # configured/login ⇔ business service má klíč jenkins_user; decision ⇔
  # atribut jenkins u některé položky klíče rulesets projektu. Formát loginu
  # a konzistenci validuje parser lib/gh-conf.sh při načtení konfigurace.
  if [[ -v _GH_CONF["business-services/$_mhn/jenkins_user"] ]]; then
    _login_ref="${_GH_CONF[business-services/$_mhn/jenkins_user]}"
    _configured_ref=true
    _gh-project-uses-jenkins "$_key" && _decision_ref=allowed
  fi
  return 0
}

_gh-api-input-retry() {
  # Pošle JSON payload na GH API endpoint s retry 5×2 s na přechodné chyby.
  # Použití: _gh-api-input-retry <endpoint> <metoda> <payload> <popis pro hlášky>
  local _endpoint="$1" _method="$2" _payload="$3" _label="$4"
  local _attempt _error _error_file
  _error_file=$(mktemp) || return 1

  for _attempt in 1 2 3 4 5; do
    if printf '%s' "$_payload" | \
        GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "$_endpoint" \
          --method "$_method" \
          --header "Accept: application/vnd.github+json" \
          --input - >/dev/null 2>"$_error_file"; then
      rm -f "$_error_file"
      return 0
    fi

    _error=$(< "$_error_file")
    if [[ "$_attempt" == 5 ]]; then
      [[ -n "$_error" ]] && printf '%s\n' "$_error" >&2
      rm -f "$_error_file"
      return 1
    fi
    echo "Varovani: Nastaveni $_label selhalo (pokus $_attempt/5), opakuji za 2 s." >&2
    [[ -n "$_error" ]] && printf '%s\n' "$_error" >&2
    : > "$_error_file"
    sleep 2
  done
}

_gh-jenkins-collaborator-add() {
  local _repo_path="$1" _key="$2" _login="$3"
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/collaborators/$_login" \
    --method PUT --field permission=push >/dev/null
}

_gh-jenkins-delete() {
  # 404-tolerantní DELETE na GH API (mizející zdroj není chyba).
  # Použití: _gh-jenkins-delete <endpoint> <projectKey>
  local _endpoint="$1" _key="$2" _error_file _error
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _error_file=$(mktemp) || return 1
  if GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "$_endpoint" --method DELETE \
      >/dev/null 2>"$_error_file"; then
    rm -f "$_error_file"
    return 0
  fi
  _error=$(< "$_error_file")
  rm -f "$_error_file"
  grep -qF '(HTTP 404)' <<< "$_error" && return 0
  [[ -n "$_error" ]] && printf '%s\n' "$_error" >&2
  return 1
}

_gh-jenkins-collaborator-remove() {
  local _repo_path="$1" _key="$2" _login="$3"
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-jenkins-delete "repos/$_repo_path/collaborators/$_login" "$_key"
}

_gh-jenkins-policy-preflight() {
  local _key="$1" _login _configured _decision _authenticated
  _gh-jenkins-policy-resolve "$_key" _login _configured _decision || return 1
  [[ "$_decision" == allowed ]] || return 0

  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "users/$_login" >/dev/null || {
    echo "Chyba: Jenkins ucet '$_login' neexistuje nebo jej nelze overit." >&2
    return 1
  }
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "orgs/$GITHUB_ORG/members/$_login" >/dev/null || {
    echo "Chyba: Jenkins ucet '$_login' neni clenem organizace '$GITHUB_ORG'." >&2
    return 1
  }
  _authenticated=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api user --jq '.login') || return 1
  if [[ "${_authenticated,,}" == "${_login,,}" ]]; then
    echo "Chyba: Jenkins ucet nesmi byt totozny s autentizovanym automatizacnim uctem." >&2
    return 1
  fi
}

# ── Repository rulesets ───────────────────────────────────────────────────────
# Profil = definice jednoho rulesetu (pole ochrany + klíč branches), projekt si
# rulesety vybírá klíčem rulesets; na repu vznikají rulesety mh-policy-<profil>.
# Návrh a rozhodnutí: docs/navrh/governance/prechod-rulesets.md.

_gh-conf-rulesets-items() {
  # Vypíše položky klíče rulesets projektu po řádcích: "<profil>\t<jenkins:0|1>".
  # Jediné místo parsování formátu položky (<profil> nebo <profil>|jenkins);
  # formát a odkazy validuje parser lib/gh-conf.sh při načtení konfigurace.
  # Použití: _gh-conf-rulesets-items <projectKey>
  local _key="$1" _rest _item _jenkins
  _rest="${_GH_CONF[projects/$_key/rulesets]:-}"
  if [[ -z "$_rest" ]]; then
    echo "Chyba: Konfigurace 'rulesets' pro projectKey '$_key' nenalezena. Zkontroluj conf.d/projects/$_key.conf." >&2
    return 1
  fi
  _rest+=","
  while [[ -n "$_rest" ]]; do
    _item="${_rest%%,*}"
    _rest="${_rest#*,}"
    _jenkins=0
    [[ "$_item" == *'|jenkins' ]] && _jenkins=1
    printf '%s\t%s\n' "${_item%%|*}" "$_jenkins"
  done
}

_gh-project-uses-jenkins() {
  # rc 0 ⇔ aspoň jedna položka klíče rulesets projektu má atribut jenkins.
  # Odvozený příznak „projekt používá Jenkinse" (náhrada jenkins_user_enabled).
  # Použití: _gh-project-uses-jenkins <projectKey>
  local _items
  _items=$(_gh-conf-rulesets-items "$1" 2>/dev/null) || return 1
  [[ "$_items" == *$'\t'1* ]]
}

declare -gA _GH_JENKINS_USER_ID_CACHE=()

_gh-jenkins-user-id() {
  # Vrátí číselné ID GitHub účtu (bypass actor rulesetu vyžaduje actor_id,
  # ne login); výsledek cachuje v paměti shellu.
  # Použití: _gh-jenkins-user-id <login>
  local _login="$1" _id
  if [[ -v _GH_JENKINS_USER_ID_CACHE["$_login"] ]]; then
    printf '%s\n' "${_GH_JENKINS_USER_ID_CACHE[$_login]}"
    return 0
  fi
  _id=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "users/$_login" --jq '.id') || {
    echo "Chyba: Nepodarilo se zjistit ID GitHub uctu '$_login'." >&2
    return 1
  }
  if [[ ! "$_id" =~ ^[0-9]+$ ]]; then
    echo "Chyba: Neocekavane ID GitHub uctu '$_login': '$_id'." >&2
    return 1
  fi
  _GH_JENKINS_USER_ID_CACHE["$_login"]="$_id"
  printf '%s\n' "$_id"
}

_gh-ruleset-payload() {
  # Sestaví JSON payload rulesetu mh-policy-<profil> z polí profilu – offline,
  # bez sítě (actor_id dodá volající). Překlad branch protection → ruleset dle
  # docs/github/branch-protection-vs-rulesets-mapovani.md a rozhodnutí návrhu:
  #   - allow_force_pushes/allow_deletions=false → pravidlo non_fast_forward/deletion,
  #   - required_status_checks bez checků → pravidlo se vynechá (API odmítá []),
  #   - restrictions != null → pravidlo update, jen má-li ruleset bypass actora,
  #   - enforce_admins=false → bypass actor RepositoryRole 5 (admin).
  # Použití: _gh-ruleset-payload <projectKey> <profil> <jenkins:0|1> [actor_id]
  local _key="$1" _profile="$2" _jenkins="$3" _actor_id="${4:-}"
  local _field _value _bypass_actors="" _rules="" _sep
  for _field in branches $_GH_CONF_PROFILE_FIELDS; do
    if [[ -z "${_GH_CONF[profiles/$_profile/$_field]:-}" ]]; then
      echo "Chyba: Profil '$_profile' (projekt '$_key') nemá klíč '$_field' – payload rulesetu nelze sestavit. Zkontroluj conf.d/profiles/$_profile.conf." >&2
      return 1
    fi
  done

  if [[ "$_jenkins" == 1 ]]; then
    if [[ ! "$_actor_id" =~ ^[0-9]+$ ]]; then
      echo "Chyba: Položka '$_profile|jenkins' vyžaduje číselné actor_id Jenkins účtu (je '${_actor_id:-<prázdné>}')." >&2
      return 1
    fi
    _bypass_actors='{ "actor_id": '"$_actor_id"', "actor_type": "User", "bypass_mode": "always" }'
  fi
  if [[ "${_GH_CONF[profiles/$_profile/enforce_admins]}" == false ]]; then
    _bypass_actors+="${_bypass_actors:+, }"'{ "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }'
  fi

  local -a _rules_arr=()
  _rules_arr+=("$(printf '{ "type": "pull_request", "parameters": { "required_approving_review_count": %s, "dismiss_stale_reviews_on_push": %s, "require_code_owner_review": %s, "require_last_push_approval": false, "required_review_thread_resolution": false } }' \
    "${_GH_CONF[profiles/$_profile/required_approving_review_count]}" \
    "${_GH_CONF[profiles/$_profile/dismiss_stale_reviews]}" \
    "${_GH_CONF[profiles/$_profile/require_code_owner_reviews]}")")
  _value="${_GH_CONF[profiles/$_profile/required_status_checks]}"
  _value="${_value//[[:space:]]/}"
  if [[ "$_value" != null && "$_value" != *'"contexts":[]'* ]]; then
    echo "Chyba: Profil '$_profile' má neprázdný seznam checků v required_status_checks – překlad na ruleset zatím není podporován (viz docs/navrh/governance/prechod-rulesets.md)." >&2
    return 1
  fi
  _value="${_GH_CONF[profiles/$_profile/restrictions]}"
  _value="${_value//[[:space:]]/}"
  if [[ "$_value" != null && -n "$_bypass_actors" ]]; then
    _rules_arr+=('{ "type": "update" }')
  fi
  [[ "${_GH_CONF[profiles/$_profile/allow_force_pushes]}" == false ]] && \
    _rules_arr+=('{ "type": "non_fast_forward" }')
  [[ "${_GH_CONF[profiles/$_profile/allow_deletions]}" == false ]] && \
    _rules_arr+=('{ "type": "deletion" }')
  [[ "${_GH_CONF[profiles/$_profile/required_linear_history]}" == true ]] && \
    _rules_arr+=('{ "type": "required_linear_history" }')
  _sep=""
  for _value in "${_rules_arr[@]}"; do
    _rules+="$_sep$_value"
    _sep=$',\n    '
  done

  printf '{
  "name": "mh-policy-%s",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["%s"], "exclude": [] } },
  "bypass_actors": [%s],
  "rules": [
    %s
  ]
}' "$_profile" "${_GH_CONF[profiles/$_profile/branches]}" "$_bypass_actors" "$_rules"
}

_gh-ruleset-payloads-build() {
  # Sestaví payloady všech položek klíče rulesets projektu do nameref
  # asociativního pole jméno rulesetu → payload. Slouží i jako fail-fast
  # validace konfigurace před první mutací (včetně lookupu actor_id).
  # Použití: local -A _p=(); _gh-ruleset-payloads-build <projectKey> <jenkins_login> _p
  local _key="$1" _jenkins_login="$2" _items _profile _jenkins _actor_id _payload
  declare -n _payloads_ref="$3"
  _items=$(_gh-conf-rulesets-items "$_key") || return 1
  while IFS=$'\t' read -r _profile _jenkins; do
    _actor_id=""
    if [[ "$_jenkins" == 1 ]]; then
      if [[ -z "$_jenkins_login" ]]; then
        echo "Chyba: Položka '$_profile|jenkins' v klíči rulesets projektu '$_key', ale Jenkins login není k dispozici. Zkontroluj klíč jenkins_user business service v conf.d/business-services/." >&2
        return 1
      fi
      _actor_id=$(_gh-jenkins-user-id "$_jenkins_login") || return 1
    fi
    _payload=$(_gh-ruleset-payload "$_key" "$_profile" "$_jenkins" "$_actor_id") || return 1
    _payloads_ref["mh-policy-$_profile"]="$_payload"
  done <<< "$_items"
}

_gh-ruleset-list() {
  # Vypíše rulesety repa po řádcích "<id>\t<jméno>" (repository-level source).
  # Použití: _gh-ruleset-list <repo_path>
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$1/rulesets" \
    --paginate --jq '.[] | select(.source_type == "Repository") | [.id, .name] | @tsv'
}

_gh-ruleset-apply() {
  # Aplikuje rulesety podle klíče rulesets projektu: find-by-name → POST
  # (neexistuje) / PUT (existuje); osiřelé rulesety mh-policy-* smaže.
  # Ruleset se posílá vždy jako kompletní payload (PUT přepisuje i bypass).
  # Použití: _gh-ruleset-apply <repo_path> <projectKey> [jenkins_login]
  local _repo_path="$1" _key="$2" _jenkins_login="${3:-}"
  local _listing _id _name
  local -A _expected_payloads=() _existing_ids=()
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-ruleset-payloads-build "$_key" "$_jenkins_login" _expected_payloads || return 1
  _listing=$(_gh-ruleset-list "$_repo_path") || return 1
  while IFS=$'\t' read -r _id _name; do
    [[ -n "$_id" ]] && _existing_ids["$_name"]="$_id"
  done <<< "$_listing"
  for _name in "${!_expected_payloads[@]}"; do
    if [[ -v _existing_ids["$_name"] ]]; then
      _gh-api-input-retry "repos/$_repo_path/rulesets/${_existing_ids[$_name]}" \
        PUT "${_expected_payloads[$_name]}" "rulesetu '$_name'" || return 1
    else
      _gh-api-input-retry "repos/$_repo_path/rulesets" \
        POST "${_expected_payloads[$_name]}" "rulesetu '$_name'" || return 1
    fi
  done
  for _name in "${!_existing_ids[@]}"; do
    [[ "$_name" == mh-policy-* ]] || continue
    [[ -v _expected_payloads["$_name"] ]] && continue
    _gh-jenkins-delete "repos/$_repo_path/rulesets/${_existing_ids[$_name]}" "$_key" || return 1
  done
}

_gh-ruleset-check() {
  # Sémanticky porovná rulesety mh-policy-* repa s očekávaným stavem z conf.d
  # (normalizovaný JSON přes jq) a smoke-testem ověří efektivní pravidla
  # výchozí větve. Výstup: OK / DIFF (rc 0); rc 2 při chybě.
  # Použití: _gh-ruleset-check <repo_path> <branch> <projectKey> [jenkins_login]
  local _repo_path="$1" _branch="$2" _key="$3" _jenkins_login="${4:-}"
  local _listing _id _name _result _observed_types _types _t _filter
  local -A _expected_payloads=() _existing_ids=()
  _gh-ruleset-payloads-build "$_key" "$_jenkins_login" _expected_payloads || return 2
  _listing=$(_gh-ruleset-list "$_repo_path") || return 2
  while IFS=$'\t' read -r _id _name; do
    [[ -n "$_id" ]] && _existing_ids["$_name"]="$_id"
  done <<< "$_listing"
  for _name in "${!_expected_payloads[@]}"; do
    [[ -v _existing_ids["$_name"] ]] || { printf 'DIFF\n'; return 0; }
  done
  for _name in "${!_existing_ids[@]}"; do
    if [[ "$_name" == mh-policy-* && ! -v _expected_payloads["$_name"] ]]; then
      printf 'DIFF\n'
      return 0
    fi
  done
  # Normalizace projektuje obě strany jen na spravovaná pole – nová pole,
  # která GitHub časem přidá do GET odpovědi, porovnání nerozbijí.
  _filter='(env.EXPECTED_RULESET_JSON | fromjson) as $e |
    def norm: {
      name, target, enforcement,
      conditions: { ref_name: { include: ((.conditions.ref_name.include // []) | sort),
                                exclude: ((.conditions.ref_name.exclude // []) | sort) } },
      bypass_actors: ((.bypass_actors // []) | map({actor_id, actor_type, bypass_mode})
                      | sort_by(.actor_type, .actor_id)),
      rules: ((.rules // []) | map(
        { type,
          parameters: (if .type == "pull_request" then
            { required_approving_review_count: .parameters.required_approving_review_count,
              dismiss_stale_reviews_on_push: .parameters.dismiss_stale_reviews_on_push,
              require_code_owner_review: .parameters.require_code_owner_review,
              require_last_push_approval: .parameters.require_last_push_approval,
              required_review_thread_resolution: .parameters.required_review_thread_resolution }
          else {} end) }) | sort_by(.type))
    };
    if (. | norm) == ($e | norm) then "OK" else "DIFF" end'
  for _name in "${!_expected_payloads[@]}"; do
    _result=$(EXPECTED_RULESET_JSON="${_expected_payloads[$_name]}" \
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
      "repos/$_repo_path/rulesets/${_existing_ids[$_name]}" --jq "$_filter") || return 2
    [[ "$_result" == OK ]] || { printf 'DIFF\n'; return 0; }
  done
  # Smoke-test: pravidla rulesetů cílících výchozí větev musí být podmnožinou
  # efektivních pravidel větve (během překryvu s branch protection jich může
  # být víc; přesné porovnání dělá GET /rulesets/{id} výše).
  _observed_types=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
    "repos/$_repo_path/rules/branches/$(_url_encode_path "$_branch")" \
    --jq '[.[].type] | unique | join(",")') || return 2
  for _name in "${!_expected_payloads[@]}"; do
    [[ "${_expected_payloads[$_name]}" == *'"include": ["~DEFAULT_BRANCH"]'* ]] || continue
    _types=$(grep -o '"type": "[a-z_]*"' <<< "${_expected_payloads[$_name]}" | \
      grep -o '[a-z_]*"$' | tr -d '"')
    for _t in $_types; do
      [[ ",$_observed_types," == *",$_t,"* ]] || { printf 'DIFF\n'; return 0; }
    done
  done
  printf 'OK\n'
}

_gh-repository-policy-expected-teams() {
  local _key="$1" _teams _entry _team _permission
  local -a _entries=()
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _teams=$(_gh-teams-for-key "$_key" GITHUB_REPO_TEAMS) || return 1
  IFS=',' read -ra _entries <<< "$_teams"
  for _entry in "${_entries[@]}"; do
    _team="${_entry%%|*}"
    _permission=$(_gh-perm-to-api "${_entry##*|}")
    printf '%s\t%s\n' "$_team" "$_permission"
  done | LC_ALL=C sort -u
}

_gh-repository-policy-collaborator-check() {
  local _repo_path="$1" _login="$2" _expected="$3" _permission
  [[ -n "$_login" ]] || { printf 'OK\n'; return 0; }
  _permission=$(JENKINS_LOGIN="$_login" GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
    "repos/$_repo_path/collaborators?affiliation=direct" --paginate --jq \
    '[.[] | select((.login | ascii_downcase) == (env.JENKINS_LOGIN | ascii_downcase)) |
      if (.permissions.push // false) then "push" else (.role_name // "none") end][0] // "none"') || return 2
  if [[ "$_expected" == allowed && "$_permission" == push ]] || \
     [[ "$_expected" != allowed && "$_permission" == none ]]; then
    printf 'OK\n'
  else
    printf 'DIFF\n'
  fi
}

_gh-repository-policy-teams-check() {
  # Porovná týmy repa s očekávaným stavem z conf.d. Výstup: OK / DIFF;
  # rc 1 při chybě API nebo konfigurace.
  # Použití: _gh-repository-policy-teams-check <repo_path> <projectKey>
  local _repo_path="$1" _key="$2" _expected_teams _observed_teams _team _permission
  local _teams_match=true
  local -A _observed_team_map=()
  _expected_teams=$(_gh-repository-policy-expected-teams "$_key") || return 1
  _observed_teams=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/teams" \
    --paginate --jq '.[] | [.slug, .permission] | @tsv' 2>/dev/null) || return 1
  while IFS=$'\t' read -r _team _permission; do
    [[ -n "$_team" ]] && _observed_team_map["$_team"]="$(_gh-perm-to-api "$_permission")"
  done <<< "$_observed_teams"
  while IFS=$'\t' read -r _team _permission; do
    [[ -z "$_team" ]] && continue
    [[ "${_observed_team_map[$_team]:-}" == "$_permission" ]] || _teams_match=false
  done <<< "$_expected_teams"
  if [[ "$_teams_match" == true ]]; then
    printf 'OK\n'
  else
    printf 'DIFF\n'
  fi
}

_gh-repository-policy-check() {
  # Check policy: týmy → rulesety (sémantické porovnání + smoke-test) →
  # Jenkins collaborator. Výsledek OK/DIFF/ERROR a detail přes nameref.
  # Použití: _gh-repository-policy-check <repo_path> <branch> <key> <result_name> <detail_name>
  local _repo_path="$1" _branch="$2" _key="$3" _result_name="$4" _detail_name="$5"
  local _login _configured _decision _teams _rulesets _collaborator
  declare -n _result_ref="$_result_name" _detail_ref="$_detail_name"
  _result_ref=ERROR; _detail_ref="policy check failed"
  _gh-jenkins-policy-resolve "$_key" _login _configured _decision || return 0
  _teams=$(_gh-repository-policy-teams-check "$_repo_path" "$_key") || return 0
  _rulesets=$(_gh-ruleset-check "$_repo_path" "$_branch" "$_key" "$_login") || return 0
  _collaborator=$(_gh-repository-policy-collaborator-check "$_repo_path" "$_login" "$_decision") || return 0

  _result_ref=OK; _detail_ref=-
  if [[ "$_teams" != OK ]]; then
    _result_ref=DIFF; _detail_ref="team permissions differ"
  elif [[ "$_rulesets" != OK ]]; then
    _result_ref=DIFF; _detail_ref="rulesets differ"
  elif [[ "$_collaborator" != OK ]]; then
    _result_ref=DIFF; _detail_ref="Jenkins collaborator differs"
  fi
}

_gh-repository-policy-live-admin-removal-safe() {
  local _repo_path="$1" _team="$2" _count
  _count=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/teams" --paginate \
    --jq "[.[] | select(.permission == \"admin\" and .slug != \"$_team\")] | length") || return 1
  [[ "$_count" =~ ^[1-9][0-9]*$ ]]
}

_gh-repository-policy-reconcile-teams() {
  local _repo_path="$1" _key="$2" _expected _observed _class _team _permission _old
  local -A _observed_map=()
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _expected=$(_gh-repository-policy-expected-teams "$_key") || return 1
  _observed=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/teams" \
    --paginate --jq '.[] | [.slug, .permission] | @tsv') || return 1
  while IFS=$'\t' read -r _team _permission; do
    [[ -n "$_team" ]] && _observed_map["$_team"]="$(_gh-perm-to-api "$_permission")"
  done <<< "$_observed"

  for _class in admin remaining; do
    while IFS=$'\t' read -r _team _permission; do
      [[ "$_class" == admin && "$_permission" != admin ]] && continue
      [[ "$_class" == remaining && "$_permission" == admin ]] && continue
      [[ "${_observed_map[$_team]:-}" == "$_permission" ]] && continue
      _old="${_observed_map[$_team]:-}"
      if [[ "$_old" == admin && "$_permission" != admin ]]; then
        _gh-repository-policy-live-admin-removal-safe "$_repo_path" "$_team" || return 1
      fi
      _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
        "orgs/$GITHUB_ORG/teams/$_team/repos/$_repo_path" --method PUT \
        --field "permission=$_permission" >/dev/null || return 1
    done <<< "$_expected"
  done
}

_gh-repository-policy-assign() {
  # Assign policy: payloady fail-fast → týmy → collaborator (před apply –
  # bypass neuděluje právo zápisu) → jediný ruleset apply s bypass seznamem
  # rovnou v payloadu. Argument <branch> zůstává kvůli rozhraní call sites
  # (rulesety cílí větve přes klíč branches profilů, ne parametrem).
  # Použití: _gh-repository-policy-assign <repo_path> <branch> <projectKey>
  local _repo_path="$1" _key="$3"
  local _login _configured _decision
  local -A _payloads=()
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-jenkins-policy-resolve "$_key" _login _configured _decision || return 1
  _gh-ruleset-payloads-build "$_key" "$_login" _payloads || return 1
  _gh-repository-policy-reconcile-teams "$_repo_path" "$_key" || return 1
  if [[ "$_decision" == allowed ]]; then
    _gh-jenkins-collaborator-add "$_repo_path" "$_key" "$_login" || return 1
    _gh-ruleset-apply "$_repo_path" "$_key" "$_login" || return 1
  else
    _gh-ruleset-apply "$_repo_path" "$_key" || return 1
  fi
}

_gh-repository-policy-remove() {
  # Remove policy: uklidí Jenkins collaboratora, když projekt Jenkinse
  # nepoužívá (bypass v rulesetu srovnává apply/orphan logika sama).
  # Argument <branch> zůstává kvůli rozhraní call sites.
  # Použití: _gh-repository-policy-remove <repo_path> <branch> <projectKey>
  local _repo_path="$1" _key="$3"
  local _login _configured _decision
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-jenkins-policy-resolve "$_key" _login _configured _decision || return 1
  if [[ "$_configured" == true && "$_decision" != allowed ]]; then
    _gh-jenkins-collaborator-remove "$_repo_path" "$_key" "$_login" || return 1
  fi
}

_gh-repository-policy-reconcile() {
  local _repo_path="$1" _branch="$2" _key="$3"
  _gh-repository-policy-assign "$_repo_path" "$_branch" "$_key" || return 1
  _gh-repository-policy-remove "$_repo_path" "$_branch" "$_key"
}

_gh-repository-policy-apply() {
  _gh-repository-policy-reconcile "$1" "$2" "$3"
}

_gh-teams-for-key() {
  # Vrátí hodnotu klíče repository_teams projektu z INI dat conf.d (_GH_CONF);
  # existenci projektu ověřuje přes _mhn_for_key.
  # Použití: _gh-teams-for-key <projectKey> <base_var pro chybovou hlášku>
  local _key="$1" _base_var="$2"
  if _mhn_for_key "$_key" >/dev/null && \
     [[ -n "${_GH_CONF[projects/$_key/repository_teams]:-}" ]]; then
    printf '%s\n' "${_GH_CONF[projects/$_key/repository_teams]}"
    return 0
  fi
  echo "Chyba: Konfigurace '${_base_var}' pro projectKey '$_key' nenalezena. Zkontroluj klíč repository_teams v conf.d/projects/$_key.conf." >&2
  return 1
}

_gh-validate-admin-team() {
  local _key="$1" _base_var="$2" _teams _entry _team _permission _has_admin=false
  local -a _entries
  _teams=$(_gh-teams-for-key "$_key" "$_base_var") || return 1

  IFS=',' read -ra _entries <<< "$_teams"
  for _entry in "${_entries[@]}"; do
    if [[ ! "$_entry" =~ ^[[:alnum:]][[:alnum:]_.-]*\|(pull|triage|push|maintain|admin|read|write)$ ]]; then
      echo "Chyba: Neplatny zaznam tymu '$_entry' v klici repository_teams projektu '$_key' (conf.d/projects/$_key.conf)." >&2
      echo "       Ocekavany format je team-slug|permission." >&2
      return 1
    fi
    _team="${_entry%%|*}"
    _permission="${_entry##*|}"
    [[ -n "$_team" && "$_permission" == admin ]] && _has_admin=true
  done

  [[ "$_has_admin" == true ]] && return 0

  echo "Chyba: V klíči repository_teams projektu '$_key' (conf.d/projects/$_key.conf) není žádný tým s admin oprávněním." >&2
  echo "       Repozitář nelze vytvořit – bez admin týmu by jeho smazání vyžadovalo JIRA požadavek." >&2
  echo "       Přidej admin tým do repository_teams (např. muj-tym|admin)." >&2
  return 1
}

_gh-perm-to-api() {
  case "$1" in
    write) echo "push" ;;
    read)  echo "pull" ;;
    *)     echo "$1" ;;
  esac
}
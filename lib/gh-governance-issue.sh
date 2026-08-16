#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Bezpečné parsování a autorizace issue pro workflows gov repa
# (new/archive/unarchive-repository; návrh plan-implementace-governance-poc.md,
# bod C). Tělo issue = řádky project_key=... a repo_name=... (titulek je jen
# pro lidi). Tělo se NIKDY neinterpoluje do run: bloku workflow – čte se
# výhradně z JSON eventu ($GITHUB_EVENT_PATH) přes jq; hodnoty se validují
# regexy před prvním použitím; žádný eval/source.
# Modul běží jen v GitHub Actions (jq je k dispozici; lokální omezení na
# builtiny se na něj nevztahuje).
# Závislosti: gh-common-defs.sh (_GH_CONF, _GH_GHNAME_REGEX, _require_vars),
# lib/gh-conf.sh (_GH_CONF_LOGIN_REGEX), lib/gh-governance-repo-ops.sh
# (_gh-governance-repo-name).
[[ -n "${_GH_GOVERNANCE_ISSUE_LOADED:-}" ]] && \
  declare -F _gh-governance-issue-parse >/dev/null && return 0
_GH_GOVERNANCE_ISSUE_LOADED=1

_GH_GOVERNANCE_PROJECT_KEY_REGEX='^[a-z0-9]{1,46}$'

_gh-governance-issue-parse() {
  # Naparsuje a zvaliduje issue event: naplní nameref asoc. pole klíči
  # number, login, project_key, gh_name, repo_name. Při odmítnutí naplní
  # reject=<typ> (bez citace obsahu issue) a vrátí 1; rc 2 = interní chyba.
  # Typy odmítnutí: invalid_login, unexpected_line, duplicate_key,
  # missing_key, invalid_project_key, invalid_repo_name, unknown_project.
  # Použití: local -A _p=(); _gh-governance-issue-parse <event_json_path> _p
  local _event_path="$1" _body _login _number _line _key _value _repo_name
  declare -n _parsed_ref="$2"
  _parsed_ref=([reject]="")
  if [[ ! -f "$_event_path" ]]; then
    echo "Chyba: Event soubor '$_event_path' neexistuje." >&2
    return 2
  fi
  _number=$(jq -r '.issue.number // empty' "$_event_path") || return 2
  _login=$(jq -r '.issue.user.login // empty' "$_event_path") || return 2
  _body=$(jq -r '.issue.body // empty' "$_event_path") || return 2
  if [[ ! "$_number" =~ ^[0-9]+$ ]]; then
    echo "Chyba: Event neobsahuje číslo issue." >&2
    return 2
  fi
  _parsed_ref[number]="$_number"
  if [[ ! "$_login" =~ $_GH_CONF_LOGIN_REGEX || "$_login" == *--* ]]; then
    _parsed_ref[reject]=invalid_login
    return 1
  fi
  _parsed_ref[login]="$_login"

  # Whitelist řádků: jen project_key= a repo_name=, každý právě jednou;
  # hodnoty extrahované bash string ops a validované regexem před použitím.
  while IFS= read -r _line; do
    _line="${_line%$'\r'}"
    [[ -z "$_line" ]] && continue
    case "$_line" in
      project_key=*|repo_name=*) ;;
      *) _parsed_ref[reject]=unexpected_line; return 1 ;;
    esac
    _key="${_line%%=*}"
    _value="${_line#*=}"
    if [[ -v _parsed_ref["body_$_key"] ]]; then
      _parsed_ref[reject]=duplicate_key
      return 1
    fi
    _parsed_ref["body_$_key"]="$_value"
  done <<< "$_body"

  if [[ -z "${_parsed_ref[body_project_key]:-}" || -z "${_parsed_ref[body_repo_name]:-}" ]]; then
    _parsed_ref[reject]=missing_key
    return 1
  fi
  if [[ ! "${_parsed_ref[body_project_key]}" =~ $_GH_GOVERNANCE_PROJECT_KEY_REGEX ]]; then
    _parsed_ref[reject]=invalid_project_key
    return 1
  fi
  if [[ ! "${_parsed_ref[body_repo_name]}" =~ $_GH_GHNAME_REGEX ]]; then
    _parsed_ref[reject]=invalid_repo_name
    return 1
  fi
  # Existence projektu proti načtenému _GH_CONF – checkout gov repa je autorita.
  if [[ -z "${_GH_CONF[projects/${_parsed_ref[body_project_key]}/business_service]:-}" ]]; then
    _parsed_ref[reject]=unknown_project
    return 1
  fi
  _repo_name=$(_gh-governance-repo-name "${_parsed_ref[body_project_key]}" \
    "${_parsed_ref[body_repo_name]}" 2>/dev/null) || {
    _parsed_ref[reject]=invalid_repo_name
    return 1
  }
  _parsed_ref[project_key]="${_parsed_ref[body_project_key]}"
  _parsed_ref[gh_name]="${_parsed_ref[body_repo_name]}"
  _parsed_ref[repo_name]="$_repo_name"
  return 0
}

_gh-governance-issue-authorize() {
  # Ověří, že login je aktivním členem některého týmu z CSV klíče projektu
  # (repository_creators / repository_archivers):
  # GET /orgs/{org}/teams/{slug}/memberships/{login}, 200 + state=active.
  # rc: 0 = povoleno, 1 = odmítnuto, 2 = chyba konfigurace.
  # Použití: _gh-governance-issue-authorize <login> <projectKey> <repository_creators|repository_archivers>
  local _login="$1" _key="$2" _field="$3" _rest _team _state
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME || return 2
  case "$_field" in
    repository_creators|repository_archivers) ;;
    *) echo "Chyba: Autorizační klíč musí být repository_creators nebo repository_archivers (je '$_field')." >&2
       return 2 ;;
  esac
  _rest="${_GH_CONF[projects/$_key/$_field]:-}"
  if [[ -z "$_rest" ]]; then
    echo "Chyba: Klíč '$_field' projektu '$_key' není v konfiguraci." >&2
    return 2
  fi
  _rest+=","
  while [[ "$_rest" == *,* ]]; do
    _team="${_rest%%,*}"
    _rest="${_rest#*,}"
    [[ -n "$_team" ]] || continue
    _state=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
      "orgs/$GITHUB_ORG/teams/$_team/memberships/$_login" \
      --jq '.state' 2>/dev/null) || continue
    [[ "$_state" == active ]] && return 0
  done
  return 1
}

_gh-governance-issue-reject-message() {
  # Vypíše lidsky čitelnou zprávu k typu odmítnutí (bez citace obsahu issue).
  # Použití: _gh-governance-issue-reject-message <typ>
  case "$1" in
    invalid_login)       echo "Login autora issue nemá platný formát." ;;
    unexpected_line)     echo "Tělo issue obsahuje neočekávaný řádek – povoleny jsou pouze řádky project_key=... a repo_name=..." ;;
    duplicate_key)       echo "Tělo issue obsahuje duplicitní klíč." ;;
    missing_key)         echo "V těle issue chybí povinný klíč project_key nebo repo_name." ;;
    invalid_project_key) echo "Hodnota project_key nemá platný formát." ;;
    invalid_repo_name)   echo "Hodnota repo_name nemá platný formát (viz formát ghName v defs/defs.md) nebo je výsledný název repa delší než 100 znaků." ;;
    unknown_project)     echo "Zadaný projekt v konfiguraci conf.d neexistuje." ;;
    unauthorized)        echo "Autor issue není aktivním členem žádného z oprávněných týmů projektu." ;;
    *)                   echo "Issue bylo odmítnuto (neznámý typ chyby '$1')." ;;
  esac
}

_gh-governance-issue-close-rejected() {
  # Okomentuje a zavře issue jako not_planned po odmítnutí (parse i autorizace).
  # Použití: _gh-governance-issue-close-rejected <issue_number> <typ>
  local _number="$1" _type="$2" _msg
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_GOVERNANCE_REPO || return 1
  _msg=$(_gh-governance-issue-reject-message "$_type")
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "$_number" \
    --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
    --body "Požadavek odmítnut: $_msg" >/dev/null || return 1
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue close "$_number" \
    --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
    --reason "not planned" >/dev/null
}

_gh-governance-issue-parse-step() {
  # Celý parse job workflow: naparsuje event ($GITHUB_EVENT_PATH), autorizuje
  # autora proti CSV týmů daného klíče projektu a zapíše výstupy do
  # $GITHUB_OUTPUT (result=ok + issue_number, project_key, gh_name, repo_name;
  # nebo result=rejected). Odmítnutí (parse i autorizace) okomentuje a zavře
  # issue not_planned a skončí úspěšně (rc 0); rc != 0 jen interní chyba.
  # Použití: _gh-governance-issue-parse-step <repository_creators|repository_archivers>
  local _field="$1" _out="${GITHUB_OUTPUT:-/dev/stdout}" _rc
  local -A _parsed=()
  if ! _gh-governance-issue-parse "${GITHUB_EVENT_PATH:?}" _parsed; then
    [[ -n "${_parsed[reject]}" ]] || return 1
    echo "Issue #${_parsed[number]} odmítnuto: ${_parsed[reject]}"
    _gh-governance-issue-close-rejected "${_parsed[number]}" "${_parsed[reject]}" || return 1
    echo "result=rejected" >> "$_out"
    return 0
  fi
  _gh-governance-issue-authorize "${_parsed[login]}" "${_parsed[project_key]}" "$_field"
  _rc=$?
  if [[ $_rc -eq 1 ]]; then
    echo "Issue #${_parsed[number]} odmítnuto: unauthorized"
    _gh-governance-issue-close-rejected "${_parsed[number]}" unauthorized || return 1
    echo "result=rejected" >> "$_out"
    return 0
  elif [[ $_rc -ne 0 ]]; then
    return 1
  fi
  {
    echo "result=ok"
    echo "issue_number=${_parsed[number]}"
    echo "project_key=${_parsed[project_key]}"
    echo "gh_name=${_parsed[gh_name]}"
    echo "repo_name=${_parsed[repo_name]}"
  } >> "$_out"
  echo "Issue #${_parsed[number]} přijato: projekt ${_parsed[project_key]}, repo ${_parsed[repo_name]}."
}

_gh-governance-issue-close-done() {
  # Okomentuje a zavře issue po úspěšném provedení operace.
  # Použití: _gh-governance-issue-close-done <issue_number> <komentář>
  local _number="$1" _comment="$2"
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_GOVERNANCE_REPO || return 1
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "$_number" \
    --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
    --body "$_comment" >/dev/null || return 1
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue close "$_number" \
    --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
    --reason completed >/dev/null
}

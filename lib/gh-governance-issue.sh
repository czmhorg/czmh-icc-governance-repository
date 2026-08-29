#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Bezpečné parsování a autorizace issue pro workflows gov repa
# (new/archive/unarchive-repository; návrh plan-implementace-governance-poc.md,
# bod C), move-repository (docs/implementovano/navrh/rozdeleni-projektu.md) a track-delete
# (defs/defs-governance-repo.md). Tělo issue = řádky project_key=... a
# repo_name=... (move-repo navíc new_project_key=... a volitelný
# redirect=keep; track-delete: repo_path=... a delete_issue=...); titulek je
# jen pro lidi. Tělo se NIKDY neinterpoluje do
# run: bloku workflow – čte se výhradně z JSON eventu ($GITHUB_EVENT_PATH)
# přes jq; hodnoty se validují regexy před prvním použitím; žádný eval/source.
# Modul běží jen v GitHub Actions (jq je k dispozici; lokální omezení na
# builtiny se na něj nevztahuje).
# Závislosti: gh-common-defs.sh (_GH_CONF, _GH_GHNAME_REGEX, _gh-match,
# _require_vars), lib/gh-conf.sh (_GH_CONF_LOGIN_REGEX),
# lib/gh-governance-repo-ops.sh (_gh-governance-repo-name).
[[ -n "${_GH_GOVERNANCE_ISSUE_LOADED:-}" ]] && \
  declare -F _gh-governance-issue-parse >/dev/null && return 0
_GH_GOVERNANCE_ISSUE_LOADED=1

_GH_GOVERNANCE_PROJECT_KEY_REGEX='^[a-z0-9]{1,46}$'

_gh-governance-issue-event-read() {
  # Interní: načte z issue eventu číslo, login autora a tělo do namerefů
  # a zvaliduje číslo issue (login validuje volající – zachází s odmítnutím
  # různě). rc 1 = chybějící event soubor nebo nevalidní číslo issue.
  # Použití: _gh-governance-issue-event-read <event_json_path> <num_ref> <login_ref> <body_ref>
  local _event_path="$1"
  declare -n _ev_num_ref="$2" _ev_login_ref="$3" _ev_body_ref="$4"
  if [[ ! -f "$_event_path" ]]; then
    echo "Chyba: Event soubor '$_event_path' neexistuje." >&2
    return 1
  fi
  _ev_num_ref=$(jq -r '.issue.number // empty' "$_event_path") || return 1
  _ev_login_ref=$(jq -r '.issue.user.login // empty' "$_event_path") || return 1
  _ev_body_ref=$(jq -r '.issue.body // empty' "$_event_path") || return 1
  if [[ ! "$_ev_num_ref" =~ ^[0-9]+$ ]]; then
    echo "Chyba: Event neobsahuje číslo issue." >&2
    return 1
  fi
  return 0
}

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
  _gh-governance-issue-event-read "$_event_path" _number _login _body || return 2
  _parsed_ref[number]="$_number"
  if ! _gh-match "$_login" "$_GH_CONF_LOGIN_REGEX" || [[ "$_login" == *--* ]]; then
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
  if ! _gh-match "${_parsed_ref[body_project_key]}" "$_GH_GOVERNANCE_PROJECT_KEY_REGEX"; then
    _parsed_ref[reject]=invalid_project_key
    return 1
  fi
  if ! _gh-match "${_parsed_ref[body_repo_name]}" "$_GH_GHNAME_REGEX"; then
    _parsed_ref[reject]=invalid_repo_name
    return 1
  fi
  # Existence projektu proti načtenému _GH_CONF – checkout gov repa je autorita.
  if [[ -z "${_GH_CONF[projects/${_parsed_ref[body_project_key]}/domain]:-}" ]]; then
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

_gh-governance-track-delete-body-parse() {
  # Naparsuje a zvaliduje tělo track-delete issue (sdílené jádro pro parse
  # job workflow i reconcile sweep): řádky repo_path=<org>/<ghRepoName> a
  # delete_issue=<URL>, každý právě jednou. repo_path se rozkládá na
  # projectKey a ghName (validace formátů); existence projektu v conf.d se
  # nevyžaduje – úklid po zaniklém repu smí proběhnout i pro zrušený projekt.
  # delete_issue je jen informační (do komentářů), nikdy se nenásleduje.
  # Naplní nameref klíči project_key, gh_name, repo_name, delete_issue;
  # při odmítnutí reject=<typ> a rc 1. Typy odmítnutí: unexpected_line,
  # duplicate_key, missing_key, invalid_repo_path, invalid_delete_issue.
  # Použití: local -A _p=(); _gh-governance-track-delete-body-parse <body> _p
  local _body="$1" _line _field _value _name _rest _pkey _gname _repo_name
  local _url_regex='^https://[A-Za-z0-9.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+$'
  declare -n _td_ref="$2"
  _td_ref=([reject]="")
  while IFS= read -r _line; do
    _line="${_line%$'\r'}"
    [[ -z "$_line" ]] && continue
    case "$_line" in
      repo_path=*|delete_issue=*) ;;
      *) _td_ref[reject]=unexpected_line; return 1 ;;
    esac
    _field="${_line%%=*}"
    _value="${_line#*=}"
    if [[ -v _td_ref["body_$_field"] ]]; then
      _td_ref[reject]=duplicate_key
      return 1
    fi
    _td_ref["body_$_field"]="$_value"
  done <<< "$_body"

  if [[ -z "${_td_ref[body_repo_path]:-}" || -z "${_td_ref[body_delete_issue]:-}" ]]; then
    _td_ref[reject]=missing_key
    return 1
  fi
  # repo_path = <GITHUB_ORG>/<GH_REPO_PREFIX>-<projectKey>-<ghName>; klíč
  # neobsahuje pomlčku (defs/defs.md), rozklad je tedy jednoznačný.
  _name="${_td_ref[body_repo_path]#"${GITHUB_ORG}/"}"
  _rest="${_name#"${GH_REPO_PREFIX}-"}"
  if [[ "$_name" == "${_td_ref[body_repo_path]}" || "$_rest" == "$_name" \
        || "$_rest" != *-* ]]; then
    _td_ref[reject]=invalid_repo_path
    return 1
  fi
  _pkey="${_rest%%-*}"
  _gname="${_rest#*-}"
  if ! _gh-match "$_pkey" "$_GH_GOVERNANCE_PROJECT_KEY_REGEX"; then
    _td_ref[reject]=invalid_repo_path
    return 1
  fi
  _repo_name=$(_gh-governance-repo-name "$_pkey" "$_gname" 2>/dev/null) || {
    _td_ref[reject]=invalid_repo_path
    return 1
  }
  if ! _gh-match "${_td_ref[body_delete_issue]}" "$_url_regex"; then
    _td_ref[reject]=invalid_delete_issue
    return 1
  fi
  _td_ref[project_key]="$_pkey"
  _td_ref[gh_name]="$_gname"
  _td_ref[repo_name]="$_repo_name"
  _td_ref[delete_issue]="${_td_ref[body_delete_issue]}"
  return 0
}

_gh-governance-issue-parse-step-track-delete() {
  # Celý parse job workflow track-delete: naparsuje event ($GITHUB_EVENT_PATH)
  # a zapíše výstupy do $GITHUB_OUTPUT (result=ok + issue_number, project_key,
  # gh_name, repo_name; nebo result=rejected). Bez týmové autorizace autora –
  # workflow nic na GitHubu nemaže, jen po prokázaném 404 uklízí vlastní
  # artefakty (viz defs/defs-governance-repo.md). Odmítnutí okomentuje a zavře
  # issue not_planned a skončí úspěšně (rc 0); rc != 0 jen interní chyba.
  # Použití: _gh-governance-issue-parse-step-track-delete
  local _out="${GITHUB_OUTPUT:-/dev/stdout}" _event_path="${GITHUB_EVENT_PATH:?}"
  local _number _login _body
  local -A _td=()
  _gh-governance-issue-event-read "$_event_path" _number _login _body || return 1
  if ! _gh-match "$_login" "$_GH_CONF_LOGIN_REGEX" || [[ "$_login" == *--* ]]; then
    echo "Issue #$_number odmítnuto: invalid_login"
    _gh-governance-issue-close-rejected "$_number" invalid_login || return 1
    echo "result=rejected" >> "$_out"
    return 0
  fi
  if ! _gh-governance-track-delete-body-parse "$_body" _td; then
    [[ -n "${_td[reject]}" ]] || return 1
    echo "Issue #$_number odmítnuto: ${_td[reject]}"
    _gh-governance-issue-close-rejected "$_number" "${_td[reject]}" || return 1
    echo "result=rejected" >> "$_out"
    return 0
  fi
  {
    echo "result=ok"
    echo "issue_number=$_number"
    echo "project_key=${_td[project_key]}"
    echo "gh_name=${_td[gh_name]}"
    echo "repo_name=${_td[repo_name]}"
  } >> "$_out"
  echo "Issue #$_number přijato: sledování zániku repa ${_td[repo_name]}."
}

_gh-governance-move-body-parse() {
  # Naparsuje a zvaliduje tělo move-repo issue (přesun repa mezi projekty,
  # docs/implementovano/navrh/rozdeleni-projektu.md): řádky project_key=, repo_name= a
  # new_project_key=, každý právě jednou, plus volitelný redirect=keep
  # (jiná hodnota = odmítnutí). Naplní nameref klíči project_key, gh_name,
  # repo_name, new_project_key, new_repo_name, redirect (keep|cancel);
  # při odmítnutí reject=<typ> a rc 1. Typy odmítnutí: unexpected_line,
  # duplicate_key, missing_key, invalid_project_key, invalid_repo_name,
  # unknown_project, same_project, invalid_redirect.
  # Použití: local -A _p=(); _gh-governance-move-body-parse <body> _p
  local _body="$1" _line _field _value _k
  declare -n _mv_ref="$2"
  _mv_ref=([reject]="")
  while IFS= read -r _line; do
    _line="${_line%$'\r'}"
    [[ -z "$_line" ]] && continue
    case "$_line" in
      project_key=*|repo_name=*|new_project_key=*|redirect=*) ;;
      *) _mv_ref[reject]=unexpected_line; return 1 ;;
    esac
    _field="${_line%%=*}"
    _value="${_line#*=}"
    if [[ -v _mv_ref["body_$_field"] ]]; then
      _mv_ref[reject]=duplicate_key
      return 1
    fi
    _mv_ref["body_$_field"]="$_value"
  done <<< "$_body"

  if [[ -z "${_mv_ref[body_project_key]:-}" || -z "${_mv_ref[body_repo_name]:-}" \
        || -z "${_mv_ref[body_new_project_key]:-}" ]]; then
    _mv_ref[reject]=missing_key
    return 1
  fi
  for _k in "${_mv_ref[body_project_key]}" "${_mv_ref[body_new_project_key]}"; do
    if ! _gh-match "$_k" "$_GH_GOVERNANCE_PROJECT_KEY_REGEX"; then
      _mv_ref[reject]=invalid_project_key
      return 1
    fi
    if [[ -z "${_GH_CONF[projects/$_k/domain]:-}" ]]; then
      _mv_ref[reject]=unknown_project
      return 1
    fi
  done
  if [[ "${_mv_ref[body_project_key]}" == "${_mv_ref[body_new_project_key]}" ]]; then
    _mv_ref[reject]=same_project
    return 1
  fi
  if ! _gh-match "${_mv_ref[body_repo_name]}" "$_GH_GHNAME_REGEX"; then
    _mv_ref[reject]=invalid_repo_name
    return 1
  fi
  case "${_mv_ref[body_redirect]:-}" in
    ""|keep) ;;
    *) _mv_ref[reject]=invalid_redirect; return 1 ;;
  esac
  # Délku validuje _gh-governance-repo-name pro obě jména (delší cílový
  # klíč může prolomit limit 100 znaků).
  _mv_ref[repo_name]=$(_gh-governance-repo-name "${_mv_ref[body_project_key]}" \
    "${_mv_ref[body_repo_name]}" 2>/dev/null) || {
    _mv_ref[reject]=invalid_repo_name
    return 1
  }
  _mv_ref[new_repo_name]=$(_gh-governance-repo-name "${_mv_ref[body_new_project_key]}" \
    "${_mv_ref[body_repo_name]}" 2>/dev/null) || {
    _mv_ref[reject]=invalid_repo_name
    return 1
  }
  _mv_ref[project_key]="${_mv_ref[body_project_key]}"
  _mv_ref[gh_name]="${_mv_ref[body_repo_name]}"
  _mv_ref[new_project_key]="${_mv_ref[body_new_project_key]}"
  _mv_ref[redirect]=cancel
  [[ "${_mv_ref[body_redirect]:-}" == keep ]] && _mv_ref[redirect]=keep
  return 0
}

_gh-governance-issue-parse-step-move() {
  # Celý parse job workflow move-repository: naparsuje event
  # ($GITHUB_EVENT_PATH) a autorizuje autora DVAKRÁT – členství v týmu
  # z repository_archivers zdrojového projektu A ZÁROVEŇ z
  # repository_creators cílového projektu (zápůjčka oprávnění, návrh
  # rozdeleni-projektu.md). Výstupy do $GITHUB_OUTPUT: result=ok +
  # issue_number, project_key, gh_name, repo_name, new_project_key,
  # new_repo_name, redirect (keep|cancel); nebo result=rejected. Odmítnutí
  # okomentuje a zavře issue not_planned a skončí rc 0; rc != 0 jen interní
  # chyba.
  # Použití: _gh-governance-issue-parse-step-move
  local _out="${GITHUB_OUTPUT:-/dev/stdout}" _number _login _body _rc _pair _key _field
  local -A _mv=()
  _gh-governance-issue-event-read "${GITHUB_EVENT_PATH:?}" _number _login _body || return 1
  if ! _gh-match "$_login" "$_GH_CONF_LOGIN_REGEX" || [[ "$_login" == *--* ]]; then
    echo "Issue #$_number odmítnuto: invalid_login"
    _gh-governance-issue-close-rejected "$_number" invalid_login || return 1
    echo "result=rejected" >> "$_out"
    return 0
  fi
  if ! _gh-governance-move-body-parse "$_body" _mv; then
    [[ -n "${_mv[reject]}" ]] || return 1
    echo "Issue #$_number odmítnuto: ${_mv[reject]}"
    _gh-governance-issue-close-rejected "$_number" "${_mv[reject]}" || return 1
    echo "result=rejected" >> "$_out"
    return 0
  fi
  for _pair in "${_mv[project_key]}:repository_archivers" \
               "${_mv[new_project_key]}:repository_creators"; do
    _key="${_pair%%:*}"
    _field="${_pair#*:}"
    _gh-governance-issue-authorize "$_login" "$_key" "$_field"
    _rc=$?
    if [[ $_rc -eq 1 ]]; then
      echo "Issue #$_number odmítnuto: unauthorized ($_field projektu $_key)"
      _gh-governance-issue-close-rejected "$_number" unauthorized || return 1
      echo "result=rejected" >> "$_out"
      return 0
    elif [[ $_rc -ne 0 ]]; then
      return 1
    fi
  done
  {
    echo "result=ok"
    echo "issue_number=$_number"
    echo "project_key=${_mv[project_key]}"
    echo "gh_name=${_mv[gh_name]}"
    echo "repo_name=${_mv[repo_name]}"
    echo "new_project_key=${_mv[new_project_key]}"
    echo "new_repo_name=${_mv[new_repo_name]}"
    echo "redirect=${_mv[redirect]}"
  } >> "$_out"
  echo "Issue #$_number přijato: přesun ${_mv[repo_name]} → ${_mv[new_repo_name]} (redirect: ${_mv[redirect]})."
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
    unexpected_line)     echo "Tělo issue obsahuje neočekávaný řádek – povoleny jsou pouze řádky klíčů daného typu issue (project_key= a repo_name=; u move-repo navíc new_project_key= a volitelný redirect=; u track-delete repo_path= a delete_issue=)." ;;
    duplicate_key)       echo "Tělo issue obsahuje duplicitní klíč." ;;
    missing_key)         echo "V těle issue chybí povinný klíč (project_key, repo_name; u move-repo i new_project_key)." ;;
    invalid_project_key) echo "Hodnota project_key nemá platný formát." ;;
    invalid_repo_name)   echo "Hodnota repo_name nemá platný formát (viz formát ghName v defs/defs.md) nebo je výsledný název repa delší než 100 znaků." ;;
    unknown_project)     echo "Zadaný projekt v konfiguraci conf.d neexistuje." ;;
    invalid_repo_path)   echo "Hodnota repo_path nemá platný formát <org>/<ghRepoName> spravovaného repa (viz defs/defs.md)." ;;
    invalid_delete_issue) echo "Hodnota delete_issue není platná URL issue." ;;
    same_project)        echo "Zdrojový a cílový projekt přesunu jsou shodné." ;;
    invalid_redirect)    echo "Hodnota redirect smí být pouze 'keep' (ponechat redirect starého jména); bez řádku redirect= se redirect ruší." ;;
    not_managed)         echo "Repo není spravovaným repem zdrojového projektu (nebo je stav přesunu nejednoznačný – viz log běhu workflow a defs/defs.md)." ;;
    name_taken)          echo "Nové jméno repa v cílovém projektu je už obsazené." ;;
    capacity_exceeded)   echo "Cílový projekt je v příslušné podmnožině (archivovaná/nearchivovaná repa) na limitu axiomu Kapacita projektu – přesun by ho porušil." ;;
    unauthorized)        echo "Autor issue není aktivním členem žádného z oprávněných týmů projektu (přesun vyžaduje repository_archivers zdrojového a repository_creators cílového projektu)." ;;
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

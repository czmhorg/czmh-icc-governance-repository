#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Správa spravovaného webhooku spravovaných rep podle klíčů webhook_url
# a webhook_events (defs/defs.md: webhook repa; docs/implementovano/navrh/webhooky-rep.md).
# Hook identifikuje přesná shoda config.url s efektivní webhook_url: chybí →
# POST, liší se → PATCH, stará URL dle diffu ukazatele → DELETE; ručně
# založené hooky (jiná URL) se jen hlásí. Po založení hooku se pošle ping
# a výsledek doručení jde do detailu položky (jen informace, ne drift).
# Rozhodovací logika je v čistých funkcích (offline testy), zápisy jdou přes
# helpery lib/gh-repository-policy.sh (_gh-api-input-retry,
# _gh-api-delete-404ok). Záměrně mimo _gh-repository-policy-*: policy apply
# volá i migrace bb-migrate a repo v migraci hook mít nesmí.
# Volají ji: denní reconcile (hlavní smyčka), workflow repo-sync
# (lib/gh-governance-repo-sync.sh — jeden projekt) a workflow životního
# cyklu repa (_gh-governance-webhook-apply-note — jedno repo, výsledek jako
# řádek komentáře issue).
# Závislosti: gh-common-defs.sh (_require_vars, GH_REPO_PREFIX, topic
# migrace, GH_WEBHOOK_EVENTS_DEFAULT), lib/gh-conf.sh (_gh-conf-webhook),
# lib/gh-repository-policy.sh (API helpery), lib/gh-governance-report.sh,
# lib/gh-governance-state.sh (_gh-governance-run-sha,
# _gh-governance-webhook-url-to-remove, _gh-governance-conf-effective-at-commit).
[[ -n "${_GH_GOVERNANCE_WEBHOOKS_LOADED:-}" ]] && \
  declare -F _gh-governance-reconcile-webhook >/dev/null && return 0
_GH_GOVERNANCE_WEBHOOKS_LOADED=1

# Pevné vlastnosti spravovaného hooku (defs/defs.md: nekonfigurují se).
_GH_GOVERNANCE_WEBHOOK_CONTENT_TYPE=json
_GH_GOVERNANCE_WEBHOOK_INSECURE_SSL=0
# Čekání na výsledek pingu (doručení je asynchronní): pokusů × sekund.
_GH_GOVERNANCE_WEBHOOK_PING_ATTEMPTS=5
_GH_GOVERNANCE_WEBHOOK_PING_SLEEP_S=2

_gh-governance-webhook-events-normalize() {
  # Naplní nameref CSV událostí bez duplicit, seřazeným LC_ALL=C — stejné
  # pořadí jako jq `sort` v listingu hooků, aby šlo porovnat řetězce.
  # Použití: _gh-governance-webhook-events-normalize <csv> <nameref>
  declare -n _en_ref="$2"
  _en_ref=$(tr ',' '\n' <<< "$1" | grep -v '^$' | LC_ALL=C sort -u | paste -sd ',' -)
}

_gh-governance-webhook-payload() {
  # Sestaví JSON payload hooku (POST i PATCH) z URL a CSV událostí – offline.
  # V URL escapuje uvozovky a zpětná lomítka (mezery vylučuje parser).
  # Použití: _gh-governance-webhook-payload <url> <eventsCSV>
  local _url="$1" _rest="$2," _item _events=""
  _url="${_url//\\/\\\\}"; _url="${_url//\"/\\\"}"
  while [[ -n "$_rest" ]]; do
    _item="${_rest%%,*}"
    _rest="${_rest#*,}"
    [[ -n "$_item" ]] && _events+="${_events:+, }\"$_item\""
  done
  printf '{ "name": "web", "active": true, "events": [%s], "config": { "url": "%s", "content_type": "%s", "insecure_ssl": "%s" } }' \
    "$_events" "$_url" "$_GH_GOVERNANCE_WEBHOOK_CONTENT_TYPE" "$_GH_GOVERNANCE_WEBHOOK_INSECURE_SSL"
}

_gh-governance-webhook-list() {
  # Vypíše hooky repa po řádcích "<id>\t<url>\t<active>\t<content_type>\t<insecure_ssl>\t<eventsCSV>"
  # (události seřazené jq sort = codepoint pořadí). Jeden GET s --paginate.
  # Použití: _gh-governance-webhook-list <repo_path>
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$1/hooks?per_page=100" --paginate \
    --jq '.[] | [(.id | tostring), (.config.url // ""), (.active | tostring), (.config.content_type // ""), ((.config.insecure_ssl // "0") | tostring), ((.events // []) | sort | join(","))] | @tsv'
}

_gh-governance-webhook-plan() {
  # Rozhodne akce nad hooky repa. Čistá funkce; vypíše po řádcích:
  #   delete\t<id>\t<old_url>   – hook staré URL (diff ukazatele / přesun),
  #   update\t<id>\t<co se liší> – spravovaný hook (URL = <url>) s odchylkou,
  #   create\t<url>             – spravovaný hook chybí,
  #   extra\t<id>\t<url>        – hook s jinou URL (jen když <url> neprázdná).
  # Shoda = žádný řádek. Prázdná <url> (repo bez klíče / none) = jen delete
  # starých URL. <old_urls> = staré URL po řádcích (může být víc – historie
  # mezi ukazatelem a HEAD); prázdné nebo shodné s <url> = nic se nemaže.
  # Použití: _gh-governance-webhook-plan <listingTSV> <url> <eventsCSV> <old_urls>
  local _listing="$1" _url="$2" _events="$3" _old_urls="$4"
  local _id _hurl _active _ct _ssl _hev _found=0 _diff _want="" _old
  local -A _old_set=()
  [[ -n "$_url" ]] && _gh-governance-webhook-events-normalize "$_events" _want
  while IFS= read -r _old; do
    [[ -n "$_old" && "$_old" != "$_url" ]] && _old_set["$_old"]=1
  done <<< "$_old_urls"
  while IFS=$'\t' read -r _id _hurl _active _ct _ssl _hev; do
    [[ -n "$_id" ]] || continue
    if [[ -n "$_hurl" && -v _old_set["$_hurl"] ]]; then
      printf 'delete\t%s\t%s\n' "$_id" "$_hurl"
    elif [[ -n "$_url" && "$_hurl" == "$_url" ]]; then
      _found=1
      _diff=""
      [[ "$_active" == true ]] || _diff+="${_diff:+; }neaktivní → aktivní"
      [[ "$_hev" == "$_want" ]] || _diff+="${_diff:+; }události: ${_hev:-žádné} → $_want"
      [[ "$_ct" == "$_GH_GOVERNANCE_WEBHOOK_CONTENT_TYPE" ]] || \
        _diff+="${_diff:+; }content type: ${_ct:-žádný} → $_GH_GOVERNANCE_WEBHOOK_CONTENT_TYPE"
      [[ "$_ssl" == "$_GH_GOVERNANCE_WEBHOOK_INSECURE_SSL" ]] || \
        _diff+="${_diff:+; }insecure_ssl: $_ssl → $_GH_GOVERNANCE_WEBHOOK_INSECURE_SSL"
      [[ -z "$_diff" ]] || printf 'update\t%s\t%s\n' "$_id" "$_diff"
    elif [[ -n "$_url" ]]; then
      printf 'extra\t%s\t%s\n' "$_id" "$_hurl"
    fi
  done <<< "$_listing"
  [[ -z "$_url" || $_found -eq 1 ]] || printf 'create\t%s\n' "$_url"
  return 0
}

_gh-governance-webhook-create() {
  # Založí hook (POST) a vypíše jeho id. Bez retry: odmítnutí (HTTP 422 –
  # neznámá událost, nevalidní URL) je definitivní, selhání hlásí volající
  # jako error repa a dorovná příští reconcile.
  # Použití: _gh-governance-webhook-create <repo_path> <payload>
  local _repo_path="$1" _payload="$2" _id _err_file _err
  _err_file=$(mktemp) || return 1
  if _id=$(printf '%s' "$_payload" | GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
      "repos/$_repo_path/hooks" --method POST \
      --header "Accept: application/vnd.github+json" --input - --jq '.id' \
      2>"$_err_file"); then
    rm -f "$_err_file"
    if [[ ! "$_id" =~ ^[0-9]+$ ]]; then
      echo "Chyba: Neočekávané id webhooku repa '$_repo_path': '$_id'." >&2
      return 1
    fi
    printf '%s\n' "$_id"
    return 0
  fi
  _err=$(< "$_err_file")
  rm -f "$_err_file"
  [[ -n "$_err" ]] && printf '%s\n' "$_err" >&2
  echo "Chyba: Založení webhooku repa '$_repo_path' selhalo." >&2
  return 1
}

_gh-governance-webhook-update() {
  # Upraví hook (PATCH, celá config + events) s retry na přechodné chyby.
  # Použití: _gh-governance-webhook-update <repo_path> <id> <payload>
  _gh-api-input-retry "repos/$1/hooks/$2" PATCH "$3" "webhooku repa '$1'"
}

_gh-governance-webhook-delete() {
  # Smaže hook (404-tolerantně – mizející hook není chyba).
  # Použití: _gh-governance-webhook-delete <repo_path> <id>
  _gh-api-delete-404ok "repos/$1/hooks/$2"
}

_gh-governance-webhook-ping() {
  # Pošle ping hooku a naplní nameref výsledkem doručení z last_response:
  # `ping: HTTP <kód>`, `ping: <status> (<zpráva>)` (doručení selhalo),
  # `ping: bez odpovědi (timeout)` (do limitu nic), `ping: odeslání selhalo`.
  # Doručení je asynchronní – čeká se po pokusech; jen informace, rc vždy 0.
  # Použití: _gh-governance-webhook-ping <repo_path> <id> <nameref>
  declare -n _wp_ref="$3"
  local _repo_path="$1" _id="$2" _attempt _row _code _status _message
  _wp_ref="ping: bez odpovědi (timeout)"
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/hooks/$_id/pings" \
      --method POST >/dev/null 2>&1 || {
    _wp_ref="ping: odeslání selhalo"
    return 0
  }
  for (( _attempt = 1; _attempt <= _GH_GOVERNANCE_WEBHOOK_PING_ATTEMPTS; _attempt++ )); do
    sleep "$_GH_GOVERNANCE_WEBHOOK_PING_SLEEP_S"
    # Prázdná pole nesou "-" – read s IFS tab by prázdné první pole spolkl.
    _row=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/hooks/$_id" \
      --jq '[((.last_response.code // "-") | tostring), (.last_response.status // "-"), (.last_response.message // "")] | @tsv' \
      2>/dev/null) || continue
    IFS=$'\t' read -r _code _status _message <<< "$_row"
    if [[ "$_code" =~ ^[0-9]+$ ]]; then
      _wp_ref="ping: HTTP $_code"
      return 0
    elif [[ "$_status" != - && "$_status" != unused ]]; then
      _wp_ref="ping: $_status${_message:+ ($_message)}"
      return 0
    fi
  done
  return 0
}

_gh-governance-webhook-conf-unchanged() {
  # rc 0 ⇔ efektivní webhook_url i webhook_events repa na SHA ukazatele jsou
  # shodné s aktuálními <url> <events> – heuristika „ruční zásah do hooku"
  # (warning) vs. „legitimní změna conf.d" (info). Prázdné SHA nebo chyba
  # čtení = neprokázáno (rc 1 → info).
  # Použití: _gh-governance-webhook-conf-unchanged <sha> <key> <ghName> <url> <events>
  local _old_url="" _old_events="" _want=""
  [[ -n "$1" ]] || return 1
  _gh-governance-conf-effective-at-commit "$1" "$2" "$3" webhook_url _old_url 2>/dev/null || return 1
  [[ "$_old_url" == "$4" ]] || return 1
  _gh-governance-conf-effective-at-commit "$1" "$2" "$3" webhook_events _old_events 2>/dev/null || return 1
  [[ -n "$_old_events" ]] || _old_events="${GH_WEBHOOK_EVENTS_DEFAULT:-push}"
  _gh-governance-webhook-events-normalize "$_old_events" _old_events
  _gh-governance-webhook-events-normalize "$5" _want
  [[ "$_old_events" == "$_want" ]]
}

_gh-governance-reconcile-webhook() {
  # Správa webhooku jednoho spravovaného nearchivovaného repa dle efektivní
  # webhook_url/webhook_events (defs/defs.md, webhook repa). Repo s topicem
  # migrace se přeskakuje celé (hook až po uzavření migrace). Staré URL
  # k odebrání: <old_url> od volajícího (přesun/přejmenování repa), jinak
  # všechny efektivní URL z historie konfigurace ukazatel <pointer_sha> →
  # RUN_SHA (_gh-governance-webhook-urls-to-remove). Bez efektivní URL a bez
  # staré URL = 0 API volání (projekt bez klíče). Položky reportu: sprava
  # webhooku (info), rucni zasah do webhooku (warning – hook se lišil,
  # konfigurace od ukazatele beze změny), webhook prirazeny navic (warning).
  # Ping jen po založení. rc != 0 → volající hlásí error a pokračuje dalším repem.
  # Použití: _gh-governance-reconcile-webhook <repoName> <projectKey>
  #          <topicsCSV> <pointer_sha|''> [old_url]
  local _name="$1" _key="$2" _topics="$3" _pointer_sha="$4" _old_urls="${5:-}"
  local _gh_name="${_name#"${GH_REPO_PREFIX}-${_key}-"}"
  local _repo_path="${GITHUB_ORG}/${_name}" _url="" _events="" _source=""
  local _run_sha _listing _plan _action _a2 _a3 _payload _id _ping
  local -a _old_list=()
  [[ ",$_topics," == *",${_BB_MIGRATION_TOPIC_MARKER},"* ]] && return 0
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX || return 1
  _gh-conf-webhook "$_key" "$_gh_name" _url _events _source
  if [[ -z "$_old_urls" && -n "$_pointer_sha" ]]; then
    _run_sha=$(_gh-governance-run-sha) || return 1
    _gh-governance-webhook-urls-to-remove "$_key" "$_gh_name" "$_pointer_sha" "$_run_sha" _old_list \
      || return 1
    [[ ${#_old_list[@]} -eq 0 ]] || _old_urls=$(printf '%s\n' "${_old_list[@]}")
  fi
  [[ -n "$_url" || -n "$_old_urls" ]] || return 0
  _listing=$(_gh-governance-webhook-list "$_repo_path") || return 1
  _plan=$(_gh-governance-webhook-plan "$_listing" "$_url" "$_events" "$_old_urls")
  [[ -n "$_plan" ]] || return 0
  _payload=""
  [[ -z "$_url" ]] || _payload=$(_gh-governance-webhook-payload "$_url" "$_events")
  while IFS=$'\t' read -r _action _a2 _a3; do
    case "$_action" in
      delete)
        _gh-governance-webhook-delete "$_repo_path" "$_a2" || return 1
        _gh-governance-report-add info "sprava webhooku" "$_repo_path" \
          "webhook odebrán $_a3 dle diffu konfigurace" ;;
      create)
        _id=$(_gh-governance-webhook-create "$_repo_path" "$_payload") || return 1
        _gh-governance-webhook-ping "$_repo_path" "$_id" _ping
        _gh-governance-report-add info "sprava webhooku" "$_repo_path" \
          "webhook založen $_url (události: $_events; $_ping)" ;;
      update)
        _gh-governance-webhook-update "$_repo_path" "$_a2" "$_payload" || return 1
        if _gh-governance-webhook-conf-unchanged "$_pointer_sha" "$_key" "$_gh_name" "$_url" "$_events"; then
          _gh-governance-report-add warning "rucni zasah do webhooku" "$_repo_path" \
            "webhook $_url: $_a3 — v GH změněno ručně, vráceno dle conf.d"
        else
          _gh-governance-report-add info "sprava webhooku" "$_repo_path" \
            "webhook upraven $_url: $_a3"
        fi ;;
      extra)
        _gh-governance-report-add warning "webhook prirazeny navic" "$_repo_path" \
          "hook $_a3 (id $_a2)" ;;
    esac
  done <<< "$_plan"
  return 0
}

_gh-governance-webhook-apply-note() {
  # Správa webhooku jednoho repa ve workflow životního cyklu (new/unarchive/
  # move/rename): volá _gh-governance-reconcile-webhook nad dočasným reportem
  # a jeho položky vrátí jako řádky poznámky do komentáře issue
  # (`Webhook: <typ> – <detail>`). Poznámka je vždy neprázdná: repo v migraci
  # → `vynecháno (repo v migraci)`, nula položek → `beze změny`, rc != 0 →
  # `zápis selhal – <poslední řádek stderr>; dorovná denní reconcile` (stderr
  # projde dál do logu). Selhání operaci neshodí — rc vždy 0. Předchozí
  # _GH_GOVERNANCE_REPORT_FILE volajícího se obnoví. Vzor:
  # _gh-governance-codeowners-apply-note.
  # Použití: _gh-governance-webhook-apply-note <repoName> <projectKey>
  #          <topicsCSV> <pointer_sha|''> <note_ref> [old_url]
  declare -n _wn_ref="$5"
  local _wn_prev_set=0 _wn_prev="" _wn_tmp _wn_err _wn_rc=0 _wn_n=0
  local _wn_level _wn_type _wn_repo _wn_detail
  _wn_ref=""
  if [[ ",$3," == *",${_BB_MIGRATION_TOPIC_MARKER},"* ]]; then
    _wn_ref="Webhook: vynecháno (repo v migraci)"
    return 0
  fi
  if [[ -v _GH_GOVERNANCE_REPORT_FILE ]]; then
    _wn_prev_set=1
    _wn_prev="$_GH_GOVERNANCE_REPORT_FILE"
  fi
  if ! _wn_tmp=$(mktemp) || ! _wn_err=$(mktemp); then
    _wn_ref="Webhook: zápis selhal – mktemp selhal; dorovná denní reconcile"
    return 0
  fi
  _gh-governance-report-init "$_wn_tmp"
  _gh-governance-reconcile-webhook "$1" "$2" "$3" "$4" "${6:-}" 2>"$_wn_err" || _wn_rc=$?
  if [[ $_wn_prev_set -eq 1 ]]; then
    _GH_GOVERNANCE_REPORT_FILE="$_wn_prev"
  else
    unset _GH_GOVERNANCE_REPORT_FILE
  fi
  [[ -s "$_wn_err" ]] && cat "$_wn_err" >&2
  while IFS=$'\t' read -r _wn_level _wn_type _wn_repo _wn_detail; do
    [[ -n "$_wn_level" ]] || continue
    _wn_ref+="${_wn_ref:+$'\n'}Webhook: ${_wn_type} – ${_wn_detail}"
    _wn_n=$(( _wn_n + 1 ))
  done < "$_wn_tmp"
  if [[ $_wn_rc -ne 0 ]]; then
    _wn_ref+="${_wn_ref:+$'\n'}Webhook: zápis selhal – $(tail -n 1 "$_wn_err"); dorovná denní reconcile"
  elif [[ $_wn_n -eq 0 ]]; then
    _wn_ref="Webhook: beze změny"
  fi
  rm -f "$_wn_tmp" "$_wn_err"
  return 0
}

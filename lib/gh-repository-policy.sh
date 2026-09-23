#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

[[ -n "${_GH_REPOSITORY_POLICY_LOADED:-}" ]] && \
  declare -F _gh-repository-policy-check >/dev/null && return 0
_GH_REPOSITORY_POLICY_LOADED=1

_gh-jenkins-policy-resolve() {
  # Naplní nameref proměnné Jenkins politikou repa: login a configured ⇔
  # doména projektu má klíč jenkins_user; decision=allowed ⇔ efektivní klíč
  # rulesets repa (nastavení repa, jinak projekt) má položku s atributem
  # jenkins. Prázdný <ghName> = hodnota projektu. Formát loginu a konzistenci
  # validuje parser lib/gh-conf.sh při načtení konfigurace.
  # Použití: _gh-jenkins-policy-resolve <projectKey> <ghName> <login_var> <configured_var> <decision_var>
  local _key="$1" _gh_name="$2" _login_name="$3" _configured_name="$4" _decision_name="$5"
  local _domain
  declare -n _login_ref="$_login_name" _configured_ref="$_configured_name"
  declare -n _decision_ref="$_decision_name"

  _login_ref=""
  _configured_ref=false
  _decision_ref=disallowed
  _domain="${_GH_CONF[projects/$_key/domain]:-}"
  if [[ -z "$_domain" ]]; then
    echo "Chyba: projectKey '$_key' neni nakonfigurovan v zadne domene." >&2
    return 1
  fi
  if [[ -v _GH_CONF["domains/$_domain/jenkins_user"] ]]; then
    _login_ref="${_GH_CONF[domains/$_domain/jenkins_user]}"
    _configured_ref=true
    _gh-project-uses-jenkins "$_key" "$_gh_name" && _decision_ref=allowed
  fi
  return 0
}

_gh-api-input-retry() {
  # Pošle JSON payload na GH API endpoint s retry 5×2 s na přechodné chyby.
  # Volitelný <text definitivní chyby> (literál hledaný v chybovém výstupu gh):
  # při shodě se neopakuje, nic se nevypisuje a vrací se 2 – rozhodnutí
  # o hlášce nechává volajícímu (např. 409 „already set at the organization
  # or enterprise level", docs/github/actions-permissions-org-selected-409.md).
  # Použití: _gh-api-input-retry <endpoint> <metoda> <payload> <popis pro hlášky> [<text definitivní chyby>]
  local _endpoint="$1" _method="$2" _payload="$3" _label="$4" _final_text="${5:-}"
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
    if [[ -n "$_final_text" ]] && grep -qF -- "$_final_text" <<< "$_error"; then
      rm -f "$_error_file"
      return 2
    fi
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

_gh-api-delete-404ok() {
  # 404-tolerantní DELETE na GH API (mizející zdroj není chyba); bez validace
  # admin týmu – volající ji dělá sám, kde jde o repo projektu.
  # Použití: _gh-api-delete-404ok <endpoint>
  local _endpoint="$1" _error_file _error
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

_gh-jenkins-delete() {
  # 404-tolerantní DELETE na zdroji repa projektu (po validaci admin týmu).
  # Použití: _gh-jenkins-delete <endpoint> <projectKey>
  _gh-validate-admin-team "$2" GITHUB_REPO_TEAMS || return 1
  _gh-api-delete-404ok "$1"
}

_gh-jenkins-collaborator-remove() {
  local _repo_path="$1" _key="$2" _login="$3"
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-jenkins-delete "repos/$_repo_path/collaborators/$_login" "$_key"
}

_gh-jenkins-policy-preflight() {
  # Preflight Jenkins účtu, když ho efektivní klíč rulesets repa používá
  # (decision allowed): účet existuje, je členem organizace a liší se od
  # autentizovaného účtu. Prázdný <ghName> = hodnota projektu.
  # Použití: _gh-jenkins-policy-preflight <projectKey> <ghName>
  local _key="$1" _gh_name="$2" _login _configured _decision _authenticated
  _gh-jenkins-policy-resolve "$_key" "$_gh_name" _login _configured _decision || return 1
  [[ "$_decision" == allowed ]] || return 0

  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "users/$_login" >/dev/null || {
    echo "Chyba: Jenkins ucet '$_login' neexistuje nebo jej nelze overit." >&2
    return 1
  }
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "orgs/$GITHUB_ORG/members/$_login" >/dev/null || {
    echo "Chyba: Jenkins ucet '$_login' neni clenem organizace '$GITHUB_ORG'." >&2
    return 1
  }
  _gh-auth-login _authenticated || return 1
  if [[ "${_authenticated,,}" == "${_login,,}" ]]; then
    echo "Chyba: Jenkins ucet nesmi byt totozny s autentizovanym automatizacnim uctem." >&2
    return 1
  fi
}

_gh-governance-bot-collaborator-add() {
  # Přidá governance bota (GH_GOVERNANCE_BOT_USER) jako přímého collaboratora
  # s právem admin — implicitní součást policy: bot není org owner a bez
  # explicitního přístupu by jeho PAT spravovaná repa neviděl.
  # Použití: _gh-governance-bot-collaborator-add <repo_path> <projectKey>
  local _repo_path="$1" _key="$2"
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _require_vars GH_GOVERNANCE_BOT_USER || return 1
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
    "repos/$_repo_path/collaborators/$GH_GOVERNANCE_BOT_USER" \
    --method PUT --field permission=admin >/dev/null
}

_gh-governance-bot-policy-preflight() {
  # Preflight governance bota: login je povinny, ucet musi existovat, byt
  # clenem organizace a lisit se od Jenkins uctu projektu (Jenkins pristup
  # by admin pravo bota prepsal na push). Totoznost s autentizovanym uctem
  # je naopak v poradku — reconcile bezi primo pod botem. Jenkins login je
  # vlastnost domeny projektu, nastaveni repa ho nemeni — bez ghName.
  # Použití: _gh-governance-bot-policy-preflight <projectKey>
  local _key="$1" _login _configured _decision
  _require_vars GH_GOVERNANCE_BOT_USER || return 1
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "users/$GH_GOVERNANCE_BOT_USER" >/dev/null || {
    echo "Chyba: Governance bot '$GH_GOVERNANCE_BOT_USER' neexistuje nebo jej nelze overit." >&2
    return 1
  }
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "orgs/$GITHUB_ORG/members/$GH_GOVERNANCE_BOT_USER" >/dev/null || {
    echo "Chyba: Governance bot '$GH_GOVERNANCE_BOT_USER' neni clenem organizace '$GITHUB_ORG'." >&2
    return 1
  }
  _gh-jenkins-policy-resolve "$_key" "" _login _configured _decision || return 1
  _gh-jenkins-bot-collision-check "$_key" "$_login"
}

_gh-jenkins-bot-collision-check() {
  # Chyba, je-li Jenkins login projektu totožný s governance botem (defs.md:
  # ghGovernanceBotUser). Bez ohledu na atribut |jenkins: u repa bez něj by
  # policy bota odebírala jako nechtěného Jenkins collaboratora (assign ho
  # přidá, remove odebere – každý běh). Hlídá se v preflightu migrace
  # i v check/assign/remove policy (reconcile preflight nevolá).
  # Použití: _gh-jenkins-bot-collision-check <projectKey> <jenkins_login>
  local _key="$1" _login="$2"
  if [[ -n "$_login" && -n "${GH_GOVERNANCE_BOT_USER:-}" && \
        "${_login,,}" == "${GH_GOVERNANCE_BOT_USER,,}" ]]; then
    echo "Chyba: Governance bot '$GH_GOVERNANCE_BOT_USER' nesmi byt totozny s Jenkins uctem projektu '$_key' (klic jenkins_user domeny v conf.d/domains/) – policy by bota odebirala jako Jenkins collaboratora." >&2
    return 1
  fi
}

# ── Repository rulesets ───────────────────────────────────────────────────────
# Profil = definice jednoho rulesetu (pole ochrany + klíč branches), projekt si
# rulesety vybírá klíčem rulesets; na repu vznikají rulesety
# ${GH_RULESET_PREFIX}-<profil> (gh-common-defs.sh).
# Návrh a rozhodnutí: docs/implementovano/prechod-rulesets.md.

_gh-conf-rulesets-items() {
  # Vypíše položky efektivního klíče rulesets repa (nastavení repa, jinak
  # projekt; prázdný <ghName> = projekt) po řádcích: "<profil>\t<jenkins:0|1>".
  # Rezervovaná položka none se vypíše jako "none\t<jenkins>" — ruleset z ní
  # nevzniká, atribut jenkins (collaborator) ale platí dál.
  # Jediné místo parsování formátu položky (<profil> nebo <profil>|jenkins);
  # formát a odkazy validuje parser lib/gh-conf.sh při načtení konfigurace.
  # Použití: _gh-conf-rulesets-items <projectKey> <ghName>
  local _key="$1" _gh_name="$2" _rest _item _jenkins
  _gh-conf-effective "$_key" "$_gh_name" rulesets _rest
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
  # rc 0 ⇔ aspoň jedna položka efektivního klíče rulesets repa má atribut
  # jenkins (i none|jenkins). Odvozený příznak „repo používá Jenkinse"
  # (náhrada jenkins_user_enabled). Prázdný <ghName> = projekt.
  # Použití: _gh-project-uses-jenkins <projectKey> <ghName>
  local _items
  _items=$(_gh-conf-rulesets-items "$1" "$2" 2>/dev/null) || return 1
  [[ "$_items" == *$'\t'1* ]]
}

_gh-profile-requires-pr() {
  # rc 0 ⇔ profil vyžaduje PR: nepovinné pole require_pull_request chybí
  # nebo je true; false = ruleset bez pravidla pull_request (defs/defs.md,
  # policy profile).
  # Použití: _gh-profile-requires-pr <profil>
  [[ "${_GH_CONF[profiles/$1/require_pull_request]:-true}" != false ]]
}

# ── Bypass týmy (defs/defs.md: bypass tym; docs/navrh/bypass-pres-tym.md) ────
# Bypass rulesetů dostává účet (bot, Jenkins login domény) výhradně přes tým
# <GH_BYPASS_TEAM_PREFIX><login> jako bypass actor Team/always — bypass actora
# typu User GHES 3.21 neuplatňuje. Chybějící tým zakládá jen bot (PAT s org
# permission Members: write / classic scope admin:org) nebo gov-init pod
# správcem; jiný účet dostane
# hlášku. Cache v paměti běhu: jeden lookup a jeden pokus o založení na tým.
declare -gA _GH_BYPASS_TEAM_ID_CACHE=()    # slug → id týmu
declare -gA _GH_BYPASS_TEAM_DESC_CACHE=()  # slug → popis (z téhož GET, kontrola v reconcile)
declare -gA _GH_BYPASS_TEAM_FAILED=()      # slug → hláška selhání (bez opakování API)
declare -gA _GH_BYPASS_TEAM_CREATED=()     # slug → login (info položka reportu)
_GH_AUTH_LOGIN_CACHE=""

_gh-bypass-team-slug() {
  # Slug bypass týmu účtu: <GH_BYPASS_TEAM_PREFIX><login> (login malými písmeny).
  # Použití: _gh-bypass-team-slug <login>
  printf '%s%s' "$GH_BYPASS_TEAM_PREFIX" "${1,,}"
}

_gh-bypass-team-description() {
  # Doporučený popis (description) bypass týmu — vysvětlení pro org ownera,
  # proč tým existuje; uvádí se i v hláškách pro ruční založení.
  # Použití: _gh-bypass-team-description <login>
  printf 'Governance: bypass rulesetů %s-* a gov-default-branch pro účet %s. Jediný člen = %s (+ governance bot jako maintainer); tým nemá přístup k repům, jen vypíná pravidla rulesetů. Nemazat, členy nepřidávat. Viz README gov repa.' \
    "$GH_RULESET_PREFIX" "$1" "$1"
}

_gh-auth-login() {
  # Naplní nameref loginem přihlášeného účtu gh (cache v paměti běhu).
  # Použití: _gh-auth-login <výstupní proměnná>
  declare -n _gh_auth_login_ref="$1"
  if [[ -z "$_GH_AUTH_LOGIN_CACHE" ]]; then
    _GH_AUTH_LOGIN_CACHE=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api user --jq '.login') || {
      echo "Chyba: Nepodarilo se zjistit prihlaseny ucet gh (GH_HOST=$GITHUB_ORG_HOSTNAME)." >&2
      return 1
    }
  fi
  _gh_auth_login_ref="$_GH_AUTH_LOGIN_CACHE"
}

_gh-bypass-team-fail() {
  # Zapíše hlášku selhání týmu do cache (jeden pokus za běh) a vypíše ji.
  # Použití: _gh-bypass-team-fail <slug> <hláška>
  _GH_BYPASS_TEAM_FAILED["$1"]="$2"
  printf '%s\n' "$2" >&2
}

_gh-bypass-team-id() {
  # Naplní nameref číselným ID bypass týmu účtu (GET orgs/<org>/teams/<slug>);
  # popis týmu z téže odpovědi jde do _GH_BYPASS_TEAM_DESC_CACHE. rc 0 = tým
  # existuje, rc 3 = neexistuje (HTTP 404, tiše), rc 1 = jiná chyba nebo
  # dřívější selhání téhož slugu v tomto běhu (uložená hláška, bez API).
  # Použití: _gh-bypass-team-id <login> <výstupní proměnná>
  local _login="$1" _slug _out _team_id _error_file _error
  declare -n _gh_bypass_team_id_ref="$2"
  _require_vars GH_BYPASS_TEAM_PREFIX || return 1
  _slug=$(_gh-bypass-team-slug "$_login")
  if [[ -v _GH_BYPASS_TEAM_ID_CACHE["$_slug"] ]]; then
    _gh_bypass_team_id_ref="${_GH_BYPASS_TEAM_ID_CACHE[$_slug]}"
    return 0
  fi
  if [[ -v _GH_BYPASS_TEAM_FAILED["$_slug"] ]]; then
    printf '%s\n' "${_GH_BYPASS_TEAM_FAILED[$_slug]}" >&2
    return 1
  fi
  _error_file=$(mktemp) || return 1
  if _out=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "orgs/$GITHUB_ORG/teams/$_slug" \
      --jq '[.id, (.description // "")] | @tsv' 2>"$_error_file"); then
    rm -f "$_error_file"
    _team_id="${_out%%$'\t'*}"
    if [[ ! "$_team_id" =~ ^[0-9]+$ ]]; then
      echo "Chyba: Neocekavane ID bypass tymu '$_slug' (ucet '$_login'): '$_team_id'." >&2
      return 1
    fi
    _GH_BYPASS_TEAM_ID_CACHE["$_slug"]="$_team_id"
    _GH_BYPASS_TEAM_DESC_CACHE["$_slug"]="${_out#*$'\t'}"
    _gh_bypass_team_id_ref="$_team_id"
    return 0
  fi
  _error=$(< "$_error_file")
  rm -f "$_error_file"
  grep -qF '(HTTP 404)' <<< "$_error" && return 3
  [[ -n "$_error" ]] && printf '%s\n' "$_error" >&2
  echo "Chyba: Nepodarilo se zjistit ID bypass tymu '$_slug' (ucet '$_login')." >&2
  return 1
}

_gh-bypass-team-create() {
  # Založí bypass tým účtu (POST orgs/<org>/teams, privacy closed, s popisem);
  # zakladatel je automaticky maintainer. Stdout: id týmu. Přímé gh api bez
  # retry: odmítnutí (HTTP 403 org zakázala členům zakládat týmy / PAT bez
  # Members: write ani classic scope admin:org, 404, 422) je definitivní → rc 2 (stderr gh propuštěn),
  # jiná chyba rc 1.
  # Použití: _gh-bypass-team-create <login>
  local _login="$1" _slug _payload _id _error_file _error
  _slug=$(_gh-bypass-team-slug "$_login")
  _payload=$(printf '{"name":"%s","description":"%s","privacy":"closed"}' \
    "$_slug" "$(_gh-bypass-team-description "$_login")")
  _error_file=$(mktemp) || return 1
  if _id=$(printf '%s' "$_payload" | GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
      "orgs/$GITHUB_ORG/teams" --method POST --input - --jq '.id' 2>"$_error_file"); then
    rm -f "$_error_file"
    printf '%s\n' "$_id"
    return 0
  fi
  _error=$(< "$_error_file")
  rm -f "$_error_file"
  [[ -n "$_error" ]] && printf '%s\n' "$_error" >&2
  grep -qE '\(HTTP (403|404|422)\)' <<< "$_error" && return 2
  return 1
}

_gh-bypass-team-member-set() {
  # Přidá účet do bypass týmu (PUT memberships, role member|maintainer).
  # Stav active = rc 0; pending (login mimo organizaci → jen pozvánka, bypass
  # neplatí) = rc 1 s hláškou; chyba API rc 1.
  # Použití: _gh-bypass-team-member-set <slug> <login> <member|maintainer>
  local _slug="$1" _login="$2" _role="$3" _state
  case "$_role" in
    member|maintainer) ;;
    *) echo "Chyba: Neznama role clena bypass tymu: '$_role' (member|maintainer)." >&2; return 1 ;;
  esac
  _state=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
    "orgs/$GITHUB_ORG/teams/$_slug/memberships/$_login" \
    --method PUT --field role="$_role" --jq '.state') || return 1
  [[ "$_state" == active ]] && return 0
  echo "Chyba: Ucet '$_login' neni clenem organizace '$GITHUB_ORG' – clenstvi v bypass tymu '$_slug' je jen pozvanka ($_state), bypass neplati." >&2
  return 1
}

_gh-bypass-team-member-remove() {
  # Odebere účet z bypass týmu (404-tolerantní DELETE; lidský zakladatel
  # v gov-init po založení týmu bota).
  # Použití: _gh-bypass-team-member-remove <slug> <login>
  _gh-api-delete-404ok "orgs/$GITHUB_ORG/teams/$1/memberships/$2"
}

_gh-bypass-team-ensure() {
  # Naplní nameref ID bypass týmu účtu; chybí-li tým, založí ho pod přihlášeným
  # účtem: bot jako maintainer (není-li zakladatel), <login> jako member (není-li
  # bot), lidský zakladatel (≠ bot, ≠ login) se odebere. Selhání → hláška
  # s instrukcí pro ruční založení org ownerem, uložená pro tento běh.
  # Použití: _gh-bypass-team-ensure <login> <výstupní proměnná>
  local _login="$1" _slug _id _me _bot _rc=0 _error_file _error _http _manual
  declare -n _gh_bypass_team_ensure_ref="$2"
  _require_vars GH_BYPASS_TEAM_PREFIX GH_GOVERNANCE_BOT_USER || return 1
  _gh-bypass-team-id "$_login" _id || _rc=$?
  if [[ $_rc -eq 0 ]]; then
    _gh_bypass_team_ensure_ref="$_id"
    return 0
  fi
  [[ $_rc -eq 3 ]] || return 1
  _gh-auth-login _me || return 1
  _bot="$GH_GOVERNANCE_BOT_USER"
  _slug=$(_gh-bypass-team-slug "$_login")
  _manual="nazev '$_slug', clenove '$_login' a bot '$_bot' (maintainer), popis: \"$(_gh-bypass-team-description "$_login")\""
  _error_file=$(mktemp) || return 1
  if ! _id=$(_gh-bypass-team-create "$_login" 2>"$_error_file"); then
    _error=$(< "$_error_file")
    rm -f "$_error_file"
    [[ -n "$_error" ]] && printf '%s\n' "$_error" >&2
    _http=$(grep -oE 'HTTP [0-9]+' <<< "$_error" | head -n 1)
    _gh-bypass-team-fail "$_slug" "Chyba: Bypass tym '$_slug' pro ucet '$_login' nelze zalozit (${_http:-chyba API}) – zaloz ho rucne jako org owner: $_manual; zkontroluj org nastaveni 'Allow members to create teams' a PAT bota s pravem spravovat tymy (fine-grained: org permission Members: write, classic: scope admin:org)."
    return 1
  fi
  rm -f "$_error_file"
  if [[ "${_me,,}" != "${_bot,,}" ]] && ! _gh-bypass-team-member-set "$_slug" "$_bot" maintainer; then
    _gh-bypass-team-fail "$_slug" "Chyba: Bypass tym '$_slug' pro ucet '$_login' zalozen, ale bota '$_bot' (maintainer) nelze pridat – dopln cleny rucne jako org owner: $_manual."
    return 1
  fi
  if [[ "${_login,,}" != "${_bot,,}" ]] && ! _gh-bypass-team-member-set "$_slug" "$_login" member; then
    _gh-bypass-team-fail "$_slug" "Chyba: Bypass tym '$_slug' pro ucet '$_login' zalozen, ale clena '$_login' nelze pridat – dopln cleny rucne jako org owner: $_manual."
    return 1
  fi
  if [[ "${_me,,}" != "${_bot,,}" && "${_me,,}" != "${_login,,}" ]] && \
      ! _gh-bypass-team-member-remove "$_slug" "$_me"; then
    _gh-bypass-team-fail "$_slug" "Chyba: Bypass tym '$_slug' pro ucet '$_login' zalozen, ale zakladatele '$_me' nelze odebrat – odeber ho rucne (org owner nebo bot jako maintainer); ocekavani: $_manual."
    return 1
  fi
  _GH_BYPASS_TEAM_ID_CACHE["$_slug"]="$_id"
  _GH_BYPASS_TEAM_DESC_CACHE["$_slug"]=$(_gh-bypass-team-description "$_login")
  _GH_BYPASS_TEAM_CREATED["$_slug"]="$_login"
  _gh_bypass_team_ensure_ref="$_id"
}

_gh-bypass-team-resolve() {
  # Rozhraní pro builder payloadu rulesetu: ID bypass týmu účtu. Chybí-li tým,
  # založí ho jen přihlášený bot (ensure); pod jiným účtem (migrátor, lokální
  # běh) rc 1 s hláškou, že tým založí bot při příštím daily-reconcile.
  # Použití: _gh-bypass-team-resolve <login> <výstupní proměnná>
  local _login="$1" _id _me _slug _rc=0
  declare -n _gh_bypass_team_resolve_ref="$2"
  _gh-bypass-team-id "$_login" _id || _rc=$?
  if [[ $_rc -eq 0 ]]; then
    _gh_bypass_team_resolve_ref="$_id"
    return 0
  fi
  [[ $_rc -eq 3 ]] || return 1
  _gh-auth-login _me || return 1
  if [[ -n "${GH_GOVERNANCE_BOT_USER:-}" && "${_me,,}" == "${GH_GOVERNANCE_BOT_USER,,}" ]]; then
    _gh-bypass-team-ensure "$_login" _gh_bypass_team_resolve_ref
    return
  fi
  _slug=$(_gh-bypass-team-slug "$_login")
  _gh-bypass-team-fail "$_slug" "Chyba: Bypass tym '$_slug' pro ucet '$_login' neexistuje – zalozi ho governance bot pri pristim behu daily-reconcile (lze spustit rucne), nebo org owner rucne: nazev '$_slug', clenove '$_login' a bot '${GH_GOVERNANCE_BOT_USER:-}' (maintainer), popis: \"$(_gh-bypass-team-description "$_login")\"."
  return 1
}

_gh-ruleset-payload() {
  # Sestaví JSON payload rulesetu ${GH_RULESET_PREFIX}-<profil> z polí profilu – offline,
  # bez sítě (ID bypass týmů dodá volající). Překlad branch protection → ruleset
  # dle docs/github/branch-protection-vs-rulesets-mapovani.md a rozhodnutí návrhu:
  #   - allow_force_pushes/allow_deletions=false → pravidlo non_fast_forward/deletion,
  #   - required_status_checks bez checků → pravidlo se vynechá (API odmítá []),
  #   - pravidlo update (Restrict updates) se negeneruje nikdy: blokovalo by
  #     i merge schváleného PR všem mimo bypass týmy (pole profilu restrictions
  #     zrušeno 2026-09-23, docs/plans/plan-zruseni-restrictions.md),
  #   - enforce_admins=false → bypass actor RepositoryRole 5 (admin),
  #   - Jenkins i bot jsou bypass actor Team always přes svůj bypass tým
  #     (defs/defs.md: bypass tym; actor typu User GHES 3.21 neuplatňuje):
  #     <jenkins_team_id> u položky |jenkins s PR, <bot_team_id> neprázdné →
  #     tým governance bota (zápis obsahu spravovaných rep přes Contents API —
  #     CODEOWNERS; bot je admin každého repa, bypass jeho práva nerozšiřuje),
  #   - require_pull_request=false (profil bez PR) → bez pravidla pull_request
  #     a bez Jenkins bypass actora (parametr <jenkins> se ignoruje: Jenkins
  #     pushuje přímo jako collaborator, bypass nemá co obcházet; pole review
  #     profilu jen validuje parser).
  # Použití: _gh-ruleset-payload <projectKey> <profil> <jenkins:0|1> [jenkins_team_id] [bot_team_id]
  local _key="$1" _profile="$2" _jenkins="$3" _actor_id="${4:-}" _bot_id="${5:-}"
  local _field _value _bypass_actors="" _rules="" _sep _requires_pr=1
  for _field in branches $_GH_CONF_PROFILE_FIELDS; do
    if [[ -z "${_GH_CONF[profiles/$_profile/$_field]:-}" ]]; then
      echo "Chyba: Profil '$_profile' (projekt '$_key') nemá klíč '$_field' – payload rulesetu nelze sestavit. Zkontroluj conf.d/profiles/$_profile.conf." >&2
      return 1
    fi
  done
  _gh-profile-requires-pr "$_profile" || _requires_pr=0

  if [[ "$_jenkins" == 1 && $_requires_pr -eq 1 ]]; then
    if [[ ! "$_actor_id" =~ ^[0-9]+$ ]]; then
      echo "Chyba: Položka '$_profile|jenkins' vyžaduje číselné actor_id bypass týmu Jenkins účtu (je '${_actor_id:-<prázdné>}')." >&2
      return 1
    fi
    _bypass_actors='{ "actor_id": '"$_actor_id"', "actor_type": "Team", "bypass_mode": "always" }'
  fi
  if [[ "${_GH_CONF[profiles/$_profile/enforce_admins]}" == false ]]; then
    _bypass_actors+="${_bypass_actors:+, }"'{ "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }'
  fi
  if [[ -n "$_bot_id" ]]; then
    _bypass_actors+="${_bypass_actors:+, }"'{ "actor_id": '"$_bot_id"', "actor_type": "Team", "bypass_mode": "always" }'
  fi

  local -a _rules_arr=()
  [[ $_requires_pr -eq 1 ]] && \
    _rules_arr+=("$(printf '{ "type": "pull_request", "parameters": { "required_approving_review_count": %s, "dismiss_stale_reviews_on_push": %s, "require_code_owner_review": %s, "require_last_push_approval": false, "required_review_thread_resolution": false } }' \
      "${_GH_CONF[profiles/$_profile/required_approving_review_count]}" \
      "${_GH_CONF[profiles/$_profile/dismiss_stale_reviews]}" \
      "${_GH_CONF[profiles/$_profile/require_code_owner_reviews]}")")
  _value="${_GH_CONF[profiles/$_profile/required_status_checks]}"
  _value="${_value//[[:space:]]/}"
  if [[ "$_value" != null && "$_value" != *'"contexts":[]'* ]]; then
    echo "Chyba: Profil '$_profile' má neprázdný seznam checků v required_status_checks – překlad na ruleset zatím není podporován (viz docs/implementovano/prechod-rulesets.md)." >&2
    return 1
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
  "name": "%s-%s",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["%s"], "exclude": [] } },
  "bypass_actors": [%s],
  "rules": [
    %s
  ]
}' "$GH_RULESET_PREFIX" "$_profile" "${_GH_CONF[profiles/$_profile/branches]}" "$_bypass_actors" "$_rules"
}

_gh-ruleset-payloads-build() {
  # Sestaví payloady všech položek efektivního klíče rulesets repa do nameref
  # asociativního pole jméno rulesetu → payload. Slouží i jako fail-fast
  # validace konfigurace před první mutací (včetně lookupu ID bypass týmů;
  # chybějící tým založí jen běh pod botem – _gh-bypass-team-resolve, jinde
  # rc 1 s hláškou). Položka none = žádný ruleset (prázdné pole; apply pak
  # smaže všechny ${GH_RULESET_PREFIX}-*). ID týmů se zjišťují, jen když je
  # payload použije: u none|jenkins a profilu bez PR zůstává Jenkins jen
  # collaborator.
  # Použití: local -A _p=(); _gh-ruleset-payloads-build <projectKey> <ghName> <jenkins_login> _p
  local _key="$1" _gh_name="$2" _jenkins_login="$3" _items _profile _jenkins _actor_id _payload
  local _bot_id=""
  declare -n _payloads_ref="$4"
  _items=$(_gh-conf-rulesets-items "$_key" "$_gh_name") || return 1
  while IFS=$'\t' read -r _profile _jenkins; do
    [[ "$_profile" == "$_GH_CONF_NONE" ]] && continue
    # Bypass tým governance bota je bypass actor always každého rulesetu
    # (zápis CODEOWNERS přes Contents API); bez nastaveného bota (offline
    # testy) se vynechá.
    if [[ -z "$_bot_id" && -n "${GH_GOVERNANCE_BOT_USER:-}" ]]; then
      _gh-bypass-team-resolve "$GH_GOVERNANCE_BOT_USER" _bot_id || return 1
    fi
    _actor_id=""
    if [[ "$_jenkins" == 1 ]] && _gh-profile-requires-pr "$_profile"; then
      if [[ -z "$_jenkins_login" ]]; then
        echo "Chyba: Položka '$_profile|jenkins' v klíči rulesets projektu '$_key', ale Jenkins login není k dispozici. Zkontroluj klíč jenkins_user domény v conf.d/domains/." >&2
        return 1
      fi
      _gh-bypass-team-resolve "$_jenkins_login" _actor_id || return 1
    fi
    _payload=$(_gh-ruleset-payload "$_key" "$_profile" "$_jenkins" "$_actor_id" "$_bot_id") || return 1
    _payloads_ref["${GH_RULESET_PREFIX}-$_profile"]="$_payload"
  done <<< "$_items"
}

_gh-ruleset-list() {
  # Vypíše rulesety repa po řádcích "<id>\t<jméno>" (repository-level source).
  # Použití: _gh-ruleset-list <repo_path>
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$1/rulesets" \
    --paginate --jq '.[] | select(.source_type == "Repository") | [.id, .name] | @tsv'
}

_gh-ruleset-ids() {
  # Naplní nameref asociativní pole jméno rulesetu → id (repository-level
  # rulesety repa) – společný find-by-name krok apply/check/gov-init.
  # Použití: local -A _ids=(); _gh-ruleset-ids <repo_path> _ids
  local _repo_path="$1" _listing _id _name
  declare -n _gh_ruleset_ids_ref="$2"
  _listing=$(_gh-ruleset-list "$_repo_path") || return 1
  while IFS=$'\t' read -r _id _name; do
    [[ -n "$_id" ]] && _gh_ruleset_ids_ref["$_name"]="$_id"
  done <<< "$_listing"
  return 0
}

_gh-ruleset-branch-rule-types() {
  # Vypíše typy efektivních pravidel větve (agregát všech aktivních rulesetů
  # cílících větev) jako čárkami oddělený seznam – smoke-test, že ruleset na
  # větev skutečně působí (docs/github/rulesets-put-prepis-a-bypass-mode.md).
  # Použití: _gh-ruleset-branch-rule-types <repo_path> <branch>
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
    "repos/$1/rules/branches/$(_url_encode_path "$2")" \
    --jq '[.[].type] | unique | join(",")'
}

_gh-ruleset-apply() {
  # Aplikuje rulesety podle klíče rulesets projektu: find-by-name → POST
  # (neexistuje) / PUT (existuje); osiřelé rulesety ${GH_RULESET_PREFIX}-* smaže.
  # Ruleset se posílá vždy jako kompletní payload (PUT přepisuje i bypass).
  # Efektivní rulesets=none → žádný očekávaný ruleset, jen úklid osiřelých.
  # Použití: _gh-ruleset-apply <repo_path> <projectKey> <ghName> [jenkins_login]
  local _repo_path="$1" _key="$2" _gh_name="$3" _jenkins_login="${4:-}"
  local _name
  local -A _expected_payloads=() _existing_ids=()
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-ruleset-payloads-build "$_key" "$_gh_name" "$_jenkins_login" _expected_payloads || return 1
  _gh-ruleset-ids "$_repo_path" _existing_ids || return 1
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
    [[ "$_name" == "${GH_RULESET_PREFIX}-"* ]] || continue
    [[ -v _expected_payloads["$_name"] ]] && continue
    _gh-jenkins-delete "repos/$_repo_path/rulesets/${_existing_ids[$_name]}" "$_key" || return 1
  done
}

_gh-ruleset-check() {
  # Sémanticky porovná rulesety ${GH_RULESET_PREFIX}-* repa s očekávaným stavem z conf.d
  # (normalizovaný JSON přes jq) a smoke-testem ověří efektivní pravidla
  # výchozí větve. Výstup: OK / DIFF (rc 0); rc 2 při chybě. Efektivní
  # rulesets=none → jen kontrola „žádný ${GH_RULESET_PREFIX}-*", smoke-test
  # se přeskočí (není co ověřovat).
  # Použití: _gh-ruleset-check <repo_path> <branch> <projectKey> <ghName> [jenkins_login]
  local _repo_path="$1" _branch="$2" _key="$3" _gh_name="$4" _jenkins_login="${5:-}"
  local _name _result _observed_types _types _t _filter
  local -A _expected_payloads=() _existing_ids=()
  _gh-ruleset-payloads-build "$_key" "$_gh_name" "$_jenkins_login" _expected_payloads || return 2
  _gh-ruleset-ids "$_repo_path" _existing_ids || return 2
  for _name in "${!_expected_payloads[@]}"; do
    [[ -v _existing_ids["$_name"] ]] || { printf 'DIFF\n'; return 0; }
  done
  for _name in "${!_existing_ids[@]}"; do
    if [[ "$_name" == "${GH_RULESET_PREFIX}-"* && ! -v _expected_payloads["$_name"] ]]; then
      printf 'DIFF\n'
      return 0
    fi
  done
  [[ ${#_expected_payloads[@]} -gt 0 ]] || { printf 'OK\n'; return 0; }
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
  _observed_types=$(_gh-ruleset-branch-rule-types "$_repo_path" "$_branch") || return 2
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
  # Vypíše efektivní týmy repa (repository_teams projektu + repository_teams_add
  # nastavení repa) po řádcích "<slug>\t<api oprávnění>", seřazené; prázdný
  # <ghName> = týmy projektu. Admin tým projektu je garantovaný vždy.
  # Použití: _gh-repository-policy-expected-teams <projectKey> <ghName>
  local _key="$1" _gh_name="$2" _teams _entry _team _permission
  local -a _entries=()
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _teams=$(_gh-teams-for-key "$_key" "$_gh_name" GITHUB_REPO_TEAMS) || return 1
  IFS=',' read -ra _entries <<< "$_teams"
  for _entry in "${_entries[@]}"; do
    _team="${_entry%%|*}"
    _permission=$(_gh-perm-to-api "${_entry##*|}")
    printf '%s\t%s\n' "$_team" "$_permission"
  done | LC_ALL=C sort -u
}

_gh-repository-policy-collaborator-check() {
  # Ověří přímého collaboratora repa: expected=allowed → login musí mít
  # oprávnění <required> (push/admin), jinak nesmí být přímý collaborator
  # vůbec. Vypíše OK/DIFF; rc 2 při chybě API; prázdný login = OK.
  # Použití: _gh-repository-policy-collaborator-check <repo_path> <login> <expected> <required>
  local _repo_path="$1" _login="$2" _expected="$3" _required="$4" _permission
  [[ -n "$_login" ]] || { printf 'OK\n'; return 0; }
  _permission=$(COLLAB_LOGIN="$_login" COLLAB_PERM="$_required" \
    GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
    "repos/$_repo_path/collaborators?affiliation=direct" --paginate --jq \
    '[.[] | select((.login | ascii_downcase) == (env.COLLAB_LOGIN | ascii_downcase)) |
      if (.permissions[env.COLLAB_PERM] // false) then env.COLLAB_PERM else (.role_name // "none") end][0] // "none"') || return 2
  if [[ "$_expected" == allowed && "$_permission" == "$_required" ]] || \
     [[ "$_expected" != allowed && "$_permission" == none ]]; then
    printf 'OK\n'
  else
    printf 'DIFF\n'
  fi
}

_gh-repository-policy-extra-collaborators() {
  # Čistá funkce (offline testy): z listingu přímých collaboratorů
  # ("<login>\t<role>" po řádcích) vypíše ty mimo politiku – všechny kromě
  # governance bota a Jenkins loginu (porovnání case-insensitive; prázdný
  # Jenkins login = doména bez Jenkinse, pak je navíc každý kromě bota).
  # Použití: _gh-repository-policy-extra-collaborators <listingTSV> <bot_login> <jenkins_login>
  local _listing="$1" _bot="${2,,}" _jenkins="${3,,}" _login _role
  while IFS=$'\t' read -r _login _role; do
    [[ -n "$_login" ]] || continue
    [[ "${_login,,}" == "$_bot" ]] && continue
    [[ -n "$_jenkins" && "${_login,,}" == "$_jenkins" ]] && continue
    printf '%s\t%s\n' "$_login" "$_role"
  done <<< "$_listing"
  return 0
}

_gh-repository-policy-extra-collaborators-list() {
  # Vypíše přímé collaboratory repa mimo politiku ("<login>\t<role>" po
  # řádcích). Očekávaní jsou governance bot a Jenkins login aktuální domény
  # projektu bez ohledu na decision (je-li configured a ne allowed, odebírá
  # ho _gh-repository-policy-remove – nehlásit dvakrát). Org owner přidaný
  # přes PUT je v affiliation=direct a hlásí se jako každý jiný (politika
  # přímé lidi nezná, docs/github/repo-collaborators-api.md). rc 1 při chybě.
  # Použití: _gh-repository-policy-extra-collaborators-list <repo_path> <projectKey> <ghName>
  local _repo_path="$1" _key="$2" _gh_name="$3" _login _configured _decision _listing
  _require_vars GH_GOVERNANCE_BOT_USER || return 1
  _gh-jenkins-policy-resolve "$_key" "$_gh_name" _login _configured _decision || return 1
  _listing=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
    "repos/$_repo_path/collaborators?affiliation=direct" --paginate \
    --jq '.[] | [.login, (.role_name // "-")] | @tsv') || return 1
  _gh-repository-policy-extra-collaborators "$_listing" "$GH_GOVERNANCE_BOT_USER" "$_login"
}

_gh-repository-policy-teams-check() {
  # Porovná týmy repa s efektivními týmy z conf.d. Výstup: OK / DIFF;
  # rc 1 při chybě API nebo konfigurace.
  # Použití: _gh-repository-policy-teams-check <repo_path> <projectKey> <ghName>
  local _repo_path="$1" _key="$2" _gh_name="$3" _expected_teams _observed_teams _team _permission
  local _teams_match=true
  local -A _observed_team_map=()
  _expected_teams=$(_gh-repository-policy-expected-teams "$_key" "$_gh_name") || return 1
  # stderr gh se propaguje – volající (audit, migrace, reconcile) hlásí jen
  # název kroku, příčinu (HTTP 403/404 = práva účtu na repu) musí vidět uživatel.
  _observed_teams=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/teams" \
    --paginate --jq '.[] | [.slug, .permission] | @tsv') || return 1
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

# ── Custom properties MHN a Deployment_Target ────────────────────────────────
# Součást repository policy (defs/defs.md: business service, Deployment_Target):
# MHN je kopie business service odvozené z conf.d – policy ji konverguje,
# ruční změna v GH je drift. Deployment_Target je v rukou admina repa – policy
# ji jen doplní výchozí hodnotou GH_DEPLOYMENT_TARGET_DEFAULT, když chybí;
# existující hodnotu nikdy nemění ani nehlásí. Chování API (práva PAT,
# částečný PATCH, tvar GET): docs/github/custom-properties.md.

_gh-repository-policy-properties-read() {
  # Načte hodnoty custom properties MHN a Deployment_Target repa do nameref
  # proměnných (prázdná = nenastaveno; jq pokrývá chybějící položku i
  # value null). Jeden GET; rc 1 při chybě API.
  # Použití: _gh-repository-policy-properties-read <repo_path> <mhn_var> <dt_var>
  # Interní proměnné mají vlastní prefix, aby nameref nestínil lokál stejného
  # jména u volajícího (typicky _mhn/_dt).
  local _repo_path="$1" _props_row _props_read_mhn _props_read_dt _props_extra
  declare -n _props_mhn_ref="$2" _props_dt_ref="$3"
  _props_mhn_ref=""; _props_dt_ref=""
  _props_row=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/properties/values" \
    --jq '(map({key: .property_name, value: ((.value // "") | tostring)}) | from_entries) as $p
      | [($p.MHN // ""), ($p.Deployment_Target // "")] | @tsv') || {
    echo "Chyba: Čtení custom properties repa '$_repo_path' selhalo." >&2
    return 1
  }
  IFS=$'\t' read -r _props_read_mhn _props_read_dt _props_extra <<< "$_props_row"
  _props_mhn_ref="$_props_read_mhn"; _props_dt_ref="$_props_read_dt"
  return 0
}

_gh-repository-policy-properties-expected-mhn() {
  # Vypíše očekávanou hodnotu property MHN projektu (business service = první
  # složka klíče domain v conf.d); rc 1 s hláškou, když projekt nemá doménu.
  # Použití: _gh-repository-policy-properties-expected-mhn <projectKey>
  _mhn_for_key "$1" && return 0
  echo "Chyba: Pro projectKey '$1' nelze urcit povinnou MHN property." >&2
  return 1
}

_gh-repository-policy-properties-diff() {
  # Čistá funkce (offline testy): vypíše detail prvního rozdílu property proti
  # policy – „MHN property differs" / „Deployment_Target property missing" –
  # nebo nic, když property sedí. Deployment_Target s libovolnou hodnotou sedí.
  # Použití: _gh-repository-policy-properties-diff <mhn_expected> <mhn_observed> <dt_observed>
  local _expected="$1" _mhn="$2" _dt="$3"
  if [[ "$_mhn" != "$_expected" ]]; then
    printf 'MHN property differs\n'
  elif [[ -z "$_dt" ]]; then
    printf 'Deployment_Target property missing\n'
  fi
  return 0
}

_gh-repository-policy-properties-check() {
  # Check property repa: vypíše OK, nebo "DIFF<TAB><detail prvního rozdílu>";
  # rc 1 při chybě API nebo konfigurace.
  # Použití: _gh-repository-policy-properties-check <repo_path> <projectKey>
  local _repo_path="$1" _key="$2" _expected _mhn _dt _diff
  _expected=$(_gh-repository-policy-properties-expected-mhn "$_key") || return 1
  _gh-repository-policy-properties-read "$_repo_path" _mhn _dt || return 1
  _diff=$(_gh-repository-policy-properties-diff "$_expected" "$_mhn" "$_dt")
  if [[ -z "$_diff" ]]; then
    printf 'OK\n'
  else
    printf 'DIFF\t%s\n' "$_diff"
  fi
}

_gh-repository-policy-properties-apply() {
  # Srovná property repa s policy jedním PATCH (částečná aktualizace –
  # neuvedené property zůstávají): MHN jen při rozdílu, Deployment_Target
  # = GH_DEPLOYMENT_TARGET_DEFAULT jen je-li prázdná. Nikdy neposílá
  # Deployment_Target, která už hodnotu má; bez rozdílu neposílá nic
  # (žádný zbytečný zápis ani šum v historii repa).
  # Použití: _gh-repository-policy-properties-apply <repo_path> <projectKey> <mhn_observed> <dt_observed>
  local _repo_path="$1" _key="$2" _mhn="$3" _dt="$4" _expected _items=""
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _require_vars GH_DEPLOYMENT_TARGET_DEFAULT || return 1
  _expected=$(_gh-repository-policy-properties-expected-mhn "$_key") || return 1
  [[ "$_mhn" == "$_expected" ]] || \
    _items="{\"property_name\":\"MHN\",\"value\":\"$_expected\"}"
  [[ -n "$_dt" ]] || \
    _items+="${_items:+,}{\"property_name\":\"Deployment_Target\",\"value\":\"$GH_DEPLOYMENT_TARGET_DEFAULT\"}"
  [[ -n "$_items" ]] || return 0
  _gh-api-input-retry "repos/$_repo_path/properties/values" PATCH \
    "{\"properties\":[$_items]}" "custom properties repa '$_repo_path'"
}

_gh-repository-policy-check() {
  # Check policy: týmy → rulesety (sémantické porovnání + smoke-test) →
  # Jenkins collaborator → governance bot collaborator (admin) → custom
  # properties (MHN dle conf.d, Deployment_Target nastavená).
  # Výsledek OK/DIFF/ERROR a detail přes nameref: u DIFF první rozdíl, u ERROR
  # název kroku, který selhal (příčinu – hlášku gh/konfigurace – vypsal krok
  # sám na stderr). Očekávaný stav = efektivní konfigurace repa (projekt +
  # nastavení repa).
  # Použití: _gh-repository-policy-check <repo_path> <branch> <key> <ghName> <result_name> <detail_name>
  local _repo_path="$1" _branch="$2" _key="$3" _gh_name="$4" _result_name="$5" _detail_name="$6"
  local _login _configured _decision _teams _rulesets _collaborator _bot _props
  declare -n _result_ref="$_result_name" _detail_ref="$_detail_name"
  _result_ref=ERROR; _detail_ref="policy configuration check failed"
  _require_vars GH_GOVERNANCE_BOT_USER || return 0
  _gh-jenkins-policy-resolve "$_key" "$_gh_name" _login _configured _decision || return 0
  _detail_ref="Jenkins login equals governance bot"
  _gh-jenkins-bot-collision-check "$_key" "$_login" || return 0
  _detail_ref="teams check failed"
  _teams=$(_gh-repository-policy-teams-check "$_repo_path" "$_key" "$_gh_name") || return 0
  _detail_ref="rulesets check failed"
  _rulesets=$(_gh-ruleset-check "$_repo_path" "$_branch" "$_key" "$_gh_name" "$_login") || return 0
  _detail_ref="Jenkins collaborator check failed"
  _collaborator=$(_gh-repository-policy-collaborator-check "$_repo_path" "$_login" "$_decision" push) || return 0
  _detail_ref="governance bot collaborator check failed"
  _bot=$(_gh-repository-policy-collaborator-check "$_repo_path" "$GH_GOVERNANCE_BOT_USER" allowed admin) || return 0
  _detail_ref="properties check failed"
  _props=$(_gh-repository-policy-properties-check "$_repo_path" "$_key") || return 0

  _result_ref=OK; _detail_ref=-
  if [[ "$_teams" != OK ]]; then
    _result_ref=DIFF; _detail_ref="team permissions differ"
  elif [[ "$_rulesets" != OK ]]; then
    _result_ref=DIFF; _detail_ref="rulesets differ"
  elif [[ "$_collaborator" != OK ]]; then
    _result_ref=DIFF; _detail_ref="Jenkins collaborator differs"
  elif [[ "$_bot" != OK ]]; then
    _result_ref=DIFF; _detail_ref="governance bot collaborator differs"
  elif [[ "$_props" != OK ]]; then
    _result_ref=DIFF; _detail_ref="${_props#DIFF$'\t'}"
  fi
}

_gh-repository-policy-live-admin-removal-safe() {
  local _repo_path="$1" _team="$2" _count
  _count=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/teams" --paginate \
    --jq "[.[] | select(.permission == \"admin\" and .slug != \"$_team\")] | length") || return 1
  [[ "$_count" =~ ^[1-9][0-9]*$ ]]
}

_gh-repository-policy-reconcile-teams() {
  # Dorovná týmy repa na efektivní týmy (admin třída první; odebrání admin
  # práva jen se zachovaným jiným admin týmem). Nikdy neodebírá — týmy navíc
  # řeší diff ukazatele (lib/gh-governance-state.sh) a tools/.
  # Použití: _gh-repository-policy-reconcile-teams <repo_path> <projectKey> <ghName>
  local _repo_path="$1" _key="$2" _gh_name="$3" _expected _observed _class _team _permission _old
  local -A _observed_map=()
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _expected=$(_gh-repository-policy-expected-teams "$_key" "$_gh_name") || return 1
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
  # Assign policy: payloady fail-fast → týmy → governance bot (admin
  # collaborator – bez něj bot PAT repo nespravuje) → custom properties
  # (MHN, chybějící Deployment_Target) → Jenkins collaborator (před apply –
  # bypass neuděluje právo zápisu) → jediný ruleset apply s bypass seznamem
  # rovnou v payloadu. Argument <branch> zůstává kvůli rozhraní call sites
  # (rulesety cílí větve přes klíč branches profilů). Očekávaný stav =
  # efektivní konfigurace repa (projekt + nastavení repa <ghName>).
  # Použití: _gh-repository-policy-assign <repo_path> <branch> <projectKey> <ghName>
  local _repo_path="$1" _key="$3" _gh_name="$4"
  local _login _configured _decision _mhn_observed _dt_observed
  local -A _payloads=()
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-jenkins-policy-resolve "$_key" "$_gh_name" _login _configured _decision || return 1
  _gh-jenkins-bot-collision-check "$_key" "$_login" || return 1
  _gh-ruleset-payloads-build "$_key" "$_gh_name" "$_login" _payloads || return 1
  _gh-repository-policy-reconcile-teams "$_repo_path" "$_key" "$_gh_name" || return 1
  _gh-governance-bot-collaborator-add "$_repo_path" "$_key" || return 1
  _gh-repository-policy-properties-read "$_repo_path" _mhn_observed _dt_observed || return 1
  _gh-repository-policy-properties-apply "$_repo_path" "$_key" "$_mhn_observed" "$_dt_observed" || return 1
  if [[ "$_decision" == allowed ]]; then
    _gh-jenkins-collaborator-add "$_repo_path" "$_key" "$_login" || return 1
    _gh-ruleset-apply "$_repo_path" "$_key" "$_gh_name" "$_login" || return 1
  else
    _gh-ruleset-apply "$_repo_path" "$_key" "$_gh_name" || return 1
  fi
}

_gh-repository-policy-remove() {
  # Remove policy: uklidí Jenkins collaboratora, když ho efektivní rulesets
  # repa nepoužívají (bypass v rulesetu srovnává apply/orphan logika sama).
  # Argument <branch> zůstává kvůli rozhraní call sites.
  # Použití: _gh-repository-policy-remove <repo_path> <branch> <projectKey> <ghName>
  local _repo_path="$1" _key="$3" _gh_name="$4"
  local _login _configured _decision
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-jenkins-policy-resolve "$_key" "$_gh_name" _login _configured _decision || return 1
  _gh-jenkins-bot-collision-check "$_key" "$_login" || return 1
  if [[ "$_configured" == true && "$_decision" != allowed ]]; then
    _gh-jenkins-collaborator-remove "$_repo_path" "$_key" "$_login" || return 1
  fi
}

_gh-repository-policy-reconcile() {
  # Použití: _gh-repository-policy-reconcile <repo_path> <branch> <projectKey> <ghName>
  local _repo_path="$1" _branch="$2" _key="$3" _gh_name="$4"
  _gh-repository-policy-assign "$_repo_path" "$_branch" "$_key" "$_gh_name" || return 1
  _gh-repository-policy-remove "$_repo_path" "$_branch" "$_key" "$_gh_name"
}

_gh-repository-policy-apply() {
  # Použití: _gh-repository-policy-apply <repo_path> <branch> <projectKey> <ghName>
  _gh-repository-policy-reconcile "$1" "$2" "$3" "$4"
}

_gh-teams-for-key() {
  # Vrátí efektivní hodnotu klíče repository_teams repa (CSV projektu +
  # repository_teams_add nastavení repa; prázdný <ghName> = projekt) z INI
  # dat conf.d (_GH_CONF); existenci projektu ověřuje přes _mhn_for_key.
  # Použití: _gh-teams-for-key <projectKey> <ghName> <base_var pro chybovou hlášku>
  local _key="$1" _gh_name="$2" _base_var="$3" _teams=""
  if _mhn_for_key "$_key" >/dev/null; then
    _gh-conf-effective "$_key" "$_gh_name" repository_teams _teams
    if [[ -n "$_teams" ]]; then
      printf '%s\n' "$_teams"
      return 0
    fi
  fi
  echo "Chyba: Konfigurace '${_base_var}' pro projectKey '$_key' nenalezena. Zkontroluj klíč repository_teams v conf.d/projects/$_key.conf." >&2
  return 1
}

_gh-validate-admin-team() {
  # Ověří admin tým projektu v repository_teams (garantovaný pro každé repo
  # projektu — repository_teams_add jen přidává, proto bez ghName).
  # Použití: _gh-validate-admin-team <projectKey> <base_var pro chybovou hlášku>
  local _key="$1" _base_var="$2" _teams _entry _team _permission _has_admin=false
  local -a _entries
  _teams=$(_gh-teams-for-key "$_key" "" "$_base_var") || return 1

  IFS=',' read -ra _entries <<< "$_teams"
  for _entry in "${_entries[@]}"; do
    # Formát položky sdílí s parserem conf.d (lib/gh-conf.sh: _GH_CONF_TEAM_REGEX).
    if ! _gh-match "$_entry" "$_GH_CONF_TEAM_REGEX"; then
      echo "Chyba: Neplatny zaznam tymu '$_entry' v klici repository_teams projektu '$_key' (conf.d/projects/$_key.conf)." >&2
      echo "       Ocekavany format je team-slug|permission." >&2
      return 1
    fi
    _team="${_entry%%|*}"
    _permission="${_entry##*|}"
    if [[ "$_team" == "$GH_SECURITY_MANAGERS_TEAM" ]]; then
      echo "Chyba: Tým '$GH_SECURITY_MANAGERS_TEAM' do klíče repository_teams projektu '$_key' nepatří (conf.d/projects/$_key.conf)." >&2
      echo "       Je implicitní součástí politiky každého repa (defs/defs.md: ghOrgSecurityManagersTeam) a nekonfiguruje se." >&2
      return 1
    fi
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
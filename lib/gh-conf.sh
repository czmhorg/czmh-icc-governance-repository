#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Bezpečný parser INI konfigurace conf.d/ (projects/, business-services/,
# domains/, profiles/).
# Načítá soubory klíč=hodnota do asociativního pole _GH_CONF bez sourcování.
# Formát a pravidla: docs/readme/README_COMMON.md (sekce Konfigurace projektů).
# Běží při každém startu shellu (source z gh-common-defs.sh) – v load path
# jsou povoleny pouze bash builtiny, žádné spouštění externích procesů.
# Závislosti z gh-common-defs.sh (definovány před sourcováním tohoto modulu):
# _gh-match (sám je jen builtin [[ =~ ]] s lokálním LC_ALL=C) a konfigurační
# proměnné GH_GOVERNANCE_REPO + GH_REPO_PREFIX (rezervovaný projectKey).
[[ -n "${_GH_CONF_LOADED:-}" ]] && \
  declare -F _gh-conf-load >/dev/null && return 0
_GH_CONF_LOADED=1

# Naparsovaná data: klíč "<ns>/<název>/<pole>", např. projects/bbpkid/rulesets.
declare -gA _GH_CONF=()
# Seznam ghProjectKey v pořadí globu projects/*.conf (pro _bb_all_project_keys).
declare -ga _GH_CONF_PROJECT_KEYS=()

# Pole profilu = branch protection API (názvy BRANCH_PROTECT_* malými bez prefixu).
_GH_CONF_PROFILE_FIELDS="required_status_checks enforce_admins dismiss_stale_reviews require_code_owner_reviews required_approving_review_count restrictions allow_force_pushes allow_deletions required_linear_history"
_GH_CONF_PROFILE_BOOL_FIELDS="enforce_admins dismiss_stale_reviews require_code_owner_reviews allow_force_pushes allow_deletions required_linear_history"
_GH_CONF_PROJECT_FIELDS="display_name domain rulesets repository_teams repository_creators repository_archivers"
# Nepovinná pole projektu; přítomný klíč musí mít neprázdnou hodnotu.
_GH_CONF_PROJECT_OPT_FIELDS="description"
# Formát hodnoty klíče domain projektu: <MHN>/<typ> (odkaz na domains/<MHN>/<typ>.conf).
_GH_CONF_DOMAIN_REF_REGEX='^[A-Z][A-Z0-9]*/[a-z][a-z0-9-]*$'
# Pole profilu mimo branch protection API: cílení rulesetu (vzor větví pro
# conditions.ref_name.include; viz docs/implementovano/prechod-rulesets.md).
_GH_CONF_PROFILE_RULESET_FIELDS="branches"
_GH_CONF_LOGIN_REGEX='^[[:alnum:]]([[:alnum:]-]{0,37}[[:alnum:]])?$'
_GH_CONF_TEAM_REGEX='^[[:alnum:]][[:alnum:]_.-]*\|(pull|triage|push|maintain|admin|read|write)$'
_GH_CONF_NAME_REGEX='^[[:alnum:]][[:alnum:]_.-]*$'
# Položka klíče rulesets: <profil> nebo <profil>|jenkins; jméno profilu musí
# odpovídat regexu názvu souboru profiles/*.conf (viz _gh-conf-load).
_GH_CONF_RULESET_ITEM_REGEX='^[a-z][a-z0-9_-]*(\|jenkins)?$'

_gh-conf-err() {
  # Přidá chybu v jednotném formátu do nameref pole chyb.
  # Použití: _gh-conf-err <errors_ref> <relativní cesta> <zpráva>
  declare -n _err_ref="$1"
  _err_ref+=("Chyba: conf.d/$2: $3")
}

_gh-conf-parse-file() {
  # Naparsuje jeden soubor klíč=hodnota do _GH_CONF pod prefix <ns>/<název>/.
  # Ořezává koncové \r (CRLF), čte i poslední řádek bez koncového newline.
  # Použití: _gh-conf-parse-file <soubor> <relativní cesta> <ns> <název> <errors_ref>
  local _file="$1" _rel="$2" _ns="$3" _name="$4" _line _key _value _lineno=0
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    (( _lineno++ ))
    _line="${_line%$'\r'}"
    [[ -z "$_line" || "$_line" == '#'* ]] && continue
    if [[ "$_line" != *=* ]]; then
      _gh-conf-err "$5" "$_rel" "řádek $_lineno: chybí '=' (očekává se 'klíč=hodnota')"
      continue
    fi
    _key="${_line%%=*}"
    _value="${_line#*=}"
    if ! _gh-match "$_key" '^[a-z_][a-z0-9_]*$'; then
      _gh-conf-err "$5" "$_rel" "řádek $_lineno: nevalidní klíč '$_key' (povolený formát: ^[a-z_][a-z0-9_]*\$)"
      continue
    fi
    if [[ "$_value" =~ [[:space:]]$ ]]; then
      _gh-conf-err "$5" "$_rel" "řádek $_lineno: koncový bílý znak za hodnotou klíče '$_key'"
      continue
    fi
    if [[ -v _GH_CONF["$_ns/$_name/$_key"] ]]; then
      _gh-conf-err "$5" "$_rel" "řádek $_lineno: duplicitní klíč '$_key'"
      continue
    fi
    _GH_CONF["$_ns/$_name/$_key"]="$_value"
  done < "$_file"
}

_gh-conf-load-ns() {
  # Načte všechny soubory jednoho namespace; název souboru validuje proti regexu,
  # úspěšně naparsované názvy značí do nameref množiny <seen_ref>.
  # Použití: _gh-conf-load-ns <confd_root> <ns> <name_regex> <errors_ref> <seen_ref>
  local _root="$1" _ns="$2" _name_regex="$3" _f _base _name
  declare -n _seen_ref="$5"
  for _f in "$_root/$_ns"/*.conf; do
    [[ -f "$_f" ]] || continue
    _base="${_f##*/}"
    _name="${_base%.conf}"
    if ! _gh-match "$_name" "$_name_regex"; then
      _gh-conf-err "$4" "$_ns/$_base" "název souboru neodpovídá formátu $_name_regex"
      continue
    fi
    _gh-conf-parse-file "$_f" "$_ns/$_base" "$_ns" "$_name" "$4"
    _seen_ref["$_name"]=1
    [[ "$_ns" == projects ]] && _GH_CONF_PROJECT_KEYS+=("$_name")
  done
  return 0
}

_gh-conf-load-domains() {
  # Načte dvouúrovňový namespace domains/<MHN>/<typ>.conf; název adresáře
  # i souboru validuje proti regexu, úspěšně naparsované domény značí do
  # nameref množiny <seen_ref> pod klíčem "<MHN>/<typ>".
  # Použití: _gh-conf-load-domains <confd_root> <errors_ref> <seen_ref>
  local _root="$1" _f _base _typ _mhn _dir
  declare -n _seen_ref="$3"
  for _f in "$_root/domains"/*/*.conf; do
    [[ -f "$_f" ]] || continue
    _base="${_f##*/}"
    _typ="${_base%.conf}"
    _dir="${_f%/*}"
    _mhn="${_dir##*/}"
    if ! _gh-match "$_mhn" '^[A-Z][A-Z0-9]*$'; then
      _gh-conf-err "$2" "domains/$_mhn/$_base" "název adresáře neodpovídá formátu ^[A-Z][A-Z0-9]*\$"
      continue
    fi
    if ! _gh-match "$_typ" '^[a-z][a-z0-9-]*$'; then
      _gh-conf-err "$2" "domains/$_mhn/$_base" "název souboru neodpovídá formátu ^[a-z][a-z0-9-]*\$"
      continue
    fi
    _gh-conf-parse-file "$_f" "domains/$_mhn/$_base" domains "$_mhn/$_typ" "$2"
    _seen_ref["$_mhn/$_typ"]=1
  done
  return 0
}

_gh-conf-validate-csv() {
  # Ověří CSV hodnotu: žádné prázdné položky, každá položka odpovídá regexu.
  # Použití: _gh-conf-validate-csv <hodnota> <regex> <relativní cesta> <klíč> <errors_ref>
  local _rest="$1," _regex="$2" _rel="$3" _keyname="$4" _item _rc=0
  while [[ -n "$_rest" ]]; do
    _item="${_rest%%,*}"
    _rest="${_rest#*,}"
    if [[ -z "$_item" ]]; then
      _gh-conf-err "$5" "$_rel" "klíč '$_keyname' obsahuje prázdnou položku"
      _rc=1
    elif ! _gh-match "$_item" "$_regex"; then
      _gh-conf-err "$5" "$_rel" "nevalidní položka '$_item' v klíči '$_keyname'"
      _rc=1
    fi
  done
  return $_rc
}

_gh-conf-validate-policy-fields() {
  # Zvaliduje pole ochrany větve pod prefixem <ns/název> v _GH_CONF;
  # všechna pole jsou povinná a neprázdná.
  # Použití: _gh-conf-validate-policy-fields <ns/název> <relativní cesta> <errors_ref>
  local _prefix="$1" _rel="$2" _field _value
  for _field in $_GH_CONF_PROFILE_FIELDS; do
    if [[ ! -v _GH_CONF["$_prefix/$_field"] ]]; then
      _gh-conf-err "$3" "$_rel" "chybí povinný klíč '$_field'"
      continue
    fi
    _value="${_GH_CONF[$_prefix/$_field]}"
    if [[ -z "$_value" ]]; then
      _gh-conf-err "$3" "$_rel" "klíč '$_field' má prázdnou hodnotu"
    elif [[ " $_GH_CONF_PROFILE_BOOL_FIELDS " == *" $_field "* ]]; then
      case "$_value" in
        true|false) ;;
        *) _gh-conf-err "$3" "$_rel" "klíč '$_field' smí mít jen hodnotu 'true' nebo 'false' (je '$_value')" ;;
      esac
    elif [[ "$_field" == required_approving_review_count && ! "$_value" =~ ^[0-9]+$ ]]; then
      _gh-conf-err "$3" "$_rel" "klíč '$_field' musí být nezáporné číslo (je '$_value')"
    fi
  done
  return 0
}

_gh-conf-validate-profile() {
  # Zvaliduje profiles/<název>.conf: povinná pole a formáty, neznámé klíče.
  # Použití: _gh-conf-validate-profile <název> <errors_ref>
  local _name="$1" _rel="profiles/$1.conf" _key _field _value
  _gh-conf-validate-policy-fields "profiles/$_name" "$_rel" "$2"
  for _key in "${!_GH_CONF[@]}"; do
    [[ "$_key" == "profiles/$_name/"* ]] || continue
    _field="${_key##*/}"
    [[ " $_GH_CONF_PROFILE_FIELDS $_GH_CONF_PROFILE_RULESET_FIELDS " == *" $_field "* ]] || \
      _gh-conf-err "$2" "$_rel" "neznámý klíč '$_field'"
  done
  if [[ ! -v _GH_CONF["profiles/$_name/branches"] ]]; then
    _gh-conf-err "$2" "$_rel" "chybí povinný klíč 'branches'"
  else
    _value="${_GH_CONF[profiles/$_name/branches]}"
    if [[ -z "$_value" ]]; then
      _gh-conf-err "$2" "$_rel" "klíč 'branches' má prázdnou hodnotu"
    elif [[ "$_value" == *[[:space:]]* || "$_value" == *,* ]]; then
      _gh-conf-err "$2" "$_rel" "klíč 'branches' musí být jediný vzor větví bez mezer a čárek (je '$_value')"
    fi
  fi
  return 0
}

_gh-conf-validate-bs() {
  # Zvaliduje business-services/<MHN>.conf: povinné klíče, neznámé klíče.
  # Použití: _gh-conf-validate-bs <MHN> <errors_ref>
  local _mhn="$1" _rel="business-services/$1.conf" _key _field
  for _field in display_name department; do
    [[ -n "${_GH_CONF[business-services/$_mhn/$_field]:-}" ]] || \
      _gh-conf-err "$2" "$_rel" "chybí povinný klíč '$_field' (nebo má prázdnou hodnotu)"
  done
  for _key in "${!_GH_CONF[@]}"; do
    [[ "$_key" == "business-services/$_mhn/"* ]] || continue
    _field="${_key##*/}"
    [[ " display_name department " == *" $_field "* ]] || \
      _gh-conf-err "$2" "$_rel" "neznámý klíč '$_field'"
  done
  return 0
}

_gh-conf-validate-domain() {
  # Zvaliduje domains/<MHN>/<typ>.conf: odkaz na business service, neznámé
  # klíče, login. Žádné povinné klíče — prázdný soubor je validní.
  # Použití: _gh-conf-validate-domain <MHN/typ> <errors_ref> <bs_seen_ref>
  local _domain="$1" _mhn="${1%%/*}" _rel="domains/$1.conf" _key _field _login
  declare -n _vd_bs="$3"
  [[ -v _vd_bs["$_mhn"] ]] || \
    _gh-conf-err "$2" "$_rel" "adresář '$_mhn' neodkazuje na existující business-services/$_mhn.conf"
  for _key in "${!_GH_CONF[@]}"; do
    [[ "$_key" == "domains/$_domain/"* ]] || continue
    _field="${_key##*/}"
    [[ "$_field" == jenkins_user ]] || \
      _gh-conf-err "$2" "$_rel" "neznámý klíč '$_field'"
  done
  if [[ -v _GH_CONF["domains/$_domain/jenkins_user"] ]]; then
    _login="${_GH_CONF[domains/$_domain/jenkins_user]}"
    if ! _gh-match "$_login" "$_GH_CONF_LOGIN_REGEX" || [[ "$_login" == *--* ]]; then
      _gh-conf-err "$2" "$_rel" "nevalidní GitHub login '$_login' v klíči 'jenkins_user'"
    fi
  fi
  return 0
}

_gh-conf-validate-project() {
  # Zvaliduje projects/<key>.conf: povinné klíče, neznámé klíče, odkazy, formáty.
  # Použití: _gh-conf-validate-project <key> <errors_ref> <profiles_seen_ref> <domains_seen_ref>
  local _pk="$1" _rel="projects/$1.conf" _field _key _value _domain _profile _item _rest
  local -A _rs_seen=()
  declare -n _vp_profiles="$3" _vp_domains="$4"
  for _field in $_GH_CONF_PROJECT_FIELDS; do
    [[ -n "${_GH_CONF[projects/$_pk/$_field]:-}" ]] || \
      _gh-conf-err "$2" "$_rel" "chybí povinný klíč '$_field' (nebo má prázdnou hodnotu)"
  done
  for _field in $_GH_CONF_PROJECT_OPT_FIELDS; do
    if [[ -v _GH_CONF["projects/$_pk/$_field"] && -z "${_GH_CONF[projects/$_pk/$_field]}" ]]; then
      _gh-conf-err "$2" "$_rel" "klíč '$_field' má prázdnou hodnotu"
    fi
  done
  for _key in "${!_GH_CONF[@]}"; do
    [[ "$_key" == "projects/$_pk/"* ]] || continue
    _field="${_key##*/}"
    [[ " $_GH_CONF_PROJECT_FIELDS $_GH_CONF_PROJECT_OPT_FIELDS " == *" $_field "* ]] || \
      _gh-conf-err "$2" "$_rel" "neznámý klíč '$_field'"
  done
  _domain="${_GH_CONF[projects/$_pk/domain]:-}"
  if [[ -n "$_domain" ]]; then
    if ! _gh-match "$_domain" "$_GH_CONF_DOMAIN_REF_REGEX"; then
      _gh-conf-err "$2" "$_rel" "klíč 'domain' musí mít tvar <MHN>/<typ> (je '$_domain')"
    elif [[ ! -v _vp_domains["$_domain"] ]]; then
      _gh-conf-err "$2" "$_rel" "domain '$_domain' neodkazuje na existující domains/$_domain.conf"
    fi
  fi
  _value="${_GH_CONF[projects/$_pk/repository_teams]:-}"
  if [[ -n "$_value" ]] && _gh-conf-validate-csv "$_value" "$_GH_CONF_TEAM_REGEX" "$_rel" repository_teams "$2"; then
    [[ "$_value," == *'|admin,'* ]] || \
      _gh-conf-err "$2" "$_rel" "repository_teams neobsahuje žádný tým s právem 'admin'"
    # ghOrgSecurityManagersTeam (defs/defs.md) je implicitní součást politiky
    # a do konfigurace se nezapisuje.
    [[ ",$_value," != *",${GH_SECURITY_MANAGERS_TEAM}|"* ]] || \
      _gh-conf-err "$2" "$_rel" "repository_teams obsahuje tým '${GH_SECURITY_MANAGERS_TEAM}' — je implicitní součástí politiky a nekonfiguruje se"
  fi
  _value="${_GH_CONF[projects/$_pk/repository_creators]:-}"
  [[ -z "$_value" ]] || _gh-conf-validate-csv "$_value" "$_GH_CONF_NAME_REGEX" "$_rel" repository_creators "$2"
  _value="${_GH_CONF[projects/$_pk/repository_archivers]:-}"
  [[ -z "$_value" ]] || _gh-conf-validate-csv "$_value" "$_GH_CONF_NAME_REGEX" "$_rel" repository_archivers "$2"
  if [[ -v _GH_CONF["projects/$_pk/rulesets"] ]] && \
     _gh-conf-validate-csv "${_GH_CONF[projects/$_pk/rulesets]}" "$_GH_CONF_RULESET_ITEM_REGEX" "$_rel" rulesets "$2"; then
    _rest="${_GH_CONF[projects/$_pk/rulesets]},"
    while [[ -n "$_rest" ]]; do
      _item="${_rest%%,*}"
      _rest="${_rest#*,}"
      _profile="${_item%%|*}"
      [[ -v _vp_profiles["$_profile"] ]] || \
        _gh-conf-err "$2" "$_rel" "položka '$_item' v klíči 'rulesets' neodkazuje na existující profiles/$_profile.conf"
      if [[ -v _rs_seen["$_profile"] ]]; then
        _gh-conf-err "$2" "$_rel" "duplicitní profil '$_profile' v klíči 'rulesets'"
      fi
      _rs_seen["$_profile"]=1
      if [[ "$_item" == *'|jenkins' && -n "$_domain" && -v _vp_domains["$_domain"] && \
            ! -v _GH_CONF["domains/$_domain/jenkins_user"] ]]; then
        _gh-conf-err "$2" "$_rel" "položka '$_item' v klíči 'rulesets' má atribut 'jenkins', ale doména '$_domain' nemá klíč 'jenkins_user'"
      fi
    done
  fi
}

_gh-conf-reserved-project-key() {
  # Naplní nameref rezervovaným ghProjectKey odvozeným z názvu gov repa:
  # z GH_GOVERNANCE_REPO ustřihne prefix "<GH_REPO_PREFIX>-" a vezme první
  # segment do další pomlčky — shodná derivace jako rozklad názvu repa
  # v _gh-repo-resolve, projekt s tímto klíčem by proto byl od gov repa
  # nerozlišitelný (defs/defs-governance-repo.md). Nemá-li název gov repa
  # tvar <prefix>-<x>-<y>, kolize nemůže nastat a nameref zůstane prázdný.
  # Použití: local _r; _gh-conf-reserved-project-key _r
  declare -n _crpk_ref="$1"
  local _rest
  _crpk_ref=""
  [[ -n "${GH_REPO_PREFIX:-}" && "${GH_GOVERNANCE_REPO:-}" == "${GH_REPO_PREFIX}-"* ]] \
    || return 0
  _rest="${GH_GOVERNANCE_REPO#"${GH_REPO_PREFIX}-"}"
  [[ "$_rest" == *-* ]] || return 0
  _crpk_ref="${_rest%%-*}"
  return 0
}

_gh-conf-load() {
  # Načte a zvaliduje celou INI konfiguraci conf.d do _GH_CONF (bez source).
  # Sbírá všechny chyby najednou; při jakékoli chybě je vypíše na stderr,
  # vyprázdní data a vrátí 1. Úspěch značí _GH_CONF_DATA_LOADED=1.
  # Použití: _gh-conf-load <confd_root>
  local _root="$1" _name _reserved
  local -a _errors=()
  local -A _profiles_seen=() _bs_seen=() _domains_seen=() _projects_seen=()
  _GH_CONF=()
  _GH_CONF_PROJECT_KEYS=()
  unset _GH_CONF_DATA_LOADED
  _gh-conf-load-ns "$_root" profiles '^[a-z][a-z0-9_-]*$' _errors _profiles_seen
  _gh-conf-load-ns "$_root" business-services '^[A-Z][A-Z0-9]*$' _errors _bs_seen
  _gh-conf-load-domains "$_root" _errors _domains_seen
  _gh-conf-load-ns "$_root" projects '^[a-z0-9]{1,46}$' _errors _projects_seen
  for _name in "${!_profiles_seen[@]}"; do
    _gh-conf-validate-profile "$_name" _errors
  done
  for _name in "${!_bs_seen[@]}"; do
    _gh-conf-validate-bs "$_name" _errors
  done
  for _name in "${!_domains_seen[@]}"; do
    _gh-conf-validate-domain "$_name" _errors _bs_seen
  done
  _gh-conf-reserved-project-key _reserved
  for _name in "${_GH_CONF_PROJECT_KEYS[@]}"; do
    if [[ -n "$_reserved" && "$_name" == "$_reserved" ]]; then
      _gh-conf-err _errors "projects/$_name.conf" \
        "projectKey '$_name' je rezervovaný — kolize s gov repem '$GH_GOVERNANCE_REPO'"
    fi
    _gh-conf-validate-project "$_name" _errors _profiles_seen _domains_seen
  done
  [[ ${#_GH_CONF_PROJECT_KEYS[@]} -gt 0 ]] || \
    _errors+=("Chyba: conf.d/projects/ neobsahuje žádný soubor <ghProjectKey>.conf")
  if [[ ${#_errors[@]} -gt 0 ]]; then
    printf '%s\n' "${_errors[@]}" >&2
    printf 'Konfigurace conf.d nebyla načtena (chyb: %d).\n' "${#_errors[@]}" >&2
    _GH_CONF=()
    _GH_CONF_PROJECT_KEYS=()
    return 1
  fi
  _GH_CONF_DATA_LOADED=1
}

#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Bypass týmy v reconcile (defs/defs.md: bypass tym, Report kontroly
# konzistence; docs/navrh/bypass-pres-tym.md): bypass rulesetů dostává účet
# výhradně přes tým <GH_BYPASS_TEAM_PREFIX><login> (actor Team/always).
# Denní kontrola pro bota a Jenkins login každé domény, na kterou odkazuje
# projekt: chybějící tým založí (PAT bota: fine-grained Members: write nebo
# classic admin:org), ověří
# členství loginu (chybí → error), cizí členy (warning) a popis (warning);
# selhání API = error „kontrola bypass tymu selhala". Běží před hlavní
# smyčkou reconcile, aby týmy existovaly dřív, než smyčka staví payloady
# rulesetů (cache ID v lib/gh-repository-policy.sh).
# Závislosti: gh-common-defs.sh (_require_vars), lib/gh-conf.sh (_GH_CONF,
# _GH_CONF_PROJECT_KEYS), lib/gh-repository-policy.sh (_gh-bypass-team-*),
# lib/gh-governance-report.sh (_gh-governance-report-add).
[[ -n "${_GH_GOVERNANCE_BYPASS_TEAM_LOADED:-}" ]] && \
  declare -F _gh-governance-reconcile-bypass-teams >/dev/null && return 0
_GH_GOVERNANCE_BYPASS_TEAM_LOADED=1

_gh-governance-bypass-team-logins() {
  # Vypíše unikátní loginy, které potřebují bypass tým: governance bot a
  # jenkins_user každé domény, na kterou odkazuje aspoň jeden projekt
  # (dedup case-insensitive, bot první). Čistá funkce nad _GH_CONF.
  # Použití: _gh-governance-bypass-team-logins
  local -a _logins=()
  local _key _domain _login _l _dup
  [[ -n "${GH_GOVERNANCE_BOT_USER:-}" ]] && _logins+=("$GH_GOVERNANCE_BOT_USER")
  for _key in "${_GH_CONF_PROJECT_KEYS[@]}"; do
    _domain="${_GH_CONF[projects/$_key/domain]:-}"
    [[ -n "$_domain" ]] || continue
    _login="${_GH_CONF[domains/$_domain/jenkins_user]:-}"
    [[ -n "$_login" ]] || continue
    _dup=0
    for _l in "${_logins[@]}"; do
      [[ "${_l,,}" == "${_login,,}" ]] && { _dup=1; break; }
    done
    [[ $_dup -eq 0 ]] && _logins+=("$_login")
  done
  [[ ${#_logins[@]} -gt 0 ]] && printf '%s\n' "${_logins[@]}"
  return 0
}

_gh-governance-bypass-team-members-check() {
  # Čistá kontrola členů bypass týmu nad výpisem loginů (řádek = aktivní
  # člen): řádek MISSING, není-li <login> členem, a řádek za každého cizího
  # člena (mimo <login> a governance bota; case-insensitive). Prázdný výstup
  # = v pořádku.
  # Použití: _gh-governance-bypass-team-members-check <výpis členů> <login>
  local _listing="$1" _login="$2" _member _found=0
  while IFS= read -r _member; do
    [[ -n "$_member" ]] || continue
    if [[ "${_member,,}" == "${_login,,}" ]]; then
      _found=1
    elif [[ "${_member,,}" != "${GH_GOVERNANCE_BOT_USER,,}" ]]; then
      printf '%s\n' "$_member"
    fi
  done <<< "$_listing"
  [[ $_found -eq 1 ]] || printf 'MISSING\n'
  return 0
}

_gh-governance-bypass-team-check() {
  # Kontrola (a založení) bypass týmu jednoho účtu s položkami reportu:
  # založen → info; login není aktivní člen → error (bypass neplatí); cizí
  # člen → warning; prázdný popis → warning; selhání API → error. Vždy rc 0
  # – běh pokračuje dalším týmem.
  # Použití: _gh-governance-bypass-team-check <login>
  local _login="$1" _slug _id _listing _line _err_file
  _slug=$(_gh-bypass-team-slug "$_login")
  _err_file=$(mktemp) || return 1
  if ! _gh-bypass-team-ensure "$_login" _id 2>"$_err_file"; then
    _gh-governance-report-add error "kontrola bypass tymu selhala" "$_slug" \
      "$(tail -n 1 "$_err_file")"
    rm -f "$_err_file"
    return 0
  fi
  [[ -v _GH_BYPASS_TEAM_CREATED["$_slug"] ]] && \
    _gh-governance-report-add info "bypass tym zalozen" "$_slug" \
      "jediny clen '$_login', bot maintainer, popis doplnen"
  # GET members vrací jen aktivní členy (pozvánky pending chybí).
  if ! _listing=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
      "orgs/$GITHUB_ORG/teams/$_slug/members" --paginate --jq '.[].login' 2>"$_err_file"); then
    _gh-governance-report-add error "kontrola bypass tymu selhala" "$_slug" \
      "cteni clenu tymu selhalo: $(tail -n 1 "$_err_file")"
    rm -f "$_err_file"
    return 0
  fi
  rm -f "$_err_file"
  while IFS= read -r _line; do
    [[ -n "$_line" ]] || continue
    if [[ "$_line" == MISSING ]]; then
      _gh-governance-report-add error "bypass tym bez clena" "$_slug" \
        "ucet '$_login' neni aktivnim clenem – bypass neplati (zapisy skonci HTTP 409); pridej ho (org owner nebo bot jako maintainer)"
    else
      _gh-governance-report-add warning "bypass tym s cizim clenem" "$_slug" \
        "clen '$_line' ziskava bypass vsech rulesetu, kde tym je – odeber ho"
    fi
  done <<< "$(_gh-governance-bypass-team-members-check "$_listing" "$_login")"
  if [[ -z "${_GH_BYPASS_TEAM_DESC_CACHE[$_slug]:-}" ]]; then
    _gh-governance-report-add warning "bypass tym bez popisu" "$_slug" \
      "doplň popis: \"$(_gh-bypass-team-description "$_login")\""
  fi
  return 0
}

_gh-governance-reconcile-bypass-teams() {
  # Run-level kontrola bypass týmů všech účtů s bypassem (bot + Jenkins
  # loginy domén projektů). rc 1 jen při chybějící konfiguraci (error hlásí
  # volající); selhání jednotlivého týmu jde do reportu, rc 0.
  # Použití: _gh-governance-reconcile-bypass-teams
  local _login
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_GOVERNANCE_BOT_USER GH_BYPASS_TEAM_PREFIX || return 1
  while IFS= read -r _login; do
    [[ -n "$_login" ]] || continue
    _gh-governance-bypass-team-check "$_login"
  done < <(_gh-governance-bypass-team-logins)
  return 0
}

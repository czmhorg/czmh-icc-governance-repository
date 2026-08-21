#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Ochrana gov repa (docs/navrh/ochrana-gov-repa.md): očekávaný stav rulesetu
# výchozí větve gov repa jako čistá funkce bez sítě – stejný payload používá
# gov-init.sh při založení/aktualizaci a později detekce driftu v reconcile.
# Ruleset je mimo prefix GH_RULESET_PREFIX: není to politika spravovaného
# repa z conf.d a apply/check logika lib/gh-repository-policy.sh ho ignoruje.
# Závislosti: žádné (hodnoty bypassu a actor_id dodá volající).
[[ -n "${_GH_GOVERNANCE_PROTECTION_LOADED:-}" ]] && \
  declare -F _gh-governance-ruleset-payload >/dev/null && return 0
_GH_GOVERNANCE_PROTECTION_LOADED=1

_GH_GOVERNANCE_RULESET_NAME=gov-default-branch

_gh-governance-ruleset-payload() {
  # Sestaví JSON payload rulesetu gov-default-branch (repo-level, cílí výchozí
  # větev). Fáze „bezpečnostní síť": výchozí větev nejde smazat ani přepsat
  # historii (deletion, non_fast_forward); bez pravidla pull_request – gov-sync
  # i bot pushují jako dosud. Bypass actors se nastavují už teď, aby fáze
  # „povinný PR" jen přidala pravidla: bot (User, always – zápis state/)
  # a podle <admin_bypass> volitelně admini repa (RepositoryRole 5,
  # pull_request). required_linear_history se záměrně nepoužívá – gov repo
  # povoluje jen merge commit a lineární historie merge commity zakazuje
  # (docs/github/rulesets-required-linear-history-vs-merge-commit.md).
  # Použití: _gh-governance-ruleset-payload <bot_actor_id> <admin_bypass: none|pull_request>
  local _bot_id="$1" _admin_bypass="$2" _bypass_actors
  if [[ ! "$_bot_id" =~ ^[0-9]+$ ]]; then
    echo "Chyba: Ruleset '$_GH_GOVERNANCE_RULESET_NAME' vyžaduje číselné actor_id bota (je '${_bot_id:-<prázdné>}')." >&2
    return 1
  fi
  _bypass_actors='{ "actor_id": '"$_bot_id"', "actor_type": "User", "bypass_mode": "always" }'
  case "$_admin_bypass" in
    pull_request)
      _bypass_actors+=', { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" }' ;;
    none) ;;
    *)
      echo "Chyba: GH_GOVERNANCE_ADMIN_BYPASS musí být pull_request nebo none (je '$_admin_bypass')." >&2
      return 1 ;;
  esac

  printf '{
  "name": "%s",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [%s],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}' "$_GH_GOVERNANCE_RULESET_NAME" "$_bypass_actors"
}

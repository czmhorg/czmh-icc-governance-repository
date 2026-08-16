#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Společný bootstrap entry skriptů gov-*.sh: najde kořen stromu se
# gh-common-defs.sh (dev repo: governance/bin/../.., gov repo po gov-sync:
# bin/..), sourcne konfiguraci a governance moduly a ověří načtení conf.d.
# Sourcuje se, nespouští: source "$(dirname "$0")/gov-env.sh"

_GOV_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GOV_ROOT=""
for _gov_candidate in "$_GOV_BIN_DIR/.." "$_GOV_BIN_DIR/../.."; do
  if [[ -f "$_gov_candidate/gh-common-defs.sh" ]]; then
    _GOV_ROOT="$(cd "$_gov_candidate" && pwd)"
    break
  fi
done
unset _gov_candidate
if [[ -z "$_GOV_ROOT" ]]; then
  echo "Chyba: gh-common-defs.sh nenalezen vedle bin/ – spouštěj skripty z checkoutu gov repa (nebo dev repa)." >&2
  exit 1
fi

source "$_GOV_ROOT/gh-common-defs.sh"
source "$_GOV_ROOT/lib/gh-repository-policy.sh"
source "$_GOV_ROOT/lib/gh-governance-state.sh"
source "$_GOV_ROOT/lib/gh-governance-repo-ops.sh"
source "$_GOV_ROOT/lib/gh-governance-issue.sh"
source "$_GOV_ROOT/lib/gh-governance-report.sh"
source "$_GOV_ROOT/lib/gh-governance-reconcile.sh"

if [[ -z "${_GH_CONF_DATA_LOADED:-}" ]]; then
  echo "Chyba: Konfigurace conf.d není načtena – governance operaci nelze spustit." >&2
  exit 1
fi

_gov-entry-main() {
  # Společné tělo entry skriptů new/archive/unarchive: režimy
  #   <projectKey> <ghName>                       lokální aplikační cesta,
  #   --parse                                     parse job (issue event),
  #   --execute <projectKey> <ghName> <issueNum>  execute job (komentář+close).
  # Použití: _gov-entry-main <op_funkce> <auth_klíč> <hláška úspěchu> [args...]
  local _op="$1" _field="$2" _success_label="$3" _a _mode=local _url
  shift 3
  local -a _pos=()
  for _a in "$@"; do
    case "$_a" in
      --parse)   _mode=parse ;;
      --execute) _mode=execute ;;
      --*) echo "Chyba: Neznámá volba '$_a' (viz --help)." >&2; return 1 ;;
      *)   _pos+=("$_a") ;;
    esac
  done
  case "$_mode" in
    parse)
      if [[ ${#_pos[@]} -ne 0 ]]; then
        echo "Chyba: --parse nemá poziční argumenty." >&2
        return 1
      fi
      _gh-governance-issue-parse-step "$_field"
      ;;
    execute)
      if [[ ${#_pos[@]} -ne 3 ]]; then
        echo "Chyba: --execute vyžaduje <projectKey> <ghName> <issueNumber>." >&2
        return 1
      fi
      if "$_op" "${_pos[0]}" "${_pos[1]}"; then
        _url="https://${GITHUB_ORG_HOSTNAME}/${GITHUB_ORG}/$(_gh-governance-repo-name "${_pos[0]}" "${_pos[1]}")"
        _gh-governance-issue-close-done "${_pos[2]}" "$_success_label: $_url"
      else
        # Provozní selhání: issue zůstává otevřené, workflow spadne (viditelnost).
        GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "${_pos[2]}" \
          --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
          --body "Provedení selhalo – viz log běhu workflow." >/dev/null
        return 1
      fi
      ;;
    local)
      if [[ ${#_pos[@]} -ne 2 ]]; then
        echo "Chyba: Očekávám <projectKey> <ghName> (viz --help)." >&2
        return 1
      fi
      "$_op" "${_pos[0]}" "${_pos[1]}"
      ;;
  esac
}

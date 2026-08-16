#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Entry skript workflow track-delete; spustitelný i lokálně nad checkoutem
# gov repa. Vlastní dispatch (ne _gov-entry-main): jiná parse funkce, bez
# autorizace autora a rc 2 operace (repo přežilo timeout) není selhání.

if [[ "${1:-}" == "--help" ]]; then
  echo "Syntaxe: gov-track-delete.sh <projectKey> <ghName>"
  echo "         gov-track-delete.sh --parse"
  echo "         gov-track-delete.sh --execute <projectKey> <ghName> <issueNumber>"
  echo "Účel:    Sleduje zánik repa po žádosti o smazání (track-delete issue):"
  echo "         polluje existenci repa a po prokázaném HTTP 404 uklidí"
  echo "         ukazatel /state/ i řádek completion manifestu. Nic nemaže."
  echo ""
  echo "Parametry:"
  echo "  projectKey   Klíč projektu (formát viz defs/defs.md)."
  echo "  ghName       Název repa bez prefixů (formát viz defs/defs.md)."
  echo ""
  echo "Volby:"
  echo "  --parse      Parse job workflow: čte issue event z GITHUB_EVENT_PATH"
  echo "               (řádky repo_path= a delete_issue=) a zapíše výstupy do"
  echo "               GITHUB_OUTPUT. Odmítnutí zavře issue. Bez autorizace"
  echo "               autora – workflow nic na GitHubu nemaže."
  echo "  --execute    Execute job workflow: poll existence repa; úklid + zavření"
  echo "               issue, nebo komentář (repo stále existuje, dořeší reconcile)."
  echo ""
  echo "Příklad: GH_CONFD_ROOT=~/gov-checkout/conf.d bash governance/bin/gov-track-delete.sh bbpkid stara-app"
  echo ""
  echo "Práva:   push do gov repa (state/), read na repech organizace."
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/gov-env.sh"

_gov_td_mode=local
_gov_td_pos=()
for _gov_td_a in "$@"; do
  case "$_gov_td_a" in
    --parse)   _gov_td_mode=parse ;;
    --execute) _gov_td_mode=execute ;;
    --*) echo "Chyba: Neznámá volba '$_gov_td_a' (viz --help)." >&2; exit 1 ;;
    *)   _gov_td_pos+=("$_gov_td_a") ;;
  esac
done

case "$_gov_td_mode" in
  parse)
    if [[ ${#_gov_td_pos[@]} -ne 0 ]]; then
      echo "Chyba: --parse nemá poziční argumenty." >&2
      exit 1
    fi
    _gh-governance-issue-parse-step-track-delete
    ;;
  execute)
    if [[ ${#_gov_td_pos[@]} -ne 3 ]]; then
      echo "Chyba: --execute vyžaduje <projectKey> <ghName> <issueNumber>." >&2
      exit 1
    fi
    _gh-governance-track-delete "${_gov_td_pos[0]}" "${_gov_td_pos[1]}"
    _gov_td_rc=$?
    if [[ $_gov_td_rc -eq 0 ]]; then
      _gh-governance-issue-close-done "${_gov_td_pos[2]}" \
        "Repo zaniklo; ukazatel /state/ i řádek completion manifestu uklizeny."
    elif [[ $_gov_td_rc -eq 2 ]]; then
      # Není selhání: issue zůstává otevřené, dořeší ho noční reconcile.
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "${_gov_td_pos[2]}" \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
        --body "Repo po ${GH_GOVERNANCE_TRACK_DELETE_TIMEOUT_MIN} min stále existuje – issue zůstává otevřené, dořeší ho noční reconcile." >/dev/null
      exit 0
    else
      # Provozní selhání: issue zůstává otevřené, workflow spadne (viditelnost).
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "${_gov_td_pos[2]}" \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
        --body "Provedení selhalo – viz log běhu workflow." >/dev/null
      exit 1
    fi
    ;;
  local)
    if [[ ${#_gov_td_pos[@]} -ne 2 ]]; then
      echo "Chyba: Očekávám <projectKey> <ghName> (viz --help)." >&2
      exit 1
    fi
    _gh-governance-track-delete "${_gov_td_pos[0]}" "${_gov_td_pos[1]}"
    ;;
esac

#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Entry skript workflow move-repository; spustitelný i lokálně nad checkoutem
# gov repa. Vlastní dispatch (ne _gov-entry-main): jiná parse funkce (tělo
# s new_project_key= a redirect=), dvojí autorizace a execute s pěti
# argumenty. Validační odmítnutí zavírá issue not_planned s typem chyby
# (_gh-governance-move-run vrací typ v summary[error_type]).

if [[ "${1:-}" == "--help" ]]; then
  echo "Syntaxe: gov-move-repository.sh <projectKey> <ghName> <newProjectKey> [--redirect]"
  echo "         gov-move-repository.sh --parse"
  echo "         gov-move-repository.sh --execute <projectKey> <ghName> <newProjectKey> <keep|cancel> <issueNumber>"
  echo "Účel:    Přesune spravované repo mezi projekty řízeným přejmenováním:"
  echo "         rename + přepnutí topicu ghp-* + politika cílového projektu"
  echo "         + přesun ukazatele /state/ a řádku completion manifestu."
  echo "         Výchozí chování ruší redirect starého jména (dočasné repo"
  echo "         + žádost o smazání); --redirect / keep ho ponechá."
  echo ""
  echo "Parametry:"
  echo "  projectKey      Klíč zdrojového projektu (formát viz defs/defs.md)."
  echo "  ghName          Název repa bez prefixů (přesunem se nemění)."
  echo "  newProjectKey   Klíč cílového projektu (conf.d/projects/<klíč>.conf)."
  echo ""
  echo "Volby:"
  echo "  --redirect   Lokální režim: ponechá redirect starého jména."
  echo "  --parse      Parse job workflow: čte issue event z GITHUB_EVENT_PATH,"
  echo "               autorizuje autora proti repository_archivers zdrojového"
  echo "               a repository_creators cílového projektu a zapíše výstupy"
  echo "               do GITHUB_OUTPUT. Odmítnutí zavře issue."
  echo "  --execute    Execute job workflow: provede přesun a zavře issue"
  echo "               komentářem se shrnutím, změnami a upozorněními."
  echo ""
  echo "Příklad: bash governance/bin/gov-move-repository.sh bbpkid moje-app novyklic"
  echo ""
  echo "Práva:   admin na repu (rename, topicy, politika), push do gov repa (state/),"
  echo "         issues v gov repu a v repu delete-repository (zrušení redirectu)."
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/gov-env.sh"

_gov_mv_mode=local
_gov_mv_redirect=cancel
_gov_mv_pos=()
for _gov_mv_a in "$@"; do
  case "$_gov_mv_a" in
    --parse)    _gov_mv_mode=parse ;;
    --execute)  _gov_mv_mode=execute ;;
    --redirect) _gov_mv_redirect=keep ;;
    --*) echo "Chyba: Neznámá volba '$_gov_mv_a' (viz --help)." >&2; exit 1 ;;
    *)   _gov_mv_pos+=("$_gov_mv_a") ;;
  esac
done

case "$_gov_mv_mode" in
  parse)
    if [[ ${#_gov_mv_pos[@]} -ne 0 ]]; then
      echo "Chyba: --parse nemá poziční argumenty." >&2
      exit 1
    fi
    _gh-governance-issue-parse-step-move
    ;;
  execute)
    if [[ ${#_gov_mv_pos[@]} -ne 5 ]]; then
      echo "Chyba: --execute vyžaduje <projectKey> <ghName> <newProjectKey> <keep|cancel> <issueNumber>." >&2
      exit 1
    fi
    # Hodnoty přicházejí z outputs parse jobu; přesto validace před použitím.
    if ! _gh-match "${_gov_mv_pos[0]}" "$_GH_GOVERNANCE_PROJECT_KEY_REGEX" \
        || ! _gh-match "${_gov_mv_pos[1]}" "$_GH_GHNAME_REGEX" \
        || ! _gh-match "${_gov_mv_pos[2]}" "$_GH_GOVERNANCE_PROJECT_KEY_REGEX"; then
      echo "Chyba: Argumenty --execute nemají platný formát (viz defs/defs.md)." >&2
      exit 1
    fi
    case "${_gov_mv_pos[3]}" in
      keep|cancel) ;;
      *) echo "Chyba: Režim redirectu musí být keep nebo cancel (je '${_gov_mv_pos[3]}')." >&2
         exit 1 ;;
    esac
    if [[ ! "${_gov_mv_pos[4]}" =~ ^[0-9]+$ ]]; then
      echo "Chyba: Číslo issue musí být číselné (je '${_gov_mv_pos[4]}')." >&2
      exit 1
    fi
    declare -A _gov_mv_sum=()
    if _gh-governance-move-run "${_gov_mv_pos[0]}" "${_gov_mv_pos[1]}" \
        "${_gov_mv_pos[2]}" "${_gov_mv_pos[3]}" _gov_mv_sum; then
      _gh-governance-issue-close-done "${_gov_mv_pos[4]}" \
        "$(_gh-governance-move-comment _gov_mv_sum)"
    elif [[ -n "${_gov_mv_sum[error_type]:-}" ]]; then
      # Validační odmítnutí (not_managed, name_taken, capacity_exceeded):
      # issue se zavře not_planned s typem, workflow nespadne.
      _gh-governance-issue-close-rejected "${_gov_mv_pos[4]}" "${_gov_mv_sum[error_type]}"
      exit 0
    else
      # Provozní selhání: issue zůstává otevřené, workflow spadne (viditelnost).
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "${_gov_mv_pos[4]}" \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
        --body "Provedení selhalo – viz log běhu workflow." >/dev/null
      exit 1
    fi
    ;;
  local)
    if [[ ${#_gov_mv_pos[@]} -ne 3 ]]; then
      echo "Chyba: Očekávám <projectKey> <ghName> <newProjectKey> (viz --help)." >&2
      exit 1
    fi
    declare -A _gov_mv_sum=()
    if _gh-governance-move-run "${_gov_mv_pos[0]}" "${_gov_mv_pos[1]}" \
        "${_gov_mv_pos[2]}" "$_gov_mv_redirect" _gov_mv_sum; then
      _gh-governance-move-comment _gov_mv_sum
    else
      exit 1
    fi
    ;;
esac

#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Entry skript workflow rename-repository; spustitelný i lokálně nad
# checkoutem gov repa. Vlastní dispatch podle vzoru gov-move-repository.sh
# (ne _gov-entry-main): parse funkce pro tělo s new_repo_name= a redirect=,
# dvojí autorizace v témže projektu a execute s pěti argumenty. Validační
# odmítnutí zavírá issue not_planned s typem chyby (_gh-governance-move-run
# vrací typ v summary[error_type]); sdílený orchestrátor volá s dstKey ==
# srcKey (docs/navrh/gh-rename.md).

if [[ "${1:-}" == "--help" ]]; then
  echo "Syntaxe: gov-rename-repository.sh <projectKey> <ghName> <newGhName> [--redirect]"
  echo "         gov-rename-repository.sh --parse"
  echo "         gov-rename-repository.sh --execute <projectKey> <ghName> <newGhName> <keep|cancel> <issueNumber>"
  echo "Účel:    Přejmenuje spravované repo uvnitř projektu: rename + efektivní"
  echo "         politika pod novým jménem (odebrání jen dle diffu ukazatele)"
  echo "         + přesun ukazatele /state/ a řádku completion manifestu."
  echo "         Topic ghp-* se nemění. Výchozí chování ruší redirect starého"
  echo "         jména (dočasné repo + žádost o smazání); --redirect / keep ho"
  echo "         ponechá. Archivované repo se na dobu operace dearchivuje."
  echo ""
  echo "Parametry:"
  echo "  projectKey   Klíč projektu (formát viz defs/defs.md; nemění se)."
  echo "  ghName       Dosavadní název repa bez prefixů."
  echo "  newGhName    Nový název repa bez prefixů (formát ghName, výsledný"
  echo "               název <prefix>-<projectKey>-<newGhName> ≤ 100 znaků)."
  echo ""
  echo "Volby:"
  echo "  --redirect   Lokální režim: ponechá redirect starého jména."
  echo "  --parse      Parse job workflow: čte issue event z GITHUB_EVENT_PATH,"
  echo "               autorizuje autora proti repository_archivers i"
  echo "               repository_creators projektu a zapíše výstupy do"
  echo "               GITHUB_OUTPUT. Odmítnutí zavře issue."
  echo "  --execute    Execute job workflow: provede přejmenování a zavře issue"
  echo "               komentářem se shrnutím, změnami a upozorněními."
  echo ""
  echo "Příklad: bash governance/bin/gov-rename-repository.sh bbpkid moje-app moje-aplikace"
  echo ""
  echo "Práva:   admin na repu (rename, politika), push do gov repa (state/),"
  echo "         issues v gov repu a v repu delete-repository (zrušení redirectu)."
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/gov-env.sh"

_gov_rn_mode=local
_gov_rn_redirect=cancel
_gov_rn_pos=()
for _gov_rn_a in "$@"; do
  case "$_gov_rn_a" in
    --parse)    _gov_rn_mode=parse ;;
    --execute)  _gov_rn_mode=execute ;;
    --redirect) _gov_rn_redirect=keep ;;
    --*) echo "Chyba: Neznámá volba '$_gov_rn_a' (viz --help)." >&2; exit 1 ;;
    *)   _gov_rn_pos+=("$_gov_rn_a") ;;
  esac
done

case "$_gov_rn_mode" in
  parse)
    if [[ ${#_gov_rn_pos[@]} -ne 0 ]]; then
      echo "Chyba: --parse nemá poziční argumenty." >&2
      exit 1
    fi
    _gh-governance-issue-parse-step-rename
    ;;
  execute)
    if [[ ${#_gov_rn_pos[@]} -ne 5 ]]; then
      echo "Chyba: --execute vyžaduje <projectKey> <ghName> <newGhName> <keep|cancel> <issueNumber>." >&2
      exit 1
    fi
    # Hodnoty přicházejí z outputs parse jobu; přesto validace před použitím.
    if ! _gh-match "${_gov_rn_pos[0]}" "$_GH_GOVERNANCE_PROJECT_KEY_REGEX" \
        || ! _gh-match "${_gov_rn_pos[1]}" "$_GH_GHNAME_REGEX" \
        || ! _gh-match "${_gov_rn_pos[2]}" "$_GH_GHNAME_REGEX"; then
      echo "Chyba: Argumenty --execute nemají platný formát (viz defs/defs.md)." >&2
      exit 1
    fi
    case "${_gov_rn_pos[3]}" in
      keep|cancel) ;;
      *) echo "Chyba: Režim redirectu musí být keep nebo cancel (je '${_gov_rn_pos[3]}')." >&2
         exit 1 ;;
    esac
    if [[ ! "${_gov_rn_pos[4]}" =~ ^[0-9]+$ ]]; then
      echo "Chyba: Číslo issue musí být číselné (je '${_gov_rn_pos[4]}')." >&2
      exit 1
    fi
    declare -A _gov_rn_sum=()
    if _gh-governance-move-run "${_gov_rn_pos[0]}" "${_gov_rn_pos[1]}" \
        "${_gov_rn_pos[0]}" "${_gov_rn_pos[2]}" "${_gov_rn_pos[3]}" _gov_rn_sum; then
      _gh-governance-issue-close-done "${_gov_rn_pos[4]}" \
        "$(_gh-governance-move-comment _gov_rn_sum)"
    elif [[ -n "${_gov_rn_sum[error_type]:-}" ]]; then
      # Validační odmítnutí (not_managed, name_taken): issue se zavře
      # not_planned s typem, workflow nespadne.
      _gh-governance-issue-close-rejected "${_gov_rn_pos[4]}" "${_gov_rn_sum[error_type]}"
      exit 0
    else
      # Provozní selhání: issue zůstává otevřené, workflow spadne (viditelnost).
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "${_gov_rn_pos[4]}" \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
        --body "Provedení selhalo – viz log běhu workflow." >/dev/null
      exit 1
    fi
    ;;
  local)
    if [[ ${#_gov_rn_pos[@]} -ne 3 ]]; then
      echo "Chyba: Očekávám <projectKey> <ghName> <newGhName> (viz --help)." >&2
      exit 1
    fi
    declare -A _gov_rn_sum=()
    if _gh-governance-move-run "${_gov_rn_pos[0]}" "${_gov_rn_pos[1]}" \
        "${_gov_rn_pos[0]}" "${_gov_rn_pos[2]}" "$_gov_rn_redirect" _gov_rn_sum; then
      _gh-governance-move-comment _gov_rn_sum
    else
      exit 1
    fi
    ;;
esac

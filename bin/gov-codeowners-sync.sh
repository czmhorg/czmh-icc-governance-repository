#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Entry skript workflow codeowners-sync (defs/defs-governance-repo.md,
# codeowners-sync issue); spustitelný i lokálně nad checkoutem gov repa
# (--project). Vlastní dispatch (ne _gov-entry-main): jiná parse funkce,
# bez autorizace autora, issue se zavírá vždy completed s reportem
# v komentáři (i při error položkách), rc 1 při error položce.

if [[ "${1:-}" == "--help" ]]; then
  echo "Syntaxe: gov-codeowners-sync.sh --project <projectKey>"
  echo "         gov-codeowners-sync.sh --parse"
  echo "         gov-codeowners-sync.sh --execute <projectKey> <issueNumber>"
  echo "         gov-codeowners-sync.sh --push <beforeSha>"
  echo "Účel:    Cílená distribuce CODEOWNERS: nad nearchivovanými spravovanými"
  echo "         repy projektu provede tutéž správu .github/CODEOWNERS"
  echo "         a CODEOWNERS_README.md jako daily-reconcile (klíč"
  echo "         pr_reviewers_team) a nic jiného. Report do GITHUB_STEP_SUMMARY"
  echo "         (mimo Actions na stdout)."
  echo ""
  echo "Parametry:"
  echo "  projectKey   Klíč projektu (formát viz defs/defs.md)."
  echo "  issueNumber  Číslo codeowners-sync issue (komentář s reportem + zavření)."
  echo "  beforeSha    SHA před pushem (github.event.before); nulové nebo neznámé"
  echo "               = sync všech projektů."
  echo ""
  echo "Volby:"
  echo "  --project    Lokální běh pro jeden projekt (bez issue)."
  echo "  --parse      Parse job workflow: čte issue event z GITHUB_EVENT_PATH"
  echo "               (řádek project_key=) a zapíše výstupy do GITHUB_OUTPUT."
  echo "               Odmítnutí zavře issue not_planned. Bez autorizace autora."
  echo "  --execute    Execute job workflow (issue): sync projektu, komentář"
  echo "               s reportem, zavření issue completed; rc 1 při error položce."
  echo "  --push       Execute job workflow (push do conf.d/projects/**): projekty"
  echo "               z cest změněných souborů beforeSha..HEAD."
  echo ""
  echo "Příklad: bash governance/bin/gov-codeowners-sync.sh --project bbpkid"
  echo ""
  echo "Práva:   read na repech organizace (výpis, Contents API), zápis obsahu"
  echo "         spravovaných rep (bot = bypass actor rulesetů), issues RW na gov repu."
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/gov-env.sh"

_gov_cs_mode=""
_gov_cs_pos=()
for _gov_cs_a in "$@"; do
  case "$_gov_cs_a" in
    --parse|--execute|--push|--project)
      if [[ -n "$_gov_cs_mode" ]]; then
        echo "Chyba: Zadej jen jeden režim (--parse, --execute, --push nebo --project)." >&2
        exit 1
      fi
      _gov_cs_mode="${_gov_cs_a#--}" ;;
    --*) echo "Chyba: Neznámá volba '$_gov_cs_a' (viz --help)." >&2; exit 1 ;;
    *)   _gov_cs_pos+=("$_gov_cs_a") ;;
  esac
done
if [[ -z "$_gov_cs_mode" ]]; then
  echo "Chyba: Zadej režim --project, --parse, --execute nebo --push (viz --help)." >&2
  exit 1
fi

_gov-cs-require-key() {
  # Obrana proti hodnotám z env: klíč projektu musí mít validní formát.
  # Použití: _gov-cs-require-key <projectKey>
  if ! _gh-match "$1" "$_GH_GOVERNANCE_PROJECT_KEY_REGEX"; then
    echo "Chyba: projectKey '$1' nemá platný formát." >&2
    return 1
  fi
}

_gov-cs-render() {
  # Report běhu do souhrnu workflow (v Actions), jinak na stdout.
  # Použití: _gov-cs-render <report>
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    _gh-governance-report-render "$1" >> "$GITHUB_STEP_SUMMARY"
  else
    _gh-governance-report-render "$1"
  fi
}

_gov-cs-exit-by-report() {
  # rc 1 při error položce v reportu (neúspěch je vidět na běhu workflow).
  # Použití: _gov-cs-exit-by-report <report>
  [[ "$(_gh-governance-report-count error "$1")" -eq 0 ]]
}

case "$_gov_cs_mode" in
  parse)
    if [[ ${#_gov_cs_pos[@]} -ne 0 ]]; then
      echo "Chyba: --parse nemá poziční argumenty." >&2
      exit 1
    fi
    _gh-governance-issue-parse-step-codeowners-sync
    ;;
  execute)
    if [[ ${#_gov_cs_pos[@]} -ne 2 ]]; then
      echo "Chyba: --execute vyžaduje <projectKey> <issueNumber>." >&2
      exit 1
    fi
    _gov-cs-require-key "${_gov_cs_pos[0]}" || exit 1
    if [[ ! "${_gov_cs_pos[1]}" =~ ^[0-9]+$ ]]; then
      echo "Chyba: issueNumber '${_gov_cs_pos[1]}' není číslo." >&2
      exit 1
    fi
    _gov_cs_report=$(mktemp) || exit 1
    _gh-governance-report-init "$_gov_cs_report"
    if ! _gh-governance-codeowners-sync-run "${_gov_cs_pos[0]}"; then
      # Provozní selhání (checkout, výpis rep): issue zůstává otevřené,
      # workflow spadne (viditelnost).
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "${_gov_cs_pos[1]}" \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
        --body "Provedení selhalo – viz log běhu workflow." >/dev/null
      exit 1
    fi
    _gov-cs-render "$_gov_cs_report"
    _gov_cs_run_url="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
    _gov_cs_comment="Distribuce CODEOWNERS projektu '${_gov_cs_pos[0]}' dokončena ($(_gh-governance-report-header "$_gov_cs_report"))."
    # Render bez souhrnu počtů (řádek 1, je v hlavičce) a prázdného řádku za ním.
    _gov_cs_comment+=$'\n\n'"$(_gh-governance-report-render "$_gov_cs_report" | tail -n +3)"
    _gov_cs_comment+=$'\n\n'"Běh workflow: $_gov_cs_run_url"
    _gh-governance-issue-close-done "${_gov_cs_pos[1]}" "$_gov_cs_comment" || exit 1
    _gov-cs-exit-by-report "$_gov_cs_report"
    ;;
  push)
    if [[ ${#_gov_cs_pos[@]} -ne 1 ]]; then
      echo "Chyba: --push vyžaduje <beforeSha>." >&2
      exit 1
    fi
    _gov_cs_before="${_gov_cs_pos[0]}"
    if ! _gh-match "$_gov_cs_before" "$_GH_GOVERNANCE_SHA_REGEX"; then
      echo "Chyba: beforeSha '$_gov_cs_before' není SHA commitu." >&2
      exit 1
    fi
    _gov_cs_root=$(_gh-governance-checkout-root) || exit 1
    _gov_cs_report=$(mktemp) || exit 1
    _gh-governance-report-init "$_gov_cs_report"
    _gov_cs_keys=()
    if [[ "$_gov_cs_before" == "$(printf '0%.0s' {1..40})" ]]; then
      _gov_cs_reason="nulové before (první push větve)"
    elif ! git -C "$_gov_cs_root" cat-file -e "${_gov_cs_before}^{commit}" 2>/dev/null; then
      _gov_cs_reason="before '$_gov_cs_before' v checkoutu neexistuje (force push)"
    else
      _gov_cs_reason=""
      _gov_cs_paths=$(git -C "$_gov_cs_root" diff --name-only \
        "${_gov_cs_before}..HEAD" -- conf.d/projects/) || {
        echo "Chyba: git diff ${_gov_cs_before}..HEAD selhal." >&2
        exit 1
      }
      _gh-governance-codeowners-sync-keys-from-paths "$_gov_cs_paths" _gov_cs_keys
    fi
    if [[ -n "$_gov_cs_reason" ]]; then
      # Všechny projekty, ne jen ty s pr_reviewers_team: klíč může být jen
      # v nastavení repa a úklid osiřelé sekce po odebrání klíče by jinak
      # neproběhl; sync je levný.
      _gov_cs_keys=("${_GH_CONF_PROJECT_KEYS[@]}")
      _gh-governance-report-add info "sync vsech projektu" \
        "${GITHUB_ORG}/${GH_GOVERNANCE_REPO}" \
        "rozsah změn nelze určit: ${_gov_cs_reason} — sync běží nad všemi projekty (${#_gov_cs_keys[@]})"
    fi
    if [[ ${#_gov_cs_keys[@]} -eq 0 ]]; then
      echo "Změny conf.d/projects/ se netýkají žádného projektu – nic k synchronizaci."
      _gov-cs-render "$_gov_cs_report"
      exit 0
    fi
    echo "Projekty k synchronizaci: ${_gov_cs_keys[*]}"
    _gh-governance-codeowners-sync-run "${_gov_cs_keys[@]}" || exit 1
    _gov-cs-render "$_gov_cs_report"
    _gov-cs-exit-by-report "$_gov_cs_report"
    ;;
  project)
    if [[ ${#_gov_cs_pos[@]} -ne 1 ]]; then
      echo "Chyba: --project vyžaduje <projectKey>." >&2
      exit 1
    fi
    _gov-cs-require-key "${_gov_cs_pos[0]}" || exit 1
    _gov_cs_report=$(mktemp) || exit 1
    _gh-governance-report-init "$_gov_cs_report"
    _gh-governance-codeowners-sync-run "${_gov_cs_pos[0]}" || exit 1
    _gov-cs-render "$_gov_cs_report"
    _gov-cs-exit-by-report "$_gov_cs_report"
    ;;
esac

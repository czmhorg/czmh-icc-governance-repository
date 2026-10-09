#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Entry skript route jobu dispatcheru issue-dispatch (defs/defs-governance-repo.md,
# governance issue): jediné workflow gov repa na událost issues. Z prefixu
# titulku `<label>: ` určí operaci, doplní issue label pod botem a zapíše
# kind=<label> do GITHUB_OUTPUT – workflow podle něj volá cílové workflow
# přes workflow_call. Jen režim --route (čte issue event, běží v Actions).

if [[ "${1:-}" == "--help" ]]; then
  echo "Syntaxe: gov-issue-dispatch.sh --route"
  echo "Účel:    Route job dispatcheru issue-dispatch: čte issue event"
  echo "         z GITHUB_EVENT_PATH, podle prefixu titulku '<label>: ' určí"
  echo "         governance operaci (create-repo, archive-repo, unarchive-repo,"
  echo "         move-repo, rename-repo, track-delete, repo-sync), doplní issue"
  echo "         label a zapíše kind=<label> do GITHUB_OUTPUT. Titulek bez"
  echo "         známého prefixu = kind prázdný, nic se nespouští."
  echo ""
  echo "Volby:"
  echo "  --route      Jediný režim (route job workflow issue-dispatch)."
  echo ""
  echo "Příklad: bash bin/gov-issue-dispatch.sh --route"
  echo ""
  echo "Práva:   write na gov repu (doplnění labelu issue)."
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/gov-env.sh"

_gov_id_mode=""
for _gov_id_a in "$@"; do
  case "$_gov_id_a" in
    --route) _gov_id_mode=route ;;
    *) echo "Chyba: Neznámá volba '$_gov_id_a' (viz --help)." >&2; exit 1 ;;
  esac
done
if [[ "$_gov_id_mode" != route ]]; then
  echo "Chyba: Očekávám --route (viz --help)." >&2
  exit 1
fi

_gh-governance-issue-dispatch-step

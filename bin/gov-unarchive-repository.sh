#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Entry skript workflow unarchive-repository; spustitelný i lokálně nad
# checkoutem gov repa.

if [[ "${1:-}" == "--help" ]]; then
  echo "Syntaxe: gov-unarchive-repository.sh <projectKey> <ghName>"
  echo "         gov-unarchive-repository.sh --parse"
  echo "         gov-unarchive-repository.sh --execute <projectKey> <ghName> <issueNumber>"
  echo "Účel:    Dearchivuje spravované repo projektu a hned aplikuje repository"
  echo "         policy (týmy, rulesety) včetně odebrání týmů dle zmrazeného"
  echo "         ukazatele /state/; po úspěchu ukazatel posune."
  echo ""
  echo "Parametry:"
  echo "  projectKey   Klíč projektu (conf.d/projects/<projectKey>.conf)."
  echo "  ghName       Název repa bez prefixů (formát viz defs/defs.md)."
  echo ""
  echo "Volby:"
  echo "  --parse      Parse job workflow: čte issue event z GITHUB_EVENT_PATH,"
  echo "               autorizuje autora proti repository_archivers a zapíše"
  echo "               výstupy do GITHUB_OUTPUT. Odmítnutí zavře issue."
  echo "  --execute    Execute job workflow: provede operaci a zavře issue."
  echo ""
  echo "Příklad: bash governance/bin/gov-unarchive-repository.sh bbpkid stara-app"
  echo ""
  echo "Práva:   admin na repu projektu (dearchivace, týmy, rulesety), push do gov repa (/state/)."
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/gov-env.sh"

_gov-entry-main _gh-governance-unarchive repository_archivers \
  "Repo je dearchivované a politika aplikovaná" "$@"

#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Entry skript workflow archive-repository; spustitelný i lokálně nad
# checkoutem gov repa.

if [[ "${1:-}" == "--help" ]]; then
  echo "Syntaxe: gov-archive-repository.sh <projectKey> <ghName>"
  echo "         gov-archive-repository.sh --parse"
  echo "         gov-archive-repository.sh --execute <projectKey> <ghName> <issueNumber>"
  echo "Účel:    Archivuje spravované nearchivované repo projektu (PATCH"
  echo "         archived=true). Ukazatel /state/ se neposouvá – zmrazí se."
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
  echo "Příklad: GH_CONFD_ROOT=~/gov-checkout/conf.d bash governance/bin/gov-archive-repository.sh bbpkid stara-app"
  echo ""
  echo "Práva:   admin na repu projektu (archivace)."
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/gov-env.sh"

_gov-entry-main _gh-governance-archive repository_archivers \
  "Repo je archivované" "$@"

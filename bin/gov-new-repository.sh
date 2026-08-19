#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Entry skript workflow new-repository; spustitelný i lokálně nad checkoutem
# gov repa (krok 2 PoC – lokální aplikační cesta bez Actions).

if [[ "${1:-}" == "--help" ]]; then
  echo "Syntaxe: gov-new-repository.sh <projectKey> <ghName>"
  echo "         gov-new-repository.sh --parse"
  echo "         gov-new-repository.sh --execute <projectKey> <ghName> <issueNumber>"
  echo "Účel:    Založí (nebo konverguje) spravované repo projektu čistě z INI"
  echo "         konfigurace conf.d: create s auto_init, topic ghp-<projectKey>,"
  echo "         týmy a rulesety dle conf.d, ukazatel /state/."
  echo ""
  echo "Parametry:"
  echo "  projectKey   Klíč projektu (conf.d/projects/<projectKey>.conf)."
  echo "  ghName       Název repa bez prefixů (formát viz defs/defs.md)."
  echo ""
  echo "Volby:"
  echo "  --parse      Parse job workflow: čte issue event z GITHUB_EVENT_PATH,"
  echo "               autorizuje autora proti repository_creators a zapíše"
  echo "               výstupy do GITHUB_OUTPUT. Odmítnutí zavře issue."
  echo "  --execute    Execute job workflow: provede operaci a zavře issue."
  echo ""
  echo "Příklad: bash governance/bin/gov-new-repository.sh bbpkid moje-app"
  echo ""
  echo "Práva:   admin v organizaci (create repo, týmy, rulesety), push do gov repa (/state/)."
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/gov-env.sh"

_gov-entry-main _gh-governance-new repository_creators \
  "Repo je založené a nakonfigurované dle INI konfigurace" "$@"

#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Sdílené helpery pro generovaný obsah ve spravovaných repech
# (defs/defs-governance-repo.md: generovany obsah ve spravovanych repech):
# Contents API — čtení, zápis a smazání jednoho souboru (jeden commit do zadané
# větve, bez klonu), výpis adresáře — blob SHA lokálního obsahu pro porovnání
# bez stahování a expanze placeholderů šablon ({{NÁZEV}}). Volají je
# lib/gh-governance-codeowners.sh (.github/CODEOWNERS,
# CODEOWNERS_README.md) a lib/gh-governance-workflows.sh (soubory
# .github/workflows/<GH_WORKFLOW_PREFIX>-*.yml). Rozhodovací logika zůstává
# v modulech — zde jen volání API; testy modulů tyto funkce přepisují jménem
# (vlastní testy: tests/test-gh-governance-contents.sh). Přes rulesety projde
# bot díky svému bypass týmu (defs/defs.md: bypass tym); zápis do
# .github/workflows/ navíc vyžaduje scope `workflow` PAT bota
# (docs/github/actions-workflow-files-contents-api.md).
# Závislosti: gh-common-defs.sh (GITHUB_ORG_HOSTNAME), gh, base64, mktemp,
# git (_gh-governance-blob-sha).
[[ -n "${_GH_GOVERNANCE_CONTENTS_LOADED:-}" ]] && \
  declare -F _gh-governance-contents-read >/dev/null && return 0
_GH_GOVERNANCE_CONTENTS_LOADED=1

_gh-governance-contents-api-error() {
  # Společné vyhodnocení selhání `gh api` ze souboru se stderr: rc 1 = HTTP 404
  # (soubor/adresář neexistuje — tiše), rc 2 = jiná chyba (stderr gh projde
  # dál; poslední řádek nese důvod: 409 rule violations, chybějící scope
  # workflow, chyba výrazu jq …). Soubor se stderr smaže.
  # Použití: _gh-governance-contents-api-error <err_file>
  local _err
  _err=$(< "$1")
  rm -f "$1"
  grep -qF '(HTTP 404)' <<< "$_err" && return 1
  [[ -n "$_err" ]] && printf '%s\n' "$_err" >&2
  return 2
}

_gh-governance-contents-read() {
  # Načte soubor spravovaného repa přes Contents API. rc 0 = načteno
  # (content + blob sha do namerefs), rc 1 = neexistuje (HTTP 404),
  # rc 2 = jiná chyba (poslední řádek stderr gh projde; i cesta k adresáři
  # místo souboru — odpověď je pole, výraz jq selže). Kontrakt obsahu:
  # koncové \n jsou ořezané (command substitution) — volající porovnávají
  # obsah bez koncového \n a při zápisu ho doplňují (codeowners); porovnání
  # celého souboru bajt po bajtu jde přes blob SHA z -dir-list.
  # Použití: _gh-governance-contents-read <repoPath> <cesta> <branch>
  #          <content_ref> <sha_ref>
  declare -n _fr_content="$4" _fr_sha="$5"
  local _resp _err_file
  _fr_content=""; _fr_sha=""
  _err_file=$(mktemp) || return 2
  if ! _resp=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
      "repos/$1/contents/$2?ref=$3" \
      --jq '.sha + "\t" + (.content | gsub("\n";""))' 2>"$_err_file"); then
    _gh-governance-contents-api-error "$_err_file"
    return $?
  fi
  rm -f "$_err_file"
  _fr_sha="${_resp%%$'\t'*}"
  _fr_content=$(printf '%s' "${_resp#*$'\t'}" | base64 -d) || return 2
  return 0
}

_gh-governance-contents-write() {
  # Založí/aktualizuje soubor přes Contents API (jeden commit do <branch>).
  # Prázdné <sha> = založení, jinak update existujícího blobu (nesouhlasící
  # sha = HTTP 409, souběh dvou běhů — error položka volajícího, dorovná
  # další běh). Obsah se předává přesně (printf '%s'): koncový \n dodá
  # volající.
  # Použití: _gh-governance-contents-write <repoPath> <cesta> <branch>
  #          <obsah> <sha|''> <commit message>
  local _b64
  local -a _args=(-f message="$6" -f branch="$3")
  _b64=$(printf '%s' "$4" | base64 | tr -d '\n') || return 1
  _args+=(-f content="$_b64")
  [[ -n "$5" ]] && _args+=(-f sha="$5")
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api --method PUT \
    "repos/$1/contents/$2" "${_args[@]}" >/dev/null
}

_gh-governance-contents-delete() {
  # Smaže soubor přes Contents API (jeden commit do <branch>); <sha> = blob
  # SHA mazaného souboru (z -read nebo -dir-list).
  # Použití: _gh-governance-contents-delete <repoPath> <cesta> <branch>
  #          <sha> <commit message>
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api --method DELETE \
    "repos/$1/contents/$2" \
    -f message="$5" -f branch="$3" -f sha="$4" >/dev/null
}

_gh-governance-contents-dir-list() {
  # Výpis adresáře spravovaného repa přes Contents API na stdout: řádky TSV
  # `name\tsha\ttype` (type file|dir|symlink|submodule; sha položky file =
  # blob SHA = _gh-governance-blob-sha jejího obsahu → porovnání bez stažení,
  # docs/github/actions-workflow-files-contents-api.md). Jeden request (limit
  # API 1000 položek). rc 0 = vypsáno, rc 1 = adresář neexistuje (HTTP 404,
  # prázdný výstup), rc 2 = jiná chyba včetně cesty k souboru místo adresáře
  # (odpověď je objekt — výraz jq skončí error(), gh vrátí rc 1 s textem na
  # stderr; docs/github/gh-api-jq-error.md).
  # Použití: _gh-governance-contents-dir-list <repoPath> <adresář> <branch>
  local _out _err_file
  _err_file=$(mktemp) || return 2
  if ! _out=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
      "repos/$1/contents/$2?ref=$3" \
      --jq 'if type == "array" then .[] | [.name, .sha, .type] | @tsv else error("odpověď není výpis adresáře (cesta je soubor)") end' \
      2>"$_err_file"); then
    _gh-governance-contents-api-error "$_err_file"
    return $?
  fi
  rm -f "$_err_file"
  [[ -z "$_out" ]] || printf '%s\n' "$_out"
  return 0
}

_gh-governance-template-expand() {
  # Nahradí v textu šablony přesné tokeny {{NÁZEV}} hodnotami (bash ${//},
  # bez regexů): každý další argument je dvojice NÁZEV=hodnota (hodnota smí
  # obsahovat '='). Výrazy Actions ${{ … }} i neznámé {{…}} zůstávají
  # (nehlásí se — mohou být legitimní součástí obsahu). Čistá funkce; jediná
  # implementace expanze pro CODEOWNERS (PROJECT_KEY, OWNERS) i soubory
  # workflow (PROJECT_KEY, GH_NAME, REPO_NAME).
  # Použití: _gh-governance-template-expand <text> <nameref> [NÁZEV=hodnota ...]
  declare -n _te_ref="$2"
  local _te_text="$1" _te_pair _te_name
  shift 2
  for _te_pair in "$@"; do
    _te_name="${_te_pair%%=*}"
    _te_text="${_te_text//\{\{$_te_name\}\}/${_te_pair#*=}}"
  done
  _te_ref="$_te_text"
}

_gh-governance-blob-sha() {
  # Blob SHA obsahu, jak ho hlásí GitHub (Contents/Trees API): `git hash-object
  # --stdin --no-filters` hashuje přesné bajty bez konverzí (autocrlf,
  # atributy). --stdin bez --path filtry neaplikuje už sám (ověřeno 2026-11-08
  # i v repu s core.autocrlf=true, docs/github/git-trees-api.md); --no-filters
  # je výslovně, aby na tom kód nezávisel. Obsah se předává přesně
  # (printf '%s'; koncový \n musí být v obsahu). Pozor na MSYS2 bash: literál
  # $'…\r…' napsaný uvnitř $( ) CR ztratí — CRLF obsah předávat proměnnou
  # (docs/bash/msys2-cr-v-command-substitution.md). Stdout = 40 hex znaků.
  # Použití: _gh-governance-blob-sha <obsah>
  printf '%s' "$1" | git hash-object --stdin --no-filters
}

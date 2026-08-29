#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Manifest nasazení kódu governance (docs/implementovano/navrh/drift-kodu-gov-a-toolkit.md):
# jeden zdroj pravdy pro to, které soubory dev repa nasazuje gov-sync.sh do
# gov repa a kam. Stejná pravidla používá gov-sync.sh (kopírování s hlavičkou
# GENEROVANO) i denní kontrola driftu kódu v reconcile (porovnání gov repa
# s toolkit repem, který nese strukturu dev repa).
# Závislosti: žádné (čisté funkce bez sítě a bez konfigurace).
[[ -n "${_GH_GOVERNANCE_DEPLOY_MANIFEST_LOADED:-}" ]] && \
  declare -F _gh-governance-deploy-manifest-rules >/dev/null && return 0
_GH_GOVERNANCE_DEPLOY_MANIFEST_LOADED=1

_GH_GOVERNANCE_DEPLOY_HEADER='# GENEROVANO gov-sync.sh -- needitovat v gov repu'
# Markdownová varianta (HTML komentář — '#' by se vykreslil jako nadpis H1).
_GH_GOVERNANCE_DEPLOY_HEADER_MD='<!-- GENEROVANO gov-sync.sh -- needitovat v gov repu -->'

_gh-governance-deploy-manifest-rules() {
  # Pravidla nasazení dev repo → gov repo, na stdout TSV řádky
  # <zdrojový glob>\t<cílový prefix>. Prefix končící '/' je cílový adresář
  # (cíl = prefix + basename zdroje), jinak přesná cílová cesta. Wildcard smí
  # být jen v posledním segmentu globu – counterpart porovnává adresářovou
  # část řetězcově, aby '*' neprocházela přes '/' (shoda s pathname expanzí
  # v gov-sync.sh).
  # Použití: _gh-governance-deploy-manifest-rules
  printf '%s\t%s\n' \
    'governance/workflows/*.yml'  '.github/workflows/' \
    'governance/bin/*.sh'         'bin/' \
    'lib/gh-conf.sh'              'lib/' \
    'lib/gh-repository-policy.sh' 'lib/' \
    'lib/gh-work-repo.sh'         'lib/' \
    'lib/gh-governance-*.sh'      'lib/' \
    'gh-common-defs.sh'           'gh-common-defs.sh' \
    'governance/templates/*.template' 'templates/' \
    'governance/README-gov-repo.md' 'README.md'
}

_gh-governance-deploy-manifest-counterpart() {
  # Pro cestu ve struktuře dev/toolkit repa (směr src) vypíše cílovou cestu
  # v gov repu; pro cestu v gov repu (směr dst) vypíše zdrojovou cestu.
  # rc 0 + cesta na stdout; rc 1 bez hlášky = cesta žádnému pravidlu
  # neodpovídá (legitimní nespravovaný soubor, není to chyba).
  # Použití: _gh-governance-deploy-manifest-counterpart <cesta> <src|dst>
  local _path="$1" _way="$2" _glob _prefix _gdir _gbase _pdir _pbase
  case "$_way" in
    src|dst) ;;
    *) echo "Chyba: Směr musí být src nebo dst (je '${_way:-}')." >&2; return 2 ;;
  esac
  _pdir=""; _pbase="$_path"
  [[ "$_path" == */* ]] && { _pdir="${_path%/*}"; _pbase="${_path##*/}"; }
  while IFS=$'\t' read -r _glob _prefix; do
    _gdir=""; _gbase="$_glob"
    [[ "$_glob" == */* ]] && { _gdir="${_glob%/*}"; _gbase="${_glob##*/}"; }
    if [[ "$_way" == src ]]; then
      [[ "$_pdir" == "$_gdir" && "$_pbase" == $_gbase ]] || continue
      if [[ "$_prefix" == */ ]]; then echo "${_prefix}${_pbase}"; else echo "$_prefix"; fi
    else
      if [[ "$_prefix" != */ ]]; then
        [[ "$_path" == "$_prefix" ]] || continue
        echo "$_glob"
      else
        [[ "$_pdir" == "${_prefix%/}" && "$_pbase" == $_gbase ]] || continue
        if [[ -n "$_gdir" ]]; then echo "${_gdir}/${_pbase}"; else echo "$_pbase"; fi
      fi
    fi
    return 0
  done < <(_gh-governance-deploy-manifest-rules)
  return 1
}

_gh-governance-deploy-manifest-header-add() {
  # Filtr stdin → stdout: vloží hlavičku GENEROVANO za shebang na prvním
  # řádku, jinak na úplný začátek (prázdný vstup → jen hlavička). Styl 'md'
  # vloží markdownovou variantu (HTML komentář). Zbytek vstupu projde bajtově
  # beze změny (cat) — soubor bez koncového \n ho nezíská. Přesná inverze je
  # _gh-governance-deploy-manifest-header-strip (umí obě varianty).
  # Použití: _gh-governance-deploy-manifest-header-add [<sh|md>] < <zdroj> > <cíl>
  local _first _hdr="$_GH_GOVERNANCE_DEPLOY_HEADER"
  case "${1:-sh}" in
    sh) ;;
    md) _hdr="$_GH_GOVERNANCE_DEPLOY_HEADER_MD" ;;
    *)  echo "Chyba: Styl hlavičky musí být sh nebo md (je '$1')." >&2; return 2 ;;
  esac
  if IFS= read -r _first; then
    if [[ "$_first" == '#!'* ]]; then
      printf '%s\n%s\n' "$_first" "$_hdr"
    else
      printf '%s\n%s\n' "$_hdr" "$_first"
    fi
    cat
  else
    # Prázdný vstup, nebo jediný řádek bez koncového \n.
    printf '%s\n' "$_hdr"
    [[ -n "$_first" ]] && printf '%s' "$_first"
    return 0
  fi
}

_gh-governance-deploy-manifest-is-header() {
  # rc 0, je-li řádek hlavičkou GENEROVANO v kterékoli variantě (sh i md).
  # Použití: _gh-governance-deploy-manifest-is-header <řádek>
  [[ "$1" == "$_GH_GOVERNANCE_DEPLOY_HEADER" \
     || "$1" == "$_GH_GOVERNANCE_DEPLOY_HEADER_MD" ]]
}

_gh-governance-deploy-manifest-header-strip() {
  # Filtr stdin → stdout: odstraní hlavičku GENEROVANO (kteroukoli variantu,
  # sh i md) z prvního řádku, nebo z druhého řádku za shebangem; vstup bez
  # hlavičky projde beze změny. Zbytek vstupu projde bajtově (cat).
  # Použití: _gh-governance-deploy-manifest-header-strip < <soubor>
  local _first _second
  if ! IFS= read -r _first; then
    # Prázdný vstup, nebo jediný řádek bez koncového \n.
    [[ -n "$_first" ]] && ! _gh-governance-deploy-manifest-is-header "$_first" \
      && printf '%s' "$_first"
    return 0
  fi
  if _gh-governance-deploy-manifest-is-header "$_first"; then
    cat
    return 0
  fi
  printf '%s\n' "$_first"
  if [[ "$_first" == '#!'* ]]; then
    if IFS= read -r _second; then
      _gh-governance-deploy-manifest-is-header "$_second" || printf '%s\n' "$_second"
    else
      [[ -n "$_second" ]] && ! _gh-governance-deploy-manifest-is-header "$_second" \
        && printf '%s' "$_second"
      return 0
    fi
  fi
  cat
}

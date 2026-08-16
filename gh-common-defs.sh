#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Sdílená konfigurace a pomocné funkce pro gh-functions-user.sh a bb-migrate.sh.
# Načítej přes: source "$(dirname "${BASH_SOURCE[0]}")/gh-common-defs.sh"
[[ -n "$_GH_COMMON_DEFS_LOADED" ]] && [[ "${BASH_SOURCE[0]}" == *gh-common-defs* ]] && return 0
_GH_COMMON_DEFS_LOADED=1

# ══════════════════════════════════════════════════════════════════════════════
# KONFIGURACE – sdílená nastavení (gh-functions-user.sh, bb-migrate.sh)
# Uprav tuto sekci podle svého prostředí.
# ══════════════════════════════════════════════════════════════════════════════

# Zápis : "${VAR:=default}" — proměnná nastavená v prostředí (env) vyhrává nad
# defaultem; gh-common-defs.local.sh (sourcovaný níže) přepíše obojí.
#GITHUB_ORG_HOSTNAME=code.mhi.tech
: "${GITHUB_ORG_HOSTNAME:=github.com}"
: "${GITHUB_ORG:=czmhorg}"

# Prefix názvů GitHub repozitářů.
# Nový formát: <GH_REPO_PREFIX>-<projectKey>-<slug>  (např. czmh-icc-bbpkid-moje-app)
# Starý formát: <GH_REPO_PREFIX_LEGACY>-<projectKey>-<slug> (např. czmh-bbpkid-moje-app)
: "${GH_REPO_PREFIX:=czmh-icc}"
: "${GH_REPO_PREFIX_LEGACY:=czmh}"

# Prefix projektového topicu spravovaných rep: ghp-<projectKey> (např. ghp-bbpkid)
: "${GH_PROJECT_TOPIC_PREFIX:=ghp-}"

# Governance repo — autoritativní umístění conf.d na GitHubu.
# Odvozený identifikátor <ghGlobalPrefix>-governance-repository (defs/defs.md).
: "${GH_GOVERNANCE_REPO:=${GH_REPO_PREFIX}-governance-repository}"

# Tým lidských adminů gov repa (governance-repo.md, souhrnná tabulka práv).
# Testovací default; produkce: czmh-bbpk-governance-admins.
# gov-init.sh tým nezakládá – jen ověřuje jeho existenci.
: "${GH_GOVERNANCE_ADMIN_TEAM:=test-gov-admins}"

# Viditelnost rep zakládaných governancí (workflow new-repository / gh-new).
# Nikdy natvrdo v kódu. Testovací prostředí (GitHub Free org): public;
# produkce (GitHub Enterprise) bude používat internal.
: "${GH_NEW_REPO_VISIBILITY:=public}"

# Viditelnost gov repa (gov-init.sh). Default sleduje GH_NEW_REPO_VISIBILITY.
# POZOR: default se vyhodnotí před načtením gh-common-defs.local.sh – přepsání
# GH_NEW_REPO_VISIBILITY až tam se sem nepropíše; v .local.sh nastav obě.
: "${GH_GOVERNANCE_REPO_VISIBILITY:=${GH_NEW_REPO_VISIBILITY}}"

# Formát ghName (defs/defs.md); ghRepoName = <prefix>-<projectKey>-<ghName>,
# max 100 znaků. Sdílí klientské funkce (gh-new, …) i governance moduly.
_GH_GHNAME_REGEX='^[a-z0-9][a-z0-9._-]*$'

# Kořenový adresář pro lokální kopié repozitářů.
# Pokud je nastavena, workspace-aware funkce (gh-clone, gh-cd, gh-open, gh-sync, gh-status)
# ukládají a pracují s repozitáři ve struktuře ${GH_WORKSPACE_ROOT}/{projectKey}/{repoName}.
# Nezapomeň: používej ${HOME}/..., ne ~/... (tilda se neexpanduje ve všech kontextech).
# GH_WORKSPACE_ROOT="${HOME}/workspace"

# Editor pro gh-open (bez --web). Výchozí: code (VS Code).
# GH_EDITOR=code

# Repo, jehož issue workflow provádí mazání rep (axiom Práva členů organizace,
# defs/defs.md) – černá skříňka spravovaná organizací; klientem je gh-delete.
: "${GH_DELETE_HELPER_REPO:=czmhorg/delete-repository}"

# Poll existence repa ve workflow track-delete (defs/defs-governance-repo.md):
# celkový timeout v minutách a interval mezi dotazy v sekundách.
: "${GH_GOVERNANCE_TRACK_DELETE_TIMEOUT_MIN:=10}"
: "${GH_GOVERNANCE_TRACK_DELETE_INTERVAL_S:=30}"

# Maximální stáří snapshotu completion cache v minutách před background
# refreshem (viz gh-completion-cache-design.md).
: "${GH_COMPLETION_CACHE_TTL_MIN:=15}"

# Minimální odstup pokusů o refresh completion cache v minutách
# (single-flight: souběžné TABy nestahují paralelně, selhání se neopakuje hned).
: "${GH_COMPLETION_REFRESH_BACKOFF_MIN:=2}"

# ══════════════════════════════════════════════════════════════════════════════
# Lokální uživatelské přepsání (gitignorováno).
# Zkopíruj gh-common-defs.local.sh.example → gh-common-defs.local.sh
# a nastav GH_WORKSPACE_ROOT, GH_EDITOR a případně další proměnné.
# ══════════════════════════════════════════════════════════════════════════════
_GH_COMMON_LOCAL="$(dirname "${BASH_SOURCE[0]}")/gh-common-defs.local.sh"
[[ -f "$_GH_COMMON_LOCAL" ]] && source "$_GH_COMMON_LOCAL"
unset _GH_COMMON_LOCAL

# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# Načtení INI konfigurace conf.d/ (projects/, business-services/, profiles/)
# parserem lib/gh-conf.sh – žádné sourcování konfiguračních souborů.
# Formát: docs/readme/README_COMMON.md.
# ══════════════════════════════════════════════════════════════════════════════
# GH_CONFD_ROOT (env nebo .local.sh) přesměruje conf.d jinam — typicky na
# lokální checkout gov repa; bez ní se čte conf.d vedle tohoto souboru.
# _GH_COMMON_CONF_D zůstává nastavená po celou dobu shellu — governance moduly
# (lib/gh-governance-*.sh) z ní odvozují kořen checkoutu gov repa (../state).
_GH_COMMON_CONF_D="${GH_CONFD_ROOT:-$(dirname "${BASH_SOURCE[0]}")/conf.d}"
if source "$(dirname "${BASH_SOURCE[0]}")/lib/gh-conf.sh"; then
  _gh-conf-load "$_GH_COMMON_CONF_D" || \
    echo "Chyba: Konfigurace conf.d nebyla načtena – oprav chyby výše. Funkce pracující s projekty nebudou fungovat." >&2
else
  echo "Chyba: Nepodařilo se načíst lib/gh-conf.sh." >&2
fi

_mhn_for_key() {
  # Vrátí MHN (business service) pro daný projectKey z conf.d/projects/.
  # Použití: _mhn_for_key <projectKey>  → echo MHN a return 0; nebo return 1
  local _mhn="${_GH_CONF[projects/$1/business_service]:-}"
  [[ -n "$_mhn" ]] || return 1
  echo "$_mhn"
}

_bb_all_project_keys() {
  # Vrátí mezerou oddělený seznam všech projectKey z conf.d/projects/.
  echo "${_GH_CONF_PROJECT_KEYS[*]}"
}

_sed_escape() {
  # Escapuje řetězec pro bezpečné vložení do sed výrazu s oddělovačem |.
  # Použití: _sed_escape pattern|replace <string>
  case "$1" in
    pattern) printf '%s' "$2" | sed 's/[]|\\.*^$[]/\\&/g' ;;
    replace) printf '%s' "$2" | sed 's/[|\\&]/\\&/g' ;;
  esac
}

_url_encode_path() {
  # Zakóduje lomítko v řetězci na %2F pro použití v gh api URL path segmentu.
  # Použití: _url_encode_path <segment>
  printf '%s' "$1" | sed 's|/|%2F|g'
}

_require_vars() {
  # Ověří, že jsou nastaveny všechny předané konfigurační proměnné.
  # Použití: _require_vars VAR1 VAR2 ...
  local _var _fail=0
  for _var in "$@"; do
    if [[ -z "${!_var}" ]]; then
      echo "Chyba: Konfigurační proměnná '$_var' není nastavena. Zkontroluj gh-common-defs.sh nebo conf.d/." >&2
      (( _fail++ )) || true
    fi
  done
  return $_fail
}

_bb-require-pk() {
  # Ověří projectKey a uloží MHN do nameref proměnné.
  # Použití: local _mhn; _bb-require-pk <projectKey> _mhn || return 1
  local _key="$1"
  declare -n _mhn_ref="$2"
  _mhn_ref=$(_mhn_for_key "$_key")
  if [[ -z "$_mhn_ref" ]]; then
    echo "Chyba: projectKey '$_key' není nakonfiguróván v žádném conf.d souboru." >&2
    echo "       Dostupné hodnoty: $(_bb_all_project_keys)" >&2
    return 1
  fi
}

_bb-require-gh-token() {
  # Získá GitHub token a uloží do nameref proměnné.
  # Použití: local gh_token; _bb-require-gh-token gh_token || return 1
  declare -n _token_ref="$1"
  _token_ref=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh auth token 2>/dev/null)
  if [[ -z "$_token_ref" ]]; then
    echo "Chyba: Nepodařilo se získat GitHub token – nejsi přihlášen přes gh-login?" >&2
    return 1
  fi
}

_gh-workspace-dir() {
  # Vrátí absolutní cestu k workspace adresáři pro daný projectKey (a volitelně repoName).
  # Použití: _gh-workspace-dir <projectKey> [repoName]
  # Selže s chybou pokud GH_WORKSPACE_ROOT není nastavena.
  _require_vars GH_WORKSPACE_ROOT || return 1
  local _path="${GH_WORKSPACE_ROOT}/$1"
  [[ -n "$2" ]] && _path="${_path}/$2"
  echo "$_path"
}

_gh-workspace-dirs() {
  # Naplní nameref pole cestami workspace adresářů odpovídajících projectKey (a volitelně repoName).
  # Použití: local -a _dirs=(); _gh-workspace-dirs <projectKey> <repoName> _dirs || return 1
  # Selže s chybou pokud GH_WORKSPACE_ROOT není nastavena.
  _require_vars GH_WORKSPACE_ROOT || return 1
  local _key="$1" _repo="$2"
  declare -n _dirs_ref="$3"
  local _d
  if [[ -n "$_repo" ]]; then
    _dirs_ref+=("${GH_WORKSPACE_ROOT}/${_key}/${_repo}")
  elif [[ -n "$_key" ]]; then
    for _d in "${GH_WORKSPACE_ROOT}/${_key}"/*/; do
      [[ -d "$_d" ]] && _dirs_ref+=("$_d")
    done
  else
    for _d in "${GH_WORKSPACE_ROOT}"/*/*/; do
      [[ -d "$_d" ]] && _dirs_ref+=("$_d")
    done
  fi
  return 0
}

_bb-eta-print() {
  # Vypíše ETA na základě průměrné doby zpracování. Bez výstupu pokud eta_count=0.
  # Použití: _bb-eta-print <eta_sum_ms> <eta_count> <total> <count> <slug>
  local _sum_ms="$1" _cnt="$2" _total="$3" _count="$4" _slug="$5"
  [[ $_cnt -eq 0 ]] && return 0
  local _avg_ms=$(( _sum_ms / _cnt ))
  local _rem_ms=$(( (_total - _count + 1) * _avg_ms ))
  local _str
  if   [[ $_rem_ms -lt 1000  ]]; then _str="${_rem_ms}ms"
  elif [[ $_rem_ms -lt 60000 ]]; then _str="~$(( _rem_ms / 1000 ))s"
  else                                 _str="~$(( _rem_ms / 60000 ))min"
  fi
  printf '[%d/%d]  Zbývá: %s  (průměr: %dms/repo)   %s\n' \
    "$_count" "$_total" "$_str" "$_avg_ms" "$_slug"
}

_gh-project-exists() {
  # Ověří aktuální existenci GH projektu podle stavu governance repa na GitHubu
  # (soubor conf.d/projects/<projectKey>.conf) — lokální klon může být neaktuální.
  # Návrat: 0 = existuje, 1 = neexistuje (bez výpisu), 2 = nelze zjistit (vypíše chybu).
  # Použití: _gh-project-exists <projectKey>
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_GOVERNANCE_REPO || return 2
  local _key="$1" _error
  _error=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
    "repos/${GITHUB_ORG}/${GH_GOVERNANCE_REPO}/contents/conf.d/projects/${_key}.conf" \
    --silent 2>&1) && return 0
  if grep -qF '(HTTP 404)' <<< "$_error"; then
    # 404 může znamenat chybějící soubor i chybějící gov repo — rozliš pro srozumitelnou chybu.
    if GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/${GITHUB_ORG}/${GH_GOVERNANCE_REPO}" --silent 2>/dev/null; then
      return 1
    fi
    echo "Chyba: Governance repo '${GITHUB_ORG}/${GH_GOVERNANCE_REPO}' není na GitHubu dostupné." >&2
    return 2
  fi
  echo "Chyba: Ověření existence GH projektu '${_key}' selhalo: ${_error}" >&2
  return 2
}

_gh-list-project-repos() {
  # Vrátí úplný seznam jmen repos jedné podmnožiny (jeden název na řádek) pro daný projectKey.
  # Závazný postup (defs/defs.md): dotaz topic:ghp-<projectKey> na Search API,
  # vždy zacílený kvalifikátorem archived: na právě jednu podmnožinu;
  # post-filtr nad odpovědí bez dalších API volání — název dle konvence
  # <GH_REPO_PREFIX>-<projectKey>-* a právě jeden topic ghp-*.
  # Úplnost zaručuje axiom Kapacita projektu (≤ 1000 rep v každé podmnožině).
  # gh search repos --hostname není na GHES podporováno, proto gh api.
  # Vyhledává jen pro existující GH projekt; existenci ověřuje aktuálním stavem
  # governance repa na GitHubu přes _gh-project-exists (lokální klon nemusí být
  # aktuální). Pro neexistující GH projekt vrátí chybu.
  # Použití: _gh-list-project-repos <projectKey> [archived]
  #   archived: false (výchozí) = nearchivovaná repa, true = archivovaná repa
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX || return 1
  local _key="$1"
  local _archived="${2:-false}"
  case "$_archived" in
    true|false) ;;
    *) echo "Chyba: druhý argument (archived) musí být true nebo false." >&2; return 1 ;;
  esac
  _gh-project-exists "$_key"
  case $? in
    0) ;;
    1) echo "Chyba: GH projekt '${_key}' neexistuje (conf.d/projects/${_key}.conf v governance repu nenalezen)." >&2
       return 1 ;;
    *) return 1 ;;
  esac
  local _name_prefix="${GH_REPO_PREFIX}-${_key}-"
  local _query="org:${GITHUB_ORG}+topic:ghp-${_key}+archived:${_archived}"
  local _all

  _all=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "search/repositories?q=${_query}&per_page=100" \
    --paginate \
    --template '{{range .items}}{{.name}}{{"\t"}}{{range .topics}}{{.}} {{end}}{{"\n"}}{{end}}' 2>/dev/null) || return 1

  local _name _topics _t _ghp_count
  local -a _topic_arr
  while IFS=$'\t' read -r _name _topics; do
    [[ -n "$_name" ]] || continue
    [[ "$_name" == "$_name_prefix"* ]] || continue
    read -r -a _topic_arr <<< "$_topics"
    _ghp_count=0
    for _t in "${_topic_arr[@]}"; do
      [[ "$_t" == ghp-* ]] && _ghp_count=$(( _ghp_count + 1 ))
    done
    [[ $_ghp_count -eq 1 ]] && printf '%s\n' "$_name"
  done <<< "$_all"
  return 0
}

# ══════════════════════════════════════════════════════════════════════════════
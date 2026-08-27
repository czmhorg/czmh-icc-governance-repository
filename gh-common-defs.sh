#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Sdílená konfigurace a pomocné funkce pro gh-functions-user.sh,
# gh-functions-search.sh a bb-migrate.sh.
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

# Rezervovaný prefix názvů repository rulesetů spravovaných automatikou
# (defs/defs.md): <GH_RULESET_PREFIX>-<profil>, např. mh-policy-default.
# Hodnota bez koncové pomlčky; pomlčku doplňuje kód v místě použití.
: "${GH_RULESET_PREFIX:=mh-policy}"

# Tým security-managers (defs/defs.md: ghOrgSecurityManagersTeam) — vytváří ho
# organizace, na každém repu je automaticky a nejde odebrat. Implicitní součást
# bezpečnostní politiky: governance ho nevynucuje ani nespravuje, jen ignoruje
# (nereportuje, neodebírá, nemění oprávnění); v repository_teams je zakázán.
: "${GH_SECURITY_MANAGERS_TEAM:=security-managers}"

# Výchozí hodnota custom property Deployment_Target spravovaných rep
# (defs/defs.md: ghDeploymentTargetDefault). Repository policy ji jen doplní,
# když property chybí; existující hodnotu (v rukou admina repa) nemění ani
# nehlásí. Migrace (bb-migrate.sh) ji nastavuje natvrdo – jde o nové repo.
: "${GH_DEPLOYMENT_TARGET_DEFAULT:=PRODUCTION}"

# Governance repo — autoritativní umístění conf.d na GitHubu.
# Odvozený identifikátor <ghGlobalPrefix>-governance-repository (defs/defs.md).
: "${GH_GOVERNANCE_REPO:=${GH_REPO_PREFIX}-governance-repository}"

# Toolkit repo — distribuční repo skriptů, ze kterého sourcují uživatelé.
# Odvozený identifikátor <ghGlobalPrefix>-gh-bash-toolkit (defs/defs.md).
# Používá kontrola driftu kódu v reconcile a akční hláška gh-update.
: "${GH_TOOLKIT_REPO:=${GH_REPO_PREFIX}-gh-bash-toolkit}"

# Tým lidských adminů gov repa (governance-repo.md, souhrnná tabulka práv).
# Testovací default; produkce: czmh-bbpk-governance-admins.
# gov-init.sh tým nezakládá – jen ověřuje jeho existenci.
: "${GH_GOVERNANCE_ADMIN_TEAM:=test-gov-admins}"

# Login governance bota (machine user gov workflows). Povinná, implicitní
# součást repository policy: policy assign ho přidá jako přímého collaboratora
# s právem admin na každé spravované repo (bot není org owner — bez toho by
# jeho PAT zmigrovaná/založená repa neviděl a reconcile by na nich selhal).
# Prázdná hodnota = chyba preflightu.
# Testovací default: účet, pod kterým běží testy; produkce: czmh-mhi-git-bbpk-governance-bot.
: "${GH_GOVERNANCE_BOT_USER:=mhgithubcopilot}"

# Bypass adminů gov repa v rulesetu výchozí větve gov-default-branch
# (gov-init.sh; docs/navrh/ochrana-gov-repa.md): pull_request = admini repa
# smějí mergnout PR bez cizího schválení, ale ne pushovat přímo; none = bez
# výjimky. Testovací default pull_request (jediný správce by se jinak zamkl);
# produkce: none – pak musí mít GH_GOVERNANCE_ADMIN_TEAM aspoň dva členy.
# Bot (GH_GOVERNANCE_BOT_USER) má bypass always vždy (zápis state/).
: "${GH_GOVERNANCE_ADMIN_BYPASS:=pull_request}"

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
# Formát ghProjectKey (defs/defs.md): bez pomlčky — v ghRepoName odděluje
# projectKey a ghName první pomlčka za prefixem (_gh-repo-resolve). Délku
# (max 46) hlídá governance vrstva (_GH_GOVERNANCE_PROJECT_KEY_REGEX).
_GH_PROJECT_KEY_REGEX='^[a-z0-9]+$'

# Kořenový adresář lokálních kopií repozitářů (workspace). Workspace funkce
# (gh-clone, gh-cd, gh-open, gh-project-clone, gh-sync, gh-status) pracují
# se strukturou ${GH_WORKSPACE_ROOT}/{projectKey}/{ghName}. Výchozí hodnota
# platí bez jakékoli lokální konfigurace; přepsání v gh-common-defs.local.sh.
# Nezapomeň: používej ${HOME}/..., ne ~/... (tilda se neexpanduje ve všech kontextech).
: "${GH_WORKSPACE_ROOT:=${HOME}/github/workspace}"

# Editor pro gh-open (bez --web). Výchozí: code (VS Code).
# GH_EDITOR=code

# Repo, jehož issue workflow provádí mazání rep (axiom Práva členů organizace,
# defs/defs.md) – černá skříňka spravovaná organizací; klientem je gh-delete.
# Default odvozen z GITHUB_ORG – žije vždy v aktuální organizaci.
: "${GH_DELETE_HELPER_REPO:=${GITHUB_ORG}/delete-repository}"

# Poll existence repa ve workflow track-delete (defs/defs-governance-repo.md):
# celkový timeout v minutách a interval mezi dotazy v sekundách.
: "${GH_GOVERNANCE_TRACK_DELETE_TIMEOUT_MIN:=10}"
: "${GH_GOVERNANCE_TRACK_DELETE_INTERVAL_S:=30}"

# Maximální stáří snapshotu completion cache v minutách před background
# refreshem (viz docs/implementovano/navrh/gh-completion-cache-design.md).
: "${GH_COMPLETION_CACHE_TTL_MIN:=15}"

# Minimální odstup pokusů o refresh completion cache v minutách
# (single-flight: souběžné TABy nestahují paralelně, selhání se neopakuje hned).
# Sdílí ho i fetch vzdálené verze skriptů (_gh-version-remote-refresh).
: "${GH_COMPLETION_REFRESH_BACKOFF_MIN:=2}"

# Maximální stáří cache vzdálené verze skriptů v minutách před background
# fetchem toolkit repa (kontrola verze skriptů; výchozí 1440 = jednou denně).
: "${GH_VERSION_CHECK_TTL_MIN:=1440}"

# Kořen lokálního zrcadla pro vyhledávání v kódu projektů (gh-functions-search.sh).
# Struktura: ${GH_SEARCH_MIRROR_DIR}/{projectKey}/{active|archived}/{ghRepoName}.git
# Obsah je dopočitatelná cache (bare + shallow klony výchozích větví) — lze
# kdykoli smazat a nechat znovu stáhnout přes gh-search-sync.
# Nezapomeň: používej ${HOME}/..., ne ~/... (tilda se neexpanduje ve všech kontextech).
: "${GH_SEARCH_MIRROR_DIR:=${HOME}/.cache/gh-search-mirror}"

# Výchozí počet řádek kontextu před a za nalezenou řádkou ve výstupu gh-search
# (lze per hledání přepsat volbami -C/-B/-A).
: "${GH_SEARCH_CONTEXT_LINES:=3}"

# Maximální počet refů (rep) v jednom volání git grep při hledání gh-search.
# Windows omezuje délku příkazové řádky na ~32 tisíc znaků — všechny refy
# projektu najednou se do ní nemusí vejít, proto se hledání dávkuje.
: "${GH_SEARCH_REF_BATCH:=150}"

# Pager pro výstup gh-search, když je stdout terminál (v rouře/přesměrování se
# nepoužije nikdy). Prázdná hodnota = bez stránkování; jednorázově vypne volba
# --no-pager. Bez dvojtečky v ${...=} záměrně: nastavená prázdná hodnota se
# respektuje jako vypnuto, := by ji přepsalo defaultem.
: "${GH_SEARCH_PAGER=${PAGER:-less -RFX}}"

# Kořen pracovních rep funkcí (docs/implementovano/pracovni-repa-funkci.md): trvalé
# klony (gov repo, řídicí repa migrace), se kterými pracují výhradně funkce.
# Není to cache — obsah se commituje a pushuje; nesmí ho mazat čisticí nástroje.
# Nezapomeň: používej ${HOME}/..., ne ~/... (tilda se neexpanduje ve všech kontextech).
: "${GH_WORK_REPOS_ROOT:=${HOME}/.local/state/gh-work}"

# ══════════════════════════════════════════════════════════════════════════════
# Locale-nezávislé regex validace (docs/bash/locale-rozsahy-regex-validace.md).
# Definováno před sourcováním lib/ modulů níže — _gh-conf-load validuje
# už při načítání shellu.
# ══════════════════════════════════════════════════════════════════════════════

_gh-match() {
  # Regex match nezávislý na locale uživatele: v ne-C locale (cs_CZ.UTF-8)
  # rozsahy [a-z]/[A-Z] matchují podle collation i opačnou velikost písmen
  # a POSIX třídy ([[:alnum:]]) pouštějí diakritiku. LC_ALL=C je local —
  # platí jen po dobu matche a po návratu se obnoví; přebije i uživatelovo
  # LC_ALL. $2 je záměrně bez uvozovek na pravé straně =~ (quoted RHS by
  # regex degradoval na literál). Vrací jen ano/ne — na BASH_REMATCH po
  # volání nespoléhej (pro capture skupiny použij přímé [[ =~ ]]).
  # Použití: _gh-match <řetězec> <ERE regex>    (negace: ! _gh-match ...)
  local LC_ALL=C
  [[ "$1" =~ $2 ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Lokální uživatelské přepsání (gitignorováno).
# Zkopíruj gh-common-defs.local.sh.example → gh-common-defs.local.sh
# a přepiš proměnné, jejichž výchozí hodnota nevyhovuje (GH_WORKSPACE_ROOT,
# GH_EDITOR, …).
# ══════════════════════════════════════════════════════════════════════════════
_GH_COMMON_DIR="$(dirname "${BASH_SOURCE[0]}")"
_GH_COMMON_LOCAL="$_GH_COMMON_DIR/gh-common-defs.local.sh"
[[ -f "$_GH_COMMON_LOCAL" ]] && source "$_GH_COMMON_LOCAL"
unset _GH_COMMON_LOCAL

# Zámek a sync pracovních rep funkcí (docs/implementovano/pracovni-repa-funkci.md).
if ! source "$_GH_COMMON_DIR/lib/gh-work-repo.sh"; then
  echo "Chyba: Nepodařilo se načíst lib/gh-work-repo.sh." >&2
fi

# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# Načtení INI konfigurace conf.d/ (projects/, business-services/, profiles/)
# parserem lib/gh-conf.sh – žádné sourcování konfiguračních souborů.
# Formát: docs/readme/README_COMMON.md.
# ══════════════════════════════════════════════════════════════════════════════
# Zdroj conf.d (docs/implementovano/pracovni-repa-funkci.md):
# 1. GH_CONFD_ROOT (env nebo .local.sh) — vývojářský override „čti odsud
#    a nesynchronizuj" (pískoviště pro nepushnuté změny konfigurace),
# 2. GitHub Actions (checkout gov repa na runneru) — conf.d vedle tohoto
#    souboru, nic se nesynchronizuje,
# 3. jinak pracovní klon gov repa — synchronizuje ho _gh-confd-sync uvnitř
#    funkcí při každém spuštění; GitHub je jediný zdroj pravdy.
# _GH_COMMON_CONF_D zůstává nastavená po celou dobu shellu — governance moduly
# (lib/gh-governance-*.sh) z ní odvozují kořen checkoutu gov repa (../state).
# _GH_CONFD_SYNC: 1 = conf.d je pracovní klon a _gh-confd-sync ho synchronizuje;
# 0 = lokální conf.d bez synchronizace. Rozhoduje se jednou při sourcování —
# GH_CONFD_ROOT nastavená jen po dobu source (VAR=x source ...) nesmí režim
# ztratit za běhu funkcí.
# _GH_CONFD_FRESH: 1 = konfigurace v paměti pochází z právě provedené
# synchronizace s GitHubem (_gh-confd-sync bez --no-sync); 0 = čtena bez
# synchronizace (start shellu, --no-sync). Rozlišuje, jakou radu dát
# uživateli, když projekt v konfiguraci chybí (_gh-require-project).
_GH_CONFD_FRESH=0
if [[ -n "${GH_CONFD_ROOT:-}" ]]; then
  _GH_COMMON_CONF_D="$GH_CONFD_ROOT"
  _GH_CONFD_SYNC=0
elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  _GH_COMMON_CONF_D="$_GH_COMMON_DIR/conf.d"
  _GH_CONFD_SYNC=0
else
  _GH_COMMON_CONF_D="${GH_WORK_REPOS_ROOT}/gov-repo/conf.d"
  _GH_CONFD_SYNC=1
fi
if source "$_GH_COMMON_DIR/lib/gh-conf.sh"; then
  if [[ -d "$_GH_COMMON_CONF_D" ]]; then
    _gh-conf-load "$_GH_COMMON_CONF_D" || \
      echo "Chyba: Konfigurace conf.d nebyla načtena – oprav chyby výše. Funkce pracující s projekty nebudou fungovat." >&2
  elif [[ -n "${GH_CONFD_ROOT:-}" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "Chyba: Adresář conf.d '$_GH_COMMON_CONF_D' neexistuje – konfigurace nenačtena." >&2
  fi
  # Jinak měkký první běh (tichý): pracovní klon vznikne při prvním spuštění
  # funkce, která konfiguraci potřebuje (_gh-confd-sync).
else
  echo "Chyba: Nepodařilo se načíst lib/gh-conf.sh." >&2
fi

_gh-gov-repo-sync-locked() {
  # Zamkne a synchronizuje pracovní klon gov repa v <dir> (clone při prvním
  # běhu, jinak ff-only pull). Po úspěchu ZŮSTÁVÁ ZÁMEK DRŽEN — volající ho
  # uvolní přes _gh-work-repo-unlock; při selhání syncu se uvolní zde.
  # Sdílí _gh-confd-sync (conf.d) a governance/gov-sync.sh (deploy kódu).
  # Použití: _gh-gov-repo-sync-locked <dir>
  local _dir="$1"
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_GOVERNANCE_REPO || return 1
  local _url="https://${GITHUB_ORG_HOSTNAME}/${GITHUB_ORG}/${GH_GOVERNANCE_REPO}.git"
  # Stručná průběhová hláška (stderr); cestu a detail vypisuje až chyba
  # (_gh-work-repo-error).
  if [[ -d "$_dir" ]]; then
    echo "Aktualizuji pracovní klon gov repa..." >&2
  else
    echo "Klonuji pracovní klon gov repa..." >&2
  fi
  _gh-work-repo-lock "$_dir" || return 1
  if ! _gh-work-repo-sync "$_dir" "$_url"; then
    _gh-work-repo-unlock "$_dir"
    return 1
  fi
  return 0
}

_gh-confd-sync() {
  # Synchronizuje pracovní klon gov repa (zdroj conf.d) a znovu načte
  # konfiguraci; volá se na začátku každé funkce, která conf.d potřebuje.
  # Společný vstupní bod všech pracovních funkcí (i přes _gh-confd-sync-ro) —
  # proto tudy vede blokace zastaralé verze skriptů.
  # Při _GH_CONFD_SYNC=0 (GH_CONFD_ROOT override, GitHub Actions) je no-op —
  # čte se lokální conf.d bez synchronizace. S --no-sync (jen read-only
  # operace) se git nespouští a zámek nebere — vyžaduje existující klon
  # s načtenou konfigurací.
  # S --hold-lock zůstane zámek pracovního repa po úspěchu držen (volající ho
  # uvolní přes _gh-work-repo-unlock; pro běhy, které do klonu dál zapisují).
  # Použití: _gh-confd-sync [--no-sync] [--hold-lock]
  _gh-require-current-version || return 1
  local _a _no_sync=0 _hold=0
  for _a in "$@"; do
    case "$_a" in
      --no-sync)   _no_sync=1 ;;
      --hold-lock) _hold=1 ;;
      *) echo "Chyba: _gh-confd-sync: neznámý argument '$_a'." >&2; return 1 ;;
    esac
  done
  [[ "${_GH_CONFD_SYNC:-0}" == "1" ]] || return 0
  local _dir="${_GH_COMMON_CONF_D%/*}"
  if [[ $_no_sync -eq 1 ]]; then
    if [[ ! -d "$_dir" || -z "${_GH_CONF_DATA_LOADED:-}" ]]; then
      echo "Chyba: Pracovní klon gov repa není k dispozici (--no-sync nemá z čeho číst) – spusť operaci bez --no-sync." >&2
      return 1
    fi
    _GH_CONFD_FRESH=0
    return 0
  fi
  _gh-gov-repo-sync-locked "$_dir" || return 1
  if ! _gh-conf-load "$_GH_COMMON_CONF_D"; then
    _gh-work-repo-unlock "$_dir"
    return 1
  fi
  _GH_CONFD_FRESH=1
  [[ $_hold -eq 1 ]] || _gh-work-repo-unlock "$_dir"
  return 0
}

_gh-confd-sync-ro() {
  # Sync conf.d pro read-only funkce s volbou --no-sync: podle příznaku
  # synchronizuje (0/false), nebo čte poslední synchronizovaný stav (1/true).
  # Jedno místo pro opakované „if no_sync“ volajících funkcí.
  # Použití: _gh-confd-sync-ro <no_sync: 0|1|false|true> || return 1
  case "$1" in
    1|true)  _gh-confd-sync --no-sync ;;
    0|false) _gh-confd-sync ;;
    *) echo "Chyba: _gh-confd-sync-ro: neplatný příznak '$1' (0|1|false|true)." >&2; return 1 ;;
  esac
}

_mhn_for_key() {
  # Vrátí MHN (business service) pro daný projectKey z conf.d/projects/ —
  # první složku klíče domain (<MHN>/<typ>).
  # Použití: _mhn_for_key <projectKey>  → echo MHN a return 0; nebo return 1
  local _d="${_GH_CONF[projects/$1/domain]:-}"
  [[ -n "$_d" ]] || return 1
  echo "${_d%%/*}"
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
  # Ověří existenci projectKey (_gh-require-project, akční hláška) a uloží
  # jeho MHN do nameref proměnné.
  # Použití: local _mhn; _bb-require-pk <projectKey> _mhn || return 1
  local _key="$1"
  declare -n _mhn_ref="$2"
  _gh-require-project "$_key" || return 1
  _mhn_ref=$(_mhn_for_key "$_key")
  if [[ -z "$_mhn_ref" ]]; then
    echo "Chyba: GH projekt '$_key' nemá v conf.d/projects/$_key.conf klíč domain (MHN nelze určit)." >&2
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

_gh-repo-resolve() {
  # Jednotná identifikace repa v parametrech funkcí
  # (docs/implementovano/navrh/identifikace-repa-parametry.md): převede
  # poziční argumenty volající funkce v libovolném z tvarů
  #   <projectKey> <ghName> | <ghRepoName> | <org>/<ghRepoName> | URL (https, git@)
  # na ghProjectKey + ghName. Nameref asoc. pole dostane klíče projectKey,
  # ghName, repoName (<GH_REPO_PREFIX>-<projectKey>-<ghName>) a consumed —
  # počet spotřebovaných pozičních argumentů (2 u krátkého tvaru, jinak 1);
  # zbytek si bere volající (cílový adresář gh-clone). Funkce bez dalších
  # pozičních parametrů volají _gh-repo-resolve-exact.
  # Čistě řetězcové (bez sítě a conf.d). Pracuje jen se spravovanými repy:
  # cizí host, cizí org, název bez prefixu nebo s legacy prefixem = chyba
  # „repo není spravované“ (legacy název resolver záměrně nezná — složil by
  # z něj jiné repo). Z URL bere první dva segmenty cesty (org/repo), ořízne
  # .git i userinfo (token@host u klonů gh-clone); /tree/…, /pull/… a koncové
  # lomítko zahodí. Host a org porovnává bez ohledu na velikost písmen.
  # Formáty projectKey a ghName (defs/defs.md) validuje u všech tvarů.
  # Použití: local -A _rr=(); _gh-repo-resolve _rr "${_pos[@]}" || return 1
  declare -n _grr_ref="$1"
  local _a1="${2:-}" _a2="${3:-}"
  local _host="" _org="" _name="" _rest="" _key="" _gh_name="" _consumed=1 _what
  _grr_ref=([projectKey]="" [ghName]="" [repoName]="" [consumed]=0)
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX || return 1

  if [[ -z "$_a1" ]]; then
    echo "Chyba: Zadej repozitář: <projectKey> <ghName>, <ghRepoName>, <org>/<ghRepoName> nebo URL (viz gh-help)." >&2
    return 1
  fi
  # Rozpoznání tvaru (BASH_REMATCH bez rozsahů písmen — docs/bash/locale-rozsahy-regex-validace.md).
  if [[ "$_a1" =~ ^https?://([^/]+)/(.*)$ ]]; then
    _host="${BASH_REMATCH[1]##*@}"
    _rest="${BASH_REMATCH[2]}"
  elif [[ "$_a1" =~ ^(ssh://)?git@([^:/]+)[:/](.*)$ ]]; then
    _host="${BASH_REMATCH[2]}"
    _rest="${BASH_REMATCH[3]}"
  fi
  if [[ -n "$_host" ]]; then
    _org="${_rest%%/*}"
    if [[ "$_rest" == */* ]]; then _rest="${_rest#*/}"; else _rest=""; fi
    _name="${_rest%%/*}"
    _name="${_name%.git}"
    if [[ -z "$_org" || -z "$_name" ]]; then
      echo "Chyba: URL neobsahuje org/repo: $_a1" >&2
      return 1
    fi
  elif [[ "$_a1" == */* ]]; then
    _org="${_a1%%/*}"
    _name="${_a1#*/}"
    if [[ -z "$_org" || -z "$_name" || "$_name" == */* ]]; then
      echo "Chyba: Neplatný tvar <org>/<ghRepoName>: $_a1" >&2
      return 1
    fi
  elif [[ "$_a1" == "${GH_REPO_PREFIX}-"* ]]; then
    _org="$GITHUB_ORG"
    _name="$_a1"
  else
    if [[ -z "$_a2" ]]; then
      echo "Chyba: Zadej ghName jako druhý argument (<projectKey> <ghName>)." >&2
      return 1
    fi
    _key="$_a1"
    _gh_name="$_a2"
    _consumed=2
  fi

  if [[ $_consumed -eq 1 ]]; then
    # org/repo → spravované repo: náš host, naše org, <prefix>-<key>-<name>.
    _what="${_org}/${_name}"
    local _foreign_host=0
    if [[ -n "$_host" && "${_host,,}" != "${GITHUB_ORG_HOSTNAME,,}" ]]; then
      _foreign_host=1
      _what+="@${_host}"
    fi
    _rest="${_name#"${GH_REPO_PREFIX}-"}"
    _key="${_rest%%-*}"
    _gh_name="${_rest#*-}"
    if [[ $_foreign_host -eq 1 || "${_org,,}" != "${GITHUB_ORG,,}" \
          || "$_name" != "${GH_REPO_PREFIX}-"* || "$_rest" != *-* \
          || -z "$_key" || -z "$_gh_name" ]]; then
      echo "Chyba: repo není spravované (${GH_REPO_PREFIX}-<ghProjectKey>-<ghName> v ${GITHUB_ORG}): ${_what}" >&2
      return 1
    fi
  fi

  if ! _gh-match "$_key" "$_GH_PROJECT_KEY_REGEX"; then
    echo "Chyba: projectKey '$_key' neodpovídá formátu $_GH_PROJECT_KEY_REGEX (viz defs/defs.md)." >&2
    return 1
  fi
  if ! _gh-match "$_gh_name" "$_GH_GHNAME_REGEX"; then
    echo "Chyba: ghName '$_gh_name' neodpovídá formátu $_GH_GHNAME_REGEX (viz defs/defs.md)." >&2
    return 1
  fi
  _grr_ref[projectKey]="$_key"
  _grr_ref[ghName]="$_gh_name"
  _grr_ref[repoName]="${GH_REPO_PREFIX}-${_key}-${_gh_name}"
  _grr_ref[consumed]=$_consumed
  return 0
}

_gh-repo-resolve-exact() {
  # _gh-repo-resolve pro funkce bez dalších pozičních parametrů: všechny
  # poziční argumenty musí resolver spotřebovat (gh-open czmhorg/x navic = chyba).
  # Použití: local -A _rr=(); _gh-repo-resolve-exact _rr "${_pos[@]}" || return 1
  declare -n _grre_ref="$1"
  _gh-repo-resolve "$@" || return 1
  if [[ $(( $# - 1 )) -gt ${_grre_ref[consumed]} ]]; then
    echo "Chyba: Příliš mnoho argumentů." >&2
    return 1
  fi
  return 0
}

_gh-repo-resolve-or-project() {
  # Varianta pro workspace funkce s volitelným repem (gh-open, gh-cd): jediný
  # poziční argument bez '/' a bez prefixu <GH_REPO_PREFIX>- je projectKey
  # (ghName a repoName zůstanou prázdné), cokoli jiného jde přes
  # _gh-repo-resolve-exact.
  # Použití: local -A _rr=(); _gh-repo-resolve-or-project _rr "${_pos[@]}" || return 1
  declare -n _grrp_ref="$1"
  if [[ $# -eq 2 && "$2" != */* && "$2" != "${GH_REPO_PREFIX}-"* ]]; then
    _require_vars GH_REPO_PREFIX || return 1
    if ! _gh-match "$2" "$_GH_PROJECT_KEY_REGEX"; then
      echo "Chyba: projectKey '$2' neodpovídá formátu $_GH_PROJECT_KEY_REGEX (viz defs/defs.md)." >&2
      return 1
    fi
    _grrp_ref=([projectKey]="$2" [ghName]="" [repoName]="" [consumed]=1)
    return 0
  fi
  _gh-repo-resolve-exact "$@"
}

_gh-fmt-duration() {
  # Naplní nameref kompaktním zápisem doby: <1 s celé ms (215ms), do 60 s sekundy
  # s jedním desetinným místem (12.3s), do 1 h minuty a sekundy (1m2s), jinak hodiny
  # a minuty (1h2m). Nulová složka se píše vždy (1m0s). Zaokrouhluje na nejbližší
  # jednotku posledního místa; pásmo se volí až ze zaokrouhlené hodnoty, aby
  # nevzniklo „60.0s" ani „60m0s". Čistá Bash aritmetika — bez forku (tiskne se
  # pro každé repo).
  # Použití: local _s; _gh-fmt-duration <ms> _s
  local _ms="$1"
  declare -n _out_ref="$2"
  local _tenths _sec _min
  if (( _ms < 1000 )); then
    _out_ref="${_ms}ms"; return 0
  fi
  _tenths=$(( (_ms + 50) / 100 ))
  if (( _tenths < 600 )); then
    _out_ref="$(( _tenths / 10 )).$(( _tenths % 10 ))s"; return 0
  fi
  _sec=$(( (_ms + 500) / 1000 ))
  if (( _sec < 3600 )); then
    _out_ref="$(( _sec / 60 ))m$(( _sec % 60 ))s"; return 0
  fi
  _min=$(( (_ms + 30000) / 60000 ))
  _out_ref="$(( _min / 60 ))h$(( _min % 60 ))m"
}

_bb-eta-print() {
  # Vypíše ETA na základě průměrné doby zpracování. Bez výstupu pokud eta_count=0.
  # Oba časy formátuje _gh-fmt-duration; „~" značí odhad zbývajícího času,
  # průměr je změřený, proto bez „~".
  # Použití: _bb-eta-print <eta_sum_ms> <eta_count> <total> <count> <slug>
  local _sum_ms="$1" _cnt="$2" _total="$3" _count="$4" _slug="$5"
  [[ $_cnt -eq 0 ]] && return 0
  local _avg_ms=$(( _sum_ms / _cnt ))
  local _rem_ms=$(( (_total - _count + 1) * _avg_ms ))
  local _rem_str _avg_str
  _gh-fmt-duration "$_rem_ms" _rem_str
  _gh-fmt-duration "$_avg_ms" _avg_str
  printf '[%d/%d]  Zbývá: ~%s  (průměr: %s/repo)   %s\n' \
    "$_count" "$_total" "$_rem_str" "$_avg_str" "$_slug"
}

_gh-utf8-pad() {
  # Doplní UTF-8 řetězec mezerami zprava na <šířka> znaků do nameref proměnné —
  # sloupce tabulek s diakritikou. printf '%-Ns' i ${#} mimo UTF-8 locale
  # počítají bajty, každé písmeno s diakritikou by sloupec posunulo o jedna —
  # délka se proto počítá nezávisle na locale: v subshellu s LC_ALL=C se
  # z UTF-8 řetězce odstraní pokračovací bajty (0x80–0xBF) a zbylé bajty =
  # znaky. Jeden fork na volání je přijatelný (desítky volání na běh).
  # Řetězec delší než <šířka> se nedoplňuje (výplň 0) ani nezkracuje.
  # Použití: _gh-utf8-pad <řetězec> <šířka> <nameref výsledku>
  local _s="$1" _width="$2" _len _pad
  declare -n _pad_ref="$3"
  _len=$(LC_ALL=C; _t="${_s//[$'\x80'-$'\xbf']/}"; printf '%s' "${#_t}")
  _pad=$(( _width - _len )); (( _pad > 0 )) || _pad=0
  printf -v _pad_ref '%s%*s' "$_s" "$_pad" ''
}

_gh-summary-row() {
  # Řádek „<odsazení><popisek> <hodnota>" s hodnotami pod sebou (popisek
  # doplněný mezerami na <šířka> znaků přes _gh-utf8-pad) — závěrečné souhrny
  # toolů, detail repa v gh-info, stav migrace.
  # Použití: _gh-summary-row <popisek> <hodnota> [<šířka>=30] [<odsazení>=2]
  # Popisek delší než <šířka> se nedoplňuje (výplň 0), hodnota následuje za
  # jednou mezerou.
  local _label="$1" _value="$2" _width="${3:-30}" _indent="${4:-2}" _padded
  _gh-utf8-pad "$_label" "$_width" _padded
  printf '%*s%s %s\n' "$_indent" '' "$_padded" "$_value"
}

_gh-project-exists() {
  # Ověří existenci GH projektu (soubor conf.d/projects/<projectKey>.conf)
  # podle naposledy načtené konfigurace conf.d — synchronizaci s GitHubem
  # (jediným zdrojem pravdy) zajišťují volající funkce přes _gh-confd-sync.
  # Návrat: 0 = existuje, 1 = neexistuje (bez výpisu), 2 = nelze zjistit (vypíše chybu).
  # Použití: _gh-project-exists <projectKey>
  local _key="$1" _k
  if [[ -z "${_GH_CONF_DATA_LOADED:-}" ]]; then
    echo "Chyba: Konfigurace conf.d není načtena – existenci GH projektu '${_key}' nelze ověřit. Spusť napřed operaci se synchronizací (např. gh-cache-refresh), případně oprav chyby hlášené při startu shellu." >&2
    return 2
  fi
  for _k in "${_GH_CONF_PROJECT_KEYS[@]}"; do
    [[ "$_k" == "$_key" ]] && return 0
  done
  return 1
}

_gh-require-project() {
  # Ověří existenci GH projektu (_gh-project-exists) a neexistenci ohlásí
  # akční chybou — uživatel má z hlášky poznat, kde se konfigurace hledala
  # a co udělat: po synchronizaci připomene, že se projeví jen pushnutý
  # commit gov repa (GitHub je jediný zdroj pravdy, lokální checkout funkce
  # nečtou); při čtení bez synchronizace (--no-sync, start shellu) doporučí
  # běh se synchronizací. Vždy vypíše dostupné projectKey.
  # Návrat: 0 = existuje; 1 = neexistuje nebo nelze zjistit (chyba vypsána).
  # Použití: _gh-require-project <projectKey> || return 1
  local _key="$1" _where _hint=""
  _gh-project-exists "$_key"
  case $? in
    0) return 0 ;;
    1) ;;
    *) return 1 ;;
  esac
  if [[ "${_GH_CONFD_SYNC:-0}" != "1" ]]; then
    _where="conf.d '${_GH_COMMON_CONF_D}' neobsahuje projects/${_key}.conf"
  elif [[ "${_GH_CONFD_FRESH:-0}" == "1" ]]; then
    _where="gov repo ${GITHUB_ORG}/${GH_GOVERNANCE_REPO} na GitHubu neobsahuje conf.d/projects/${_key}.conf"
    _hint="Pokud jsi projekt právě přidal, ověř, že je commit pushnutý do gov repa (funkce čtou jen GitHub, ne lokální checkout)."
  else
    _where="naposledy synchronizovaná konfigurace neobsahuje conf.d/projects/${_key}.conf"
    _hint="Konfigurace byla čtena bez synchronizace s GitHubem – spusť příkaz bez --no-sync."
  fi
  echo "Chyba: GH projekt '${_key}' neexistuje: ${_where}." >&2
  [[ -z "$_hint" ]] || echo "       $_hint" >&2
  echo "       Dostupné projekty: $(_bb_all_project_keys)" >&2
  return 1
}

_gh-list-project-repos() {
  # Vrátí úplný seznam jmen repos jedné podmnožiny (jeden název na řádek) pro daný projectKey.
  # Závazný postup (defs/defs.md): dotaz topic:ghp-<projectKey> na Search API,
  # vždy zacílený kvalifikátorem archived: na právě jednu podmnožinu;
  # post-filtr nad odpovědí bez dalších API volání — název dle konvence
  # <GH_REPO_PREFIX>-<projectKey>-* a právě jeden topic ghp-*.
  # Úplnost zaručuje axiom Kapacita projektu (≤ 1000 rep v každé podmnožině).
  # gh search repos --hostname není na GHES podporováno, proto gh api.
  # Vyhledává jen pro existující GH projekt; existenci ověřuje přes
  # _gh-require-project nad naposledy načtenou konfigurací conf.d —
  # synchronizaci (_gh-confd-sync) zajišťuje volající funkce.
  # Pro neexistující GH projekt vrátí chybu.
  # Použití: _gh-list-project-repos <projectKey> [archived]
  #   archived: false (výchozí) = nearchivovaná repa, true = archivovaná repa
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX || return 1
  local _key="$1"
  local _archived="${2:-false}"
  case "$_archived" in
    true|false) ;;
    *) echo "Chyba: druhý argument (archived) musí být true nebo false." >&2; return 1 ;;
  esac
  _gh-require-project "$_key" || return 1
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
# Kontrola verze skriptů (docs/readme/README_COMMON.md).
# Verze skriptů = rostoucí celé číslo v souboru VERSION v kořeni toolkit repa;
# spravuje ji výhradně workflow version-bump.yml. V dev repu VERSION neexistuje
# → _GH_SCRIPTS_VERSION je prázdná a všechny kontroly se tiše přeskakují.
# Blokovat se smí jen na pozitivní zjištění „novější verze prokazatelně
# existuje"; chybějící data (bez sítě, bez cache) nikdy neblokují (fail-open).
# ══════════════════════════════════════════════════════════════════════════════

_gh-version-read-file() {
  # Přečte celé číslo verze z prvního řádku souboru do nameref; chybějící
  # soubor nebo nečíselný obsah → prázdná hodnota (kontroly se přeskočí).
  # Použití: local _v; _gh-version-read-file <soubor> _v
  local _file="$1" _raw=""
  declare -n _gvr_ref="$2"
  _gvr_ref=""
  [[ -f "$_file" ]] || return 0
  IFS= read -r _raw < "$_file" 2>/dev/null || true
  # Git Bash na Windows s core.autocrlf checkoutuje VERSION s CRLF.
  _raw="${_raw%$'\r'}"
  _gh-match "$_raw" '^[0-9]+$' && _gvr_ref="$_raw"
  return 0
}

_gh-version-load() {
  # Načte verzi skriptů z $_GH_COMMON_DIR/VERSION do _GH_SCRIPTS_VERSION.
  # Volá se při sourcování; testy volají znovu po přesměrování _GH_COMMON_DIR.
  _gh-version-read-file "$_GH_COMMON_DIR/VERSION" _GH_SCRIPTS_VERSION
}

_gh-version-cache-dir() {
  # Kořen cache kontroly verze — sdílí adresář completion cache
  # (~/.cache/gh-workspace); _gh_cache_dir žije v gh-functions-user.sh
  # a gh-common-defs.sh na něm záviset nesmí.
  printf '%s\n' "${HOME}/.cache/gh-workspace"
}

_gh-version-cache-write() {
  # Atomicky (tmp + mv) zapíše číslo vzdálené verze do cache .version-remote
  # a dotykem .version-last-refresh označí úspěšný refresh (TTL). Kromě
  # fetche na pozadí ji po úspěchu volá i gh-update — odblokování bez čekání.
  # Použití: _gh-version-cache-write <verze>
  local _dir _tmp
  _dir=$(_gh-version-cache-dir)
  mkdir -p "$_dir" || return 1
  _tmp=$(mktemp "$_dir/.version-remote.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$1" > "$_tmp"; then
    rm -f "$_tmp"
    return 1
  fi
  mv "$_tmp" "$_dir/.version-remote" || return 1
  touch "$_dir/.version-last-refresh"
}

_gh-version-remote-branch() {
  # Vypíše jméno default větve remotu origin (bez prefixu origin/):
  # symbolic-ref origin/HEAD s fallbackem main/master (origin/HEAD nemusí
  # být v klonu nastaven, např. po ručním git clone starší verzí gitu).
  local _b
  _b=$(git -C "$_GH_COMMON_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [[ -n "$_b" ]]; then
    printf '%s\n' "${_b#origin/}"
    return 0
  fi
  for _b in main master; do
    if git -C "$_GH_COMMON_DIR" rev-parse --verify --quiet "refs/remotes/origin/$_b" >/dev/null 2>&1; then
      printf '%s\n' "$_b"
      return 0
    fi
  done
  return 1
}

_gh-version-refresh-due() {
  # rc 0 = má smysl spustit fetch vzdálené verze na pozadí: verze skriptů je
  # známá a poslední úspěšný refresh je starší než TTL (nebo žádný nebyl).
  # Levná kontrola mtime — hook při sourcování nespouští git ani subshell
  # na pozadí, když je cache čerstvá (vzor priming completion cache).
  [[ -n "$_GH_SCRIPTS_VERSION" ]] || return 1
  local _marker="$(_gh-version-cache-dir)/.version-last-refresh"
  [[ -f "$_marker" ]] || return 0
  [[ -n "$(find "$_marker" -mmin "+${GH_VERSION_CHECK_TTL_MIN}" 2>/dev/null)" ]]
}

_gh-version-remote-refresh() {
  # Pozadí: obnoví cache vzdálené verze skriptů fetchem toolkit repa —
  # $_GH_COMMON_DIR musí být git klon s remote origin (pracovní strom se
  # nemění, jen refy). Single-flight: bez --force se přeskočí při čerstvém
  # .version-last-refresh (TTL) nebo čerstvém .version-refresh-lock (backoff
  # po selhání). Všechna selhání jsou tichá s rc 0 — blokace smí vzniknout
  # jen z pozitivního zjištění (fail-open).
  # Použití: _gh-version-remote-refresh [--force]
  local _a _force=false _dir _branch _remote=""
  for _a in "$@"; do
    case "$_a" in
      --force) _force=true ;;
      *) echo "Chyba: _gh-version-remote-refresh: neznámý argument '$_a'." >&2; return 1 ;;
    esac
  done
  [[ -n "$_GH_SCRIPTS_VERSION" ]] || return 0
  git -C "$_GH_COMMON_DIR" remote get-url origin &>/dev/null || return 0
  _dir=$(_gh-version-cache-dir)
  mkdir -p "$_dir" || return 0
  if [[ "$_force" == false ]]; then
    [[ -n "$(find "$_dir/.version-refresh-lock" -mmin "-${GH_COMPLETION_REFRESH_BACKOFF_MIN}" 2>/dev/null)" ]] \
      && return 0
    _gh-version-refresh-due || return 0
  fi
  touch "$_dir/.version-refresh-lock"
  git -C "$_GH_COMMON_DIR" fetch --quiet 2>/dev/null || return 0
  _branch=$(_gh-version-remote-branch) || return 0
  _remote=$(git -C "$_GH_COMMON_DIR" show "origin/${_branch}:VERSION" 2>/dev/null)
  _gh-match "$_remote" '^[0-9]+$' || return 0
  _gh-version-cache-write "$_remote" || return 0
  return 0
}

_gh-version-status() {
  # Bez sítě: naplní nameref asoc. pole stavem verze skriptů ze tří čísel —
  # verze v shellu (_GH_SCRIPTS_VERSION, načtena při sourcování), soubor
  # VERSION na disku a cache vzdálené verze (plní _gh-version-remote-refresh).
  # Klíče: state (current | stale-shell | outdated | unknown), shell, disk,
  # remote. unknown = chybějící data (dev repo bez VERSION, prázdná cache) —
  # volající se chová fail-open. Aritmetika s prefixem 10# (VERSION s vedoucí
  # nulou by jinak byla octal a např. 08 chyba parsování).
  # Použití: local -A _vs=(); _gh-version-status _vs
  declare -n _gvs_ref="$1"
  local _disk="" _remote=""
  _gh-version-read-file "$_GH_COMMON_DIR/VERSION" _disk
  _gh-version-read-file "$(_gh-version-cache-dir)/.version-remote" _remote
  _gvs_ref=([state]=unknown [shell]="$_GH_SCRIPTS_VERSION" [disk]="$_disk" [remote]="$_remote")
  [[ -n "$_GH_SCRIPTS_VERSION" && -n "$_disk" ]] || return 0
  if (( 10#$_disk > 10#$_GH_SCRIPTS_VERSION )); then
    _gvs_ref[state]=stale-shell
  elif [[ -z "$_remote" ]]; then
    _gvs_ref[state]=unknown
  elif (( 10#$_remote > 10#$_disk )); then
    _gvs_ref[state]=outdated
  else
    _gvs_ref[state]=current
  fi
  return 0
}

_gh-require-current-version() {
  # Blokační brána pracovních funkcí (společné vstupní body _gh-confd-sync
  # a _bb-require-login): zastaralé skripty zablokuje do provedení upgradu.
  # stale-shell (na disku už je novější verze, v paměti shellu stará) → stačí
  # zavřít okna; outdated → v interaktivním shellu nabídne rovnou gh-update,
  # jinak akční hláška. current i unknown propouští (fail-open).
  # Použití: _gh-require-current-version || return 1
  local -A _vs=()
  local _answer
  _gh-version-status _vs
  case "${_vs[state]}" in
    stale-shell)
      echo "Skripty byly aktualizovány na verzi ${_vs[disk]}; v tomto okně běží stará verze ${_vs[shell]}." >&2
      echo "Zavři všechna okna Git Bash a otevři nová." >&2
      return 1
      ;;
    outdated)
      echo "Je k dispozici nová verze skriptů (${_vs[disk]} → ${_vs[remote]})." >&2
      if [[ $- == *i* && -t 0 ]] && declare -f gh-update >/dev/null; then
        read -r -p "Provést aktualizaci nyní? [a/N] " _answer
        if [[ "$_answer" == [aA] ]]; then
          gh-update
          # I po úspěšném upgradu jsou funkce v paměti shellu staré —
          # rozpracovaná operace se nespouští (gh-update vyzval zavřít okna).
          return 1
        fi
      fi
      echo "Aktualizaci provedeš příkazem: gh-update" >&2
      return 1
      ;;
  esac
  return 0
}

_GH_SCRIPTS_VERSION=""
_gh-version-load

# ══════════════════════════════════════════════════════════════════════════════

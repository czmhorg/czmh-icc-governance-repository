#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Sdílená konfigurace a pomocné funkce pro gh-functions-user.sh,
# gh-functions-search.sh a bb-migrate.sh.
# Načítej přes: source "$(dirname "${BASH_SOURCE[0]}")/gh-common-defs.sh"
[[ -n "$_GH_COMMON_DEFS_LOADED" ]] && [[ "${BASH_SOURCE[0]}" == *gh-common-defs* ]] && return 0
# Toolkit vyžaduje Bash 4.3+ (declare -n/-A, mapfile, ${var,,}); systémový
# /bin/bash na macOS je 3.2 a bez kontroly by se každý blok ~/.bashrc rozpadl
# na nesrozumitelných hláškách (docs/bash/macos-prenositelnost.md). Porovnání
# ve funkci s argumenty — BASH_VERSINFO je readonly, testy ji nestubnou.
_gh-bash-version-ok() {
  # Použití: _gh-bash-version-ok <major> <minor>   (rc 0 = verze ≥ 4.3)
  (( $1 > 4 || ($1 == 4 && $2 >= 3) ))
}
if ! _gh-bash-version-ok "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"; then
  echo "Chyba: Bash $BASH_VERSION je příliš starý – gh skripty vyžadují Bash 4.3+. Na macOS otevři terminál s Bashem 5 (viz README_PREREQUISITES.md, sekce Instalace na macOS)." >&2
  _GH_BASH_TOO_OLD=1
  return 1 2>/dev/null || exit 1
fi
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

# Marker topicy migrace (defs/defs.md, defs-migrace.md): bb-gh-migrating nese
# repo stále otevřené pro opakovanou migraci; bb-gh-migrated repo předané.
# Interní konstanty (ne konfigurace). Žijí zde, protože je sdílí bb-migrate.sh,
# tools/ i governance reconcile v gov repu (lib/bb-migration-control.sh se do
# gov repa nenasazuje) — a s nimi i helper _bb-migration-topic-present.
_BB_MIGRATION_TOPIC_MARKER=bb-gh-migrating
_BB_MIGRATION_TOPIC_MARKER_DONE=bb-gh-migrated

_bb-migration-topic-present() {
  # rc 0 ⇔ CSV seznam topiců obsahuje přesně daný topic (celá položka, ne
  # podřetězec). Jen builtiny. Používá migrace (bb-migrate.sh), tools/
  # i governance moduly (vynechání repa v migraci ze správy obsahu rep).
  # Použití: _bb-migration-topic-present <topicsCSV> <topic>
  [[ ",$1," == *",$2,"* ]]
}

# Rezervovaný prefix názvů repository rulesetů spravovaných automatikou
# (defs/defs.md): <GH_RULESET_PREFIX>-<profil>, např. mh-policy-default.
# Hodnota bez koncové pomlčky; pomlčku doplňuje kód v místě použití.
: "${GH_RULESET_PREFIX:=mh-policy}"

# Rezervovaný prefix souborů workflow spravovaných automatikou (defs/defs.md:
# workflow repa): .github/workflows/<GH_WORKFLOW_PREFIX>-<název>.yml ve výchozí
# větvi repa, např. mh-workflow-release-merge-up.yml. Obsah = šablona
# conf.d/workflows/<název>.yml gov repa (klíč workflows projektu nebo nastavení
# repa) s hlavičkou GENEROVANO; conf.d je per prostředí, šablony se gov-syncem
# nenasazují. Soubor s prefixem a hlavičkou automatika vlastní (osiřelý maže),
# s prefixem bez hlavičky jen hlásí, bez prefixu nikdy nečte.
# Hodnota bez koncové pomlčky; pomlčku doplňuje kód v místě použití.
: "${GH_WORKFLOW_PREFIX:=mh-workflow}"

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

# Výchozí události spravovaného webhooku rep (defs/defs.md: webhook repa) –
# platí pro repa bez klíče webhook_events v conf.d. push stačí triggeru GitHub
# pluginu Jenkinsu („GitHub hook trigger for GITScm polling“); multibranch
# pipeline potřebuje navíc pull_request (klíč webhook_events projektu).
: "${GH_WEBHOOK_EVENTS_DEFAULT:=push}"

# Max. stáří otevřeného reconcile issue ve dnech (defs/defs-governance-repo.md:
# reconcile issue, bod 4). Trvalá zjištění by issue držela otevřené neomezeně
# (pondělní běh přidává komentář); po dosažení stáří ho pondělní běh se
# zjištěními zavře jako not_planned se závěrečným komentářem a založí nové
# (rotace). 0 = rotace při každém pondělním běhu se zjištěními – jen ověření.
: "${GH_RECONCILE_ISSUE_MAX_AGE_DAYS:=90}"

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
# Testovací default: czmha-bot (org member bez owner role — parita práv
# s machine userem; czmha je běžný uživatel); produkce: czmh-mhi-git-bbpk-governance-bot.
: "${GH_GOVERNANCE_BOT_USER:=czmha-bot}"

# Prefix slugu bypass týmů (defs/defs.md, docs/navrh/bypass-pres-tym.md):
# <GH_BYPASS_TEAM_PREFIX><login> (např. mhcz-bypass-team-for-czmha-bot).
# Bypass rulesetů (mh-policy-* i gov-default-branch) dostává každý účet — bot
# i Jenkins login domény — výhradně přes svůj tým jako bypass actor Team/always:
# bypass actor typu User GHES 3.21 neuplatňuje. Chybějící tým zakládá bot sám
# (PAT s právem spravovat týmy: fine-grained org permission Members: write,
# classic scope admin:org); tým nemá přístup k žádnému repu.
# Stejný pro pískoviště i produkci. Na rozdíl od GH_RULESET_PREFIX prefix
# končí pomlčkou (login se připojuje bez oddělovače).
: "${GH_BYPASS_TEAM_PREFIX:=mhcz-bypass-team-for-}"

# Bypass adminů gov repa v rulesetu výchozí větve gov-default-branch
# (gov-init.sh; docs/navrh/ochrana-gov-repa.md): pull_request = admini repa
# smějí mergnout PR bez cizího schválení, ale ne pushovat přímo; none = bez
# výjimky. Testovací default pull_request (jediný správce by se jinak zamkl);
# produkce: none – pak musí mít GH_GOVERNANCE_ADMIN_TEAM aspoň dva členy.
# Bypass tým bota (GH_BYPASS_TEAM_PREFIX + GH_GOVERNANCE_BOT_USER) má bypass
# always vždy (zápis state/).
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
# Formát jména výchozí větve (klíč default_branch, defs/defs.md): konzervativní
# podmnožina `git check-ref-format` bez lomítka — parser conf.d smí jen bash
# builtiny a hodnota jde do JSON těla `branches/{branch}/rename`. Úplnou
# kontrolu (zákaz '..' a přípony .lock) dělá _gh-branch-name-valid.
_GH_BRANCH_NAME_REGEX='^[A-Za-z0-9][A-Za-z0-9._-]*$'
# Formát URL spravovaného webhooku (klíč webhook_url, defs/defs.md: webhook
# repa) a názvu události hooku (položka klíče webhook_events; samotná `*`
# = všechny události). Platnost názvu události ověřuje až GitHub API.
_GH_WEBHOOK_URL_REGEX='^https?://[^[:space:]]+$'
_GH_WEBHOOK_EVENT_REGEX='^[a-z_]+$'
# Formát názvu policy profilu (conf.d/profiles/<název>.conf) a šablony workflow
# (conf.d/workflows/<název>.yml; defs/defs.md: policy profile, sablona
# workflow) — týž regex; položky klíčů rulesets a workflows ho musí splnit.
_GH_CONF_TEMPLATE_NAME_REGEX='^[a-z][a-z0-9_-]*$'
# Mapování workspace (GH_WORKSPACE_MAP, docs/implementovano/navrh/workspace-mapovani.md): vzor
# ghName v klíči položky = znaky ghName plus glob znaky * a ? (rozsahy [...],
# extglob a '**' se nepouštějí); hodnota = relativní cesta ze segmentů
# [A-Za-z0-9._-] (bez úvodního/koncového '/', '//', '\' a mezer).
_GH_WS_PATTERN_REGEX='^[a-z0-9._*?-]+$'
_GH_WS_VALUE_REGEX='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'

# Kořenový adresář lokálních kopií repozitářů (workspace). Workspace funkce
# (gh-clone, gh-cd, gh-open, gh-project-clone, gh-sync, gh-status) pracují
# se strukturou ${GH_WORKSPACE_ROOT}/{projectKey}/{ghName}; jiné umístění
# vybraných rep určuje mapování GH_WORKSPACE_MAP (níže). Výchozí hodnota
# platí bez jakékoli lokální konfigurace; přepsání v gh-common-defs.local.sh.
# Koncové lomítko hodnoty se po načtení lokální konfigurace ořeže (cesty se
# skládají jako ${GH_WORKSPACE_ROOT}/…, jinak by vznikalo dvojité lomítko).
# Nezapomeň: používej ${HOME}/..., ne ~/... (tilda se neexpanduje ve všech kontextech).
: "${GH_WORKSPACE_ROOT:=${HOME}/github/workspace}"

# Aplikace pro gh-open bez přepínače. Výchozí: code (VS Code). Hodnota je
# shell příkaz (jako GH_BROWSER): cesta s mezerami v uvozovkách, argumenty
# možné, cesta k adresáři se připojí na konec; gh-open ji spouští na pozadí
# (_gh-open-in-editor).
# GH_EDITOR=code

# Grafický klient gitu pro gh-open --git (Sourcetree, Fork, GitKraken, …).
# Bez výchozí hodnoty — bez nastavení je --git chyba s hintem. Stejná
# konvence jako GH_EDITOR; Sourcetree na Windows chce před cestou -f.
# GH_GIT_GUI=

# Správce souborů pro gh-open --files (Total Commander, Explorer, …). Bez
# nastavení výchozí správce OS (Linux xdg-open, macOS open, Windows explorer).
# Stejná konvence jako GH_EDITOR; přepínače Windows programů s dvojitým
# lomítkem (//O //T) — MSYS by jednoduché /O převedl na cestu.
# GH_FILE_MANAGER=

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
: "${GH_VERSION_CHECK_TTL_MIN:=10}"

# Hlášení čekajících PR ve funkcích gh-* („Máš 1 schválený PR k merge, 2 PR
# čekají na tvoje review → gh-pr-list"; docs/implementovano/navrh/gh-pr-funkce.md): maximální
# stáří cache počtů v minutách před obnovou na pozadí a zároveň nejmenší
# odstup dvou stejných hlášení v jednom shellu. 0 = hlášení vypnuto.
: "${GH_PR_NOTICE_TTL_MIN:=10}"

# Hlídač PR (macOS tools/pr-watcher.sh — docs/navrh/pr-watcher-macos.md:
# LaunchAgent à 1 minutu, bubliny přes vlastní notifikátor — aplikaci
# kompilovanou při instalaci z tools/pr-watcher-notifier.swift; windowsí
# hlídač tools/pr-watcher.ps1 má vlastní konfiguraci .local.ps1). Společný
# pro oba je stavový adresář a odklad gh-pr-snooze
# (docs/navrh/pr-watcher-ticho.md).
# Opakovaná připomínka v minutách, dokud dotaz vrací PR; 0 = bublina jen při
# novém PR / schválení. Jen macOS (Windows: $ReminderMinutes v .local.ps1).
: "${GH_PR_WATCHER_REMINDER_MIN:=60}"

# Výchozí doba odkladu bublin v minutách pro gh-pr-snooze bez čísla
# (gh-functions-user.sh): odklad zapisuje epochu konce do souboru snooze-until
# ve stavovém adresáři a oba hlídače během něj kontrolu přeskočí.
: "${GH_PR_WATCHER_SNOOZE_MIN:=60}"

# Stav hlídače, soubor odkladu snooze-until, na macOS i generované soubory
# kliknutí (pr-inbox.command, on-click.sh) a log LaunchAgentu. Na Windows
# (Git Bash dědí LOCALAPPDATA) tentýž adresář, ze kterého čte pr-watcher.ps1
# ($StateDir = %LOCALAPPDATA%\gh-pr-watcher) — gh-pr-snooze tak píše tam, kde
# hlídač čte; zpětná lomítka převádí expanze (Git Bash cestu C:/… přijímá,
# cygpath by byl subproces při každém sourcování). Přepsání v .local.sh na
# Windows nedává smysl: pr-watcher.ps1 tuto proměnnou nečte.
# Nezapomeň: používej ${HOME}/..., ne ~/... (tilda se neexpanduje ve všech kontextech).
if [[ -n "${LOCALAPPDATA:-}" ]]; then
  : "${GH_PR_WATCHER_STATE_DIR:=${LOCALAPPDATA//\\//}/gh-pr-watcher}"
else
  : "${GH_PR_WATCHER_STATE_DIR:=${HOME}/.local/state/gh-pr-watcher}"
fi

# Aplikace notifikátoru. Musí ležet pod ${HOME}/Applications — z jiného
# umístění macOS oprávnění k oznámením odmítne
# (docs/mac/usernotifications-lokalni-aplikace.md).
: "${GH_PR_WATCHER_APP:=${HOME}/Applications/gh-pr-watcher.app}"

# Příkaz, kterým hlídač zobrazí jednu bublinu (shellový řetězec pro eval,
# vyhodnocuje se až při volání). Dostává exportované proměnné
# GH_PR_WATCHER_ID (identifikátor bubliny — stejný nahradí předchozí bublinu
# téhož druhu), GH_PR_WATCHER_TITLE, GH_PR_WATCHER_BODY, GH_PR_WATCHER_CLICK
# (shell příkaz pro kliknutí na tělo / tlačítko Terminál) a GH_PR_WATCHER_URL
# (tlačítko GitHub). Jiný notifikátor se stejným rozhraním lze dosadit
# v .local.sh. Výstup aplikace (potvrzení doručení, nebo chyba oprávnění) jde
# do notifier.log ve stavovém adresáři — open se vrací hned a návratový kód
# aplikace nevidí. Jednoduché uvozovky záměrně: proměnné se expandují až při
# eval, proto ne přes : "${VAR:=…}".
if [[ -z "${GH_PR_WATCHER_NOTIFIER:-}" ]]; then
  GH_PR_WATCHER_NOTIFIER='open -g -n "$GH_PR_WATCHER_APP" --stdout "$GH_PR_WATCHER_STATE_DIR/notifier.log" --stderr "$GH_PR_WATCHER_STATE_DIR/notifier.log" --args --id "$GH_PR_WATCHER_ID" --title "$GH_PR_WATCHER_TITLE" --body "$GH_PR_WATCHER_BODY" --click "$GH_PR_WATCHER_CLICK" --url "$GH_PR_WATCHER_URL"'
fi

# Co provede kliknutí na tělo bubliny nebo tlačítko Terminál (zapisuje se při
# instalaci do on-click.sh). Prázdné = výchozí
# open "${GH_PR_WATCHER_STATE_DIR}/pr-inbox.command" (Terminal.app spustí
# gh-pr-list + gh-pr-inbox v interaktivním Bashi 5); výchozí se neskládá
# zde, aby respektovalo GH_PR_WATCHER_STATE_DIR přepsaný v .local.sh.
# iTerm2: open -a iTerm "<cesta k pr-inbox.command>".
: "${GH_PR_WATCHER_CLICK_CMD:=}"

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

# Kořen pracovních rep funkcí (docs/implementovano/navrh/pracovni-repa-funkci.md): trvalé
# klony (gov repo, řídicí repa migrace), se kterými pracují výhradně funkce.
# Není to cache — obsah se commituje a pushuje; nesmí ho mazat čisticí nástroje.
# Nezapomeň: používej ${HOME}/..., ne ~/... (tilda se neexpanduje ve všech kontextech).
: "${GH_WORK_REPOS_ROOT:=${HOME}/.local/state/gh-work}"

# Strategie merge pull requestu pro gh-pr-merge: merge (merge commit) nebo
# squash. Výchozí merge — release tok opakovaně merguje tutéž integrační
# větev do výchozí větve a opakovaný merge dlouhožijící větve funguje jen
# s merge commitem (docs/implementovano/navrh/gh-pr-funkce.md). Squash lze
# zvolit per PR volbou --squash; jiná hodnota proměnné je chyba.
: "${GH_PR_MERGE_STRATEGY:=merge}"

# Pager pro diff v gh-pr-diff, když je stdout terminál (v rouře/přesměrování
# se nepoužije nikdy). -R nechá projít barvy, -FX ukončí krátký diff rovnou
# bez čekání na q. Prázdná hodnota = bez stránkování. Bez dvojtečky v ${...=}
# záměrně: nastavená prázdná hodnota se respektuje jako vypnuto, := by ji
# přepsalo defaultem.
: "${GH_PR_DIFF_PAGER=${PAGER:-less -RFX}}"

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

_gh-csv-to-array() {
  # Rozloží CSV hodnotu na pole položek (nameref): oddělovač čárka, položky se
  # neořezávají ani nevalidují, prázdné položky zůstávají („a,,b“ → tři,
  # „a,“ → dvě — koncová čárka je prázdná položka, kterou validátory hlásí),
  # prázdný řetězec → prázdné pole. Jen builtiny (load path conf.d). Jediná
  # implementace smyčky nad CSV klíči conf.d a hodnotami z nich.
  # Použití: _gh-csv-to-array <csv> <array_ref>
  declare -n _cta_ref="$2"
  local _rest="$1,"
  _cta_ref=()
  [[ -n "$1" ]] || return 0
  while [[ -n "$_rest" ]]; do
    _cta_ref+=("${_rest%%,*}")
    _rest="${_rest#*,}"
  done
  return 0
}

_gh-branch-name-valid() {
  # Platnost jména výchozí větve (klíč default_branch): _GH_BRANCH_NAME_REGEX,
  # navíc bez '..' a bez přípony .lock (git check-ref-format). Vrací rc 0/1.
  # Použití: _gh-branch-name-valid <jméno větve>
  _gh-match "$1" "$_GH_BRANCH_NAME_REGEX" && [[ "$1" != *..* && "$1" != *.lock ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Lokální uživatelské přepsání (gitignorováno).
# Zkopíruj gh-common-defs.local.sh.example → gh-common-defs.local.sh
# a přepiš proměnné, jejichž výchozí hodnota nevyhovuje (GH_WORKSPACE_ROOT,
# GH_EDITOR, …).
# ══════════════════════════════════════════════════════════════════════════════
# Mapování nestandardního umístění rep ve workspace (docs/implementovano/navrh/workspace-mapovani.md).
# Jen gh-common-defs.local.sh (pole nejde předat prostředím), zápis po položkách:
#   GH_WORKSPACE_MAP[<projectKey>/<vzor ghName>]=<adresář relativně ke GH_WORKSPACE_ROOT>
# Vzor = přesné ghName nebo glob jen z * a ?; repo pak leží
# v ${GH_WORKSPACE_ROOT}/<hodnota>/<ghName> (listový adresář vždy celé ghName).
# Nejdelší shodný vzor vítězí, dva různé vzory stejné délky jsou chyba; položka
# <projectKey>/* určuje i projektový adresář (gh-cd/gh-open <projectKey>). Bez
# položek se nic nemění. Validace běží líně při prvním použití
# (_gh-workspace-map-prepare), start shellu zůstává bez práce navíc. Pole musí
# být předdeklarované, jinak by zápis položky v .local.sh skončil syntax error.
declare -gA GH_WORKSPACE_MAP=()
_GH_COMMON_DIR="$(dirname "${BASH_SOURCE[0]}")"
_GH_COMMON_LOCAL="$_GH_COMMON_DIR/gh-common-defs.local.sh"
[[ -f "$_GH_COMMON_LOCAL" ]] && source "$_GH_COMMON_LOCAL"
unset _GH_COMMON_LOCAL
# Jediné místo normalizace tvaru kořene workspace (env i .local.sh).
GH_WORKSPACE_ROOT="${GH_WORKSPACE_ROOT%/}"
# Odvozené struktury mapování se staví líně; nový source = nová validace.
_GH_WS_MAP_READY=0

# Zámek a sync pracovních rep funkcí (docs/implementovano/navrh/pracovni-repa-funkci.md).
if ! source "$_GH_COMMON_DIR/lib/gh-work-repo.sh"; then
  echo "Chyba: Nepodařilo se načíst lib/gh-work-repo.sh." >&2
fi

# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# Načtení INI konfigurace conf.d/ (projects/, business-services/, profiles/)
# parserem lib/gh-conf.sh – žádné sourcování konfiguračních souborů.
# Formát: docs/readme/README_COMMON.md.
# ══════════════════════════════════════════════════════════════════════════════
# Zdroj conf.d (docs/implementovano/navrh/pracovni-repa-funkci.md):
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

_gh-confd-reload() {
  # Znovu načte conf.d z pracovního klonu gov repa jen při změně: když
  # konfigurace v paměti chybí, SHA HEAD po syncu není známé (čerstvý klon,
  # start shellu bez gitu) nebo se liší od SHA načtené konfigurace
  # (_GH_CONF_LOADED_SHA; _gh-conf-load ji ruší). Parser tak neběží při
  # každém volání funkce, jen po změně gov repa. rc = rc _gh-conf-load.
  # Použití: _gh-confd-reload
  if [[ -n "${_GH_CONF_DATA_LOADED:-}" && -n "${_GH_WORK_REPO_HEAD:-}" && \
        "$_GH_WORK_REPO_HEAD" == "${_GH_CONF_LOADED_SHA:-}" ]]; then
    return 0
  fi
  _gh-conf-load "$_GH_COMMON_CONF_D" || return 1
  _GH_CONF_LOADED_SHA="${_GH_WORK_REPO_HEAD:-}"
}

_gh-confd-sync() {
  # Synchronizuje pracovní klon gov repa (zdroj conf.d) a znovu načte
  # konfiguraci (jen při změně gov repa — _gh-confd-reload); volá se na
  # začátku každé funkce, která conf.d potřebuje.
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
  if ! _gh-confd-reload; then
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

_gh-confirm() {
  # Sdílený potvrzovací dotaz [Y/N] uživatelských funkcí (gh-functions-user.sh)
  # i toolů ve tools/ (ty gh-functions-user.sh nenačítají — proto je zde).
  # skip_confirm=true (přepínač --yes) = souhlas bez čtení stdin; bez TTY
  # (roura, EOF) read selže a prázdná odpověď = ne. Hlášku o zrušení
  # („Akce zrušena.“) vypisuje volající. Vzor _bb-migration-confirm
  # (bb-migrate si drží vlastní kvůli rc 2 bez TTY).
  # Použití: _gh-confirm <otázka> [skip_confirm true|false]  → return 0 = ano, 1 = ne
  local _question="$1" _skip="${2:-false}" _answer
  [[ "$_skip" == true ]] && return 0
  read -r -p "$_question [Y/N] " _answer || _answer=""
  [[ "$_answer" =~ ^[Yy]$ ]]
}

_gh-workspace-map-error() {
  # Chyba položky mapování workspace jmenující položku; vrací 1.
  # Použití: _gh-workspace-map-error <klíč> <hodnota> <důvod>
  echo "Chyba: GH_WORKSPACE_MAP[$1]='$2': $3 (gh-common-defs.local.sh)." >&2
  return 1
}

_gh-workspace-map-check-entry() {
  # Validace jedné položky mapování (docs/implementovano/navrh/workspace-mapovani.md,
  # Omezení): klíč <projectKey>/<vzor ghName> s jediným '/', vzor podle
  # _GH_WS_PATTERN_REGEX bez '**', hodnota podle _GH_WS_VALUE_REGEX bez
  # segmentů '.' a '..'. Každá chyba jmenuje položku.
  # Použití: _gh-workspace-map-check-entry <klíč> <hodnota>
  local _key="$1" _val="$2" _pk _pat
  if [[ "$_key" != */* ]]; then
    _gh-workspace-map-error "$_key" "$_val" "klíč musí mít tvar <projectKey>/<vzor ghName>"; return 1
  fi
  _pk="${_key%%/*}"; _pat="${_key#*/}"
  if [[ "$_pat" == */* ]]; then
    _gh-workspace-map-error "$_key" "$_val" "klíč smí obsahovat jediné '/' (<projectKey>/<vzor ghName>)"; return 1
  fi
  if ! _gh-match "$_pk" "$_GH_PROJECT_KEY_REGEX"; then
    _gh-workspace-map-error "$_key" "$_val" "projectKey '$_pk' neodpovídá formátu $_GH_PROJECT_KEY_REGEX"; return 1
  fi
  if ! _gh-match "$_pat" "$_GH_WS_PATTERN_REGEX" || [[ "$_pat" == *'**'* ]]; then
    _gh-workspace-map-error "$_key" "$_val" "vzor '$_pat' smí obsahovat jen malá písmena, číslice, . _ - a glob znaky * ? (ne **)"; return 1
  fi
  if ! _gh-match "$_val" "$_GH_WS_VALUE_REGEX"; then
    _gh-workspace-map-error "$_key" "$_val" "hodnota musí být relativní cesta ze segmentů [A-Za-z0-9._-] oddělených '/' (bez úvodního a koncového '/', '//', '\\' a mezer)"; return 1
  fi
  if [[ "/$_val/" == *"/../"* || "/$_val/" == *"/./"* ]]; then
    _gh-workspace-map-error "$_key" "$_val" "hodnota nesmí obsahovat segmenty '.' a '..'"; return 1
  fi
  return 0
}

_gh-workspace-containers-insert() {
  # Vloží cestu do seřazeného pole _GH_WS_CONTAINERS (insertion sort jen
  # builtiny; řazení v C locale, aby byl výčet gh-sync/gh-status deterministický).
  # Použití: _gh-workspace-containers-insert <abs cesta>
  local LC_ALL=C
  local _new="$1" _i=${#_GH_WS_CONTAINERS[@]}
  while (( _i > 0 )) && [[ "${_GH_WS_CONTAINERS[_i-1]}" > "$_new" ]]; do
    _GH_WS_CONTAINERS[_i]="${_GH_WS_CONTAINERS[_i-1]}"
    (( _i-- ))
  done
  _GH_WS_CONTAINERS[_i]="$_new"
}

_gh-workspace-map-prepare() {
  # Jednorázová (per shell a kořen workspace) validace GH_WORKSPACE_MAP
  # a stavba odvozených struktur: _GH_WS_CONTAINER[<abs cesta>]=<projectKey …>
  # (kontejner = ${GH_WORKSPACE_ROOT}/<hodnota>; mezerou oddělené projekty,
  # které do něj míří — jednu složku smí sdílet víc projektů, např. všechna
  # CI/CD repa; ghName se v ní pak nesmí opakovat), _GH_WS_SKIP[<abs cesta>]=<klíč>
  # (kontejnery a všichni jejich předci pod kořenem — výčet je nevypisuje jako
  # repa, cesta repa se s nimi nesmí krýt), _GH_WS_CONTAINERS (kontejnery
  # seřazené). Při chybě zůstane _GH_WS_MAP_READY=0 a chyba se opakuje při
  # každém použití, dokud ji uživatel neopraví.
  # Použití: _gh-workspace-map-prepare || return 1
  [[ "${_GH_WS_MAP_READY:-0}" -eq 1 && "${_GH_WS_MAP_ROOT:-}" == "$GH_WORKSPACE_ROOT" ]] && return 0
  _require_vars GH_WORKSPACE_ROOT || return 1
  local _key _val _dir _pk
  declare -gA _GH_WS_CONTAINER=() _GH_WS_SKIP=()
  declare -ga _GH_WS_CONTAINERS=()
  for _key in "${!GH_WORKSPACE_MAP[@]}"; do
    _val="${GH_WORKSPACE_MAP[$_key]}"
    _gh-workspace-map-check-entry "$_key" "$_val" || return 1
    _pk="${_key%%/*}"
    _dir="${GH_WORKSPACE_ROOT}/${_val}"
    if [[ -z "${_GH_WS_CONTAINER[$_dir]:-}" ]]; then
      _GH_WS_CONTAINER[$_dir]="$_pk"
      _gh-workspace-containers-insert "$_dir"
    elif [[ " ${_GH_WS_CONTAINER[$_dir]} " != *" $_pk "* ]]; then
      _GH_WS_CONTAINER[$_dir]+=" $_pk"
    fi
    while [[ "$_dir" != "$GH_WORKSPACE_ROOT" ]]; do
      [[ -n "${_GH_WS_SKIP[$_dir]:-}" ]] || _GH_WS_SKIP[$_dir]="$_key"
      _dir="${_dir%/*}"
    done
  done
  _GH_WS_MAP_ROOT="$GH_WORKSPACE_ROOT"
  _GH_WS_MAP_READY=1
  return 0
}

_gh-workspace-map-resolve() {
  # Najde kontejner (hodnotu položky) pro repo <projectKey>/<ghName>: ze
  # shodných vzorů projektu vítězí nejdelší (přesné jméno > pay-* > *); dvě
  # různé shody stejné délky = chyba jmenující obě položky. Nameref dostane
  # hodnotu položky, bez shody prázdno. Glob porovnání [[ == $vzor ]] —
  # vzor je validovaný jen na * a ? (bez rozsahů, locale nehraje roli).
  # Použití: local _c; _gh-workspace-map-resolve <projectKey> <ghName> _c || return 1
  local _pk="$1" _name="$2" _key _pat _best="" _best_key="" _tie=""
  declare -n _gwmr_ref="$3"
  _gwmr_ref=""
  for _key in "${!GH_WORKSPACE_MAP[@]}"; do
    [[ "${_key%%/*}" == "$_pk" ]] || continue
    _pat="${_key#*/}"
    [[ "$_name" == $_pat ]] || continue
    if [[ -z "$_best_key" || ${#_pat} -gt ${#_best} ]]; then
      _best="$_pat"; _best_key="$_key"; _tie=""
    elif [[ ${#_pat} -eq ${#_best} ]]; then
      _tie="$_key"
    fi
  done
  if [[ -n "$_tie" ]]; then
    echo "Chyba: ghName '$_name' projektu '$_pk' odpovídá dvěma vzorům stejné délky: GH_WORKSPACE_MAP[$_best_key] a GH_WORKSPACE_MAP[$_tie] (gh-common-defs.local.sh)." >&2
    return 1
  fi
  [[ -n "$_best_key" ]] && _gwmr_ref="${GH_WORKSPACE_MAP[$_best_key]}"
  return 0
}

_gh-workspace-path() {
  # Naplní nameref absolutní cestou workspace adresáře projektu (prázdné
  # ghName) nebo repa. Standardně ${GH_WORKSPACE_ROOT}/<projectKey>[/<ghName>];
  # s položkou mapování ${GH_WORKSPACE_ROOT}/<hodnota>/<ghName>, projektový
  # adresář podle položky <projectKey>/*. Jediné místo skládání workspace cest
  # — bez forku, vhodné do smyček (gh-project-clone); _gh-workspace-dir je
  # echo obal pro $(…). Cesta repa krytá s kontejnerem mapování nebo jeho
  # předkem je chyba (gh-delete by jinak smazal kontejner i s repy).
  # Použití: local _p; _gh-workspace-path <projectKey> <ghName|""> _p || return 1
  # Selže s chybou pokud GH_WORKSPACE_ROOT není nastavena nebo mapování neprojde.
  local _key="$1" _name="$2" _container=""
  declare -n _gwp_ref="$3"
  _gh-workspace-map-prepare || return 1
  if [[ -n "$_name" ]]; then
    _gh-workspace-map-resolve "$_key" "$_name" _container || return 1
  else
    _container="${GH_WORKSPACE_MAP[$_key/*]:-}"
  fi
  _gwp_ref="${GH_WORKSPACE_ROOT}/${_container:-$_key}"
  [[ -n "$_name" ]] && _gwp_ref+="/${_name}"
  if [[ -n "$_name" && -n "${_GH_WS_SKIP[$_gwp_ref]:-}" ]]; then
    echo "Chyba: Cesta repa '$_gwp_ref' se kryje s adresářem položky GH_WORKSPACE_MAP[${_GH_WS_SKIP[$_gwp_ref]}] (gh-common-defs.local.sh)." >&2
    _gwp_ref=""
    return 1
  fi
  return 0
}

_gh-workspace-dir() {
  # Vypíše absolutní cestu k workspace adresáři pro daný projectKey (a volitelně ghName).
  # Použití: _gh-workspace-dir <projectKey> [ghName]
  # Selže s chybou pokud GH_WORKSPACE_ROOT není nastavena.
  local _path
  _gh-workspace-path "$1" "${2:-}" _path || return 1
  echo "$_path"
}

_gh-git-origin-url() {
  # Naplní nameref URL remote origin klonu bez spuštění gitu: čte sekci
  # [remote "origin"] v <dir>/.git/config builtiny (výčet stovek rep ve
  # workspace bez forku na repo); .git jiného tvaru (soubor gitdir u worktree
  # či submodulu) → git remote get-url. Bez originu nebo mimo git repo
  # prázdno; vždy rc 0.
  # Použití: local _u; _gh-git-origin-url <dir> _u
  local _dir="$1" _line _in=0
  declare -n _ggou_ref="$2"
  _ggou_ref=""
  if [[ -f "$_dir/.git/config" ]]; then
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      _line="${_line%$'\r'}"
      case "$_line" in
        '[remote "origin"]') _in=1 ;;
        '['*) _in=0 ;;
        *) if (( _in )) && [[ "$_line" =~ ^[[:space:]]*url[[:space:]]*=[[:space:]]*(.*)$ ]]; then
             _ggou_ref="${BASH_REMATCH[1]}"
             return 0
           fi ;;
      esac
    done < "$_dir/.git/config"
    return 0
  fi
  [[ -e "$_dir/.git" ]] || return 0
  _ggou_ref=$(git -C "$_dir" remote get-url origin 2>/dev/null)
  return 0
}

_gh-workspace-dir-children() {
  # Přidá do nameref pole repa (podadresáře) jednoho rodiče pro výčet
  # workspace. Dítě rovné kontejneru mapování nebo jeho předkovi
  # (_GH_WS_SKIP) se vynechá (kontejner s .git = varování, kryje se s repem).
  # S projectKey jde do výčtu jen repo tohoto projektu podle remote origin
  # (_gh-repo-resolve-exact) — položky mapování určují jen umístění, ne
  # příslušnost; repo jiného projektu, klon z Bitbucketu s nepřepnutým
  # origin i klon bez origin se přeskočí a jejich počet za rodiče jde na
  # stderr. Adresář bez .git zůstává (volající ho ohlásí). Glob bez
  # nullglob: guard [[ -d ]].
  # Použití: _gh-workspace-dir-children <rodič> <projectKey|""> <jméno pole>
  local _parent="$1" _key="$2" _d _url _foreign=0
  declare -n _gwdc_ref="$3"
  local -A _rr=()
  for _d in "$_parent"/*/; do
    _d="${_d%/}"
    [[ -d "$_d" ]] || continue
    if [[ -n "${_GH_WS_SKIP[$_d]:-}" ]]; then
      [[ -d "$_d/.git" ]] && echo "Varování: Adresář položky GH_WORKSPACE_MAP[${_GH_WS_SKIP[$_d]}] '$_d' je git repozitář – kryje se s repem (gh-common-defs.local.sh)." >&2
      continue
    fi
    if [[ -n "$_key" && -e "$_d/.git" ]]; then
      _gh-git-origin-url "$_d" _url
      _rr=()
      if ! _gh-repo-resolve-exact _rr "$_url" 2>/dev/null || [[ "${_rr[projectKey]}" != "$_key" ]]; then
        (( _foreign++ ))
        continue
      fi
    fi
    _gwdc_ref+=("$_d")
  done
  (( _foreign > 0 )) && echo "Přeskočeno (repa jiných projektů ve složce ${_parent#"$GH_WORKSPACE_ROOT"/}): $_foreign" >&2
  return 0
}

_gh-workspace-dirs() {
  # Naplní nameref pole cestami workspace adresářů (kandidátů na repa) pro
  # gh-sync a gh-status: s projectKey+ghName jediná cesta repa; s projectKey
  # děti projektového adresáře a kontejnerů položek mapování daného projektu
  # (sdílený kontejner patří každému projektu, který do něj míří), z nich jen
  # repa tohoto projektu podle origin (_gh-workspace-dir-children); bez
  # argumentů děti všech adresářů pod kořenem a všech kontejnerů bez filtru.
  # Princip „rodiče → děti“: rodiče se deduplikují a dítě rovné kontejneru
  # mapování nebo jeho předkovi (_GH_WS_SKIP) se vynechá — každé repo je ve
  # výčtu právě jednou a kontejnery se nehlásí jako „není git repozitář“.
  # Bez položek = dvouúrovňový výčet ${GH_WORKSPACE_ROOT}/*/*/ jako dřív.
  # Použití: local -a _dirs=(); _gh-workspace-dirs <projectKey> <ghName> _dirs || return 1
  # Selže s chybou pokud GH_WORKSPACE_ROOT není nastavena nebo mapování neprojde.
  local _key="$1" _repo="$2"
  declare -n _dirs_ref="$3"
  local _p _d _c
  local -a _parents=()
  local -A _seen=()
  _gh-workspace-map-prepare || return 1
  if [[ -n "$_repo" ]]; then
    _gh-workspace-path "$_key" "$_repo" _p || return 1
    _dirs_ref+=("$_p")
    return 0
  fi
  if [[ -n "$_key" ]]; then
    _gh-workspace-path "$_key" "" _p || return 1
    _parents+=("$_p")
    for _c in "${_GH_WS_CONTAINERS[@]}"; do
      [[ " ${_GH_WS_CONTAINER[$_c]} " == *" $_key "* ]] && _parents+=("$_c")
    done
  else
    for _d in "${GH_WORKSPACE_ROOT}"/*/; do
      [[ -d "$_d" ]] && _parents+=("${_d%/}")
    done
    _parents+=("${_GH_WS_CONTAINERS[@]}")
  fi
  for _p in "${_parents[@]}"; do
    [[ -n "${_seen[$_p]:-}" ]] && continue
    _seen[$_p]=1
    _gh-workspace-dir-children "$_p" "$_key" "$3"
  done
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
  # Varianta pro workspace funkce s volitelným repem (gh-open, gh-cd, gh-sync,
  # gh-status): jediný poziční argument bez '/' a bez prefixu <GH_REPO_PREFIX>- je projectKey
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

_gh-repo-resolve-or-cwd() {
  # Varianta pro repo-lokální funkce s volitelným repem (gh-info, gh-pr*):
  # bez pozičních argumentů se repo odvodí z remote origin git repozitáře
  # v aktuálním adresáři (přes git rev-parse funguje i z podadresáře klonu),
  # s argumenty jde vše přes _gh-repo-resolve-exact. Origin URL projde
  # resolverem (https i git@ tvar; tokenizovanou URL resolver ořízne) —
  # i repo z aktuálního adresáře musí být spravované.
  # Použití: local -A _rr=(); _gh-repo-resolve-or-cwd _rr "${_pos[@]}" || return 1
  if [[ $# -ge 2 ]]; then
    _gh-repo-resolve-exact "$@"
    return $?
  fi
  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Chyba: Aktuální adresář není git repozitář (nebo zadej <repo>, viz gh-help)." >&2
    return 1
  fi
  local _grrc_url
  _grrc_url=$(git remote get-url origin 2>/dev/null)
  if [[ -z "$_grrc_url" ]]; then
    echo "Chyba: Remote 'origin' není nastaven." >&2
    return 1
  fi
  _gh-repo-resolve-exact "$1" "$_grrc_url"
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

_gh-iso-epoch() {
  # Převede čas ISO 8601 v UTC z GitHub API (2026-01-10T12:00:00Z) na sekundy
  # od epochy. GNU date zná -d (Linux, Git Bash); BSD date na macOS -d nemá
  # (illegal option) a parsuje -j -f s pevným formátem — GNU varianta první,
  # BSD jako fallback (docs/bash/macos-prenositelnost.md). Nečitelný čas →
  # rc 1 bez výstupu (volající rozhodne: „?", continue, return 1).
  # Použití: _epoch=$(_gh-iso-epoch <ISO 8601 UTC>) || …
  date -u -d "$1" +%s 2>/dev/null && return 0
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

_gh-file-mtime-fmt() {
  # Vypíše čas poslední změny souboru v lokálním čase podle strftime formátu.
  # Epochu čte GNU stat -c %Y (Linux, Git Bash), jinak BSD stat -f %m (macOS;
  # -c je tam illegal option). GNU varianta musí být první: GNU stat -f %m by
  # nehlásil chybu, ale vypsal mount point. Formátuje printf %()T bez dalšího
  # procesu (bash ≥ 4.2); GNU `date -r <soubor>` by na BSD date znamenalo
  # epochu v sekundách (docs/bash/macos-prenositelnost.md). Neexistující
  # soubor → rc 1 bez výstupu.
  # Použití: _gh-file-mtime-fmt <soubor> <strftime formát>
  local _epoch
  _epoch=$(stat -c %Y -- "$1" 2>/dev/null) || _epoch=$(stat -f %m -- "$1" 2>/dev/null) || return 1
  printf "%($2)T\n" "$_epoch"
}

_gh-epoch-hm() {
  # Vypíše čas z epochy v lokálním čase krátce: dnes jen HH:MM, jiný den
  # DD.MM. HH:MM (konec odkladu hlídače PR — gh-pr-snooze, pr-watcher.sh;
  # stejný tvar vypisuje pr-watcher.ps1). printf %()T bez dalšího procesu;
  # %d a %m s nulami záměrně — %-d BSD strftime na macOS nezná.
  # Použití: _gh-epoch-hm <epocha>
  if [[ "$(printf '%(%Y%m%d)T' "$1")" == "$(printf '%(%Y%m%d)T' -1)" ]]; then
    printf '%(%H:%M)T\n' "$1"
  else
    printf '%(%d.%m. %H:%M)T\n' "$1"
  fi
}

_gh-now-ms() {
  # Naplní nameref aktuálním časem v milisekundách od epochy — měření doby
  # kroku ve smyčkách s ETA (_bb-eta-print). Bez forku: čte $EPOCHREALTIME
  # (bash ≥ 5.0, mikrosekundy). Jeho desetinný oddělovač se řídí LC_NUMERIC
  # (pod cs_CZ čárka; přímé $(( EPOCHREALTIME )) by přes operátor čárka tiše
  # vrátilo jen zlomek), proto se ponechají jen číslice (µs) a zkrátí na ms.
  # Bez $EPOCHREALTIME (bash 4.3/4.4, nebo po `unset EPOCHREALTIME`, který
  # speciální proměnnou v shellu natrvalo zruší) printf %()T (bash ≥ 4.2):
  # celé sekundy × 1000, ETA měří hrubě. `date +%s%3N` nelze: BSD date na
  # macOS %N nezná, vrátí „…3N" a aritmetika padá („value too great for
  # base", docs/bash/macos-prenositelnost.md). Lokální jména mají prefix
  # _gnm_, aby se na ně nameref volajícího nenavázal.
  # Použití: _gh-now-ms <nameref výsledku>
  declare -n _gnm_ref="$1"
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local _gnm_us="${EPOCHREALTIME//[^0-9]/}"
    _gnm_ref=$(( 10#$_gnm_us / 1000 ))
  else
    printf -v _gnm_ref '%(%s)T000' -1
  fi
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
  # Háček hlášení čekajících PR: brána je společný vstup všech pracovních
  # funkcí gh-* (přímo i přes _gh-confd-sync); definici má jen
  # gh-functions-user.sh, bb-migrate.sh ji nemá → nic.
  declare -F _gh-pr-pending-notice >/dev/null && _gh-pr-pending-notice
  return 0
}

_GH_SCRIPTS_VERSION=""
_gh-version-load

# ══════════════════════════════════════════════════════════════════════════════

#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Distribuce spravované sekce .github/CODEOWNERS a doprovodného
# CODEOWNERS_README.md do spravovaných rep podle klíče pr_reviewers_team
# (defs/defs.md; docs/plans/plan-codeowners-distribuce.md). Rozhodovací
# logika je v čistých funkcích (offline testy), zápisy jdou přes Contents
# API (jeden commit na soubor, bez klonu; přes rulesety projde bot jako
# bypass actor). Jediné místo, kde reconcile zapisuje obsah spravovaných
# rep — výhradně v souborech/sekcích označených vlastními značkami.
# Závislosti: gh-common-defs.sh (_gh-match, topicy migrace), lib/gh-conf.sh
# (_GH_CONF), lib/gh-governance-report.sh, lib/gh-governance-state.sh
# (_gh-governance-checkout-root, _gh-governance-state-read),
# lib/gh-governance-deploy-manifest.sh (strip hlavičky šablon).
[[ -n "${_GH_GOVERNANCE_CODEOWNERS_LOADED:-}" ]] && \
  declare -F _gh-governance-reconcile-codeowners >/dev/null && return 0
_GH_GOVERNANCE_CODEOWNERS_LOADED=1

_GH_GOVERNANCE_CODEOWNERS_PATH=".github/CODEOWNERS"
_GH_GOVERNANCE_CODEOWNERS_README_PATH=".github/CODEOWNERS_README.md"
# Značky spravované sekce — vlastní konstanty reconcile (soubor negeneruje
# gov-sync, hlavička GENEROVANO sem nepatří). ASCII kvůli přesné shodě řádku.
_GH_GOVERNANCE_CODEOWNERS_BEGIN='# >>> SPRAVOVANA SEKCE governance reconcile -- needitovat, obsah prepisuje denni reconcile >>>'
_GH_GOVERNANCE_CODEOWNERS_END='# <<< KONEC SPRAVOVANE SEKCE governance reconcile <<<'
# Prefix prvního řádku oznámení v ručně spravovaném souboru bez sekce.
_GH_GOVERNANCE_CODEOWNERS_NOTICE_MARK='# UPOZORNENI governance:'
# Hlavička generovaného README (varianta hlavičky GENEROVANO pro reconcile —
# generovaný obsah ve spravovaných repech; defs/defs-governance-repo.md).
# README se maže jen s touto hlavičkou na prvním řádku (nikdy cizí soubor).
_GH_GOVERNANCE_CODEOWNERS_HEADER_MD='<!-- GENEROVANO reconcile -- needitovat, prepise kazdy beh -->'
# Šablony v checkoutu gov repa (nasazuje gov-sync z governance/templates/).
_GH_GOVERNANCE_CODEOWNERS_TEMPLATE="templates/CODEOWNERS-section.template"
_GH_GOVERNANCE_CODEOWNERS_README_TEMPLATE="templates/CODEOWNERS_README.template"

_gh-governance-codeowners-owner-from-slug() {
  # Převede slug týmu na vlastníka pro řádek CODEOWNERS: "@<org>/<tym>".
  # Prázdný slug → prázdný výstup. Čistá funkce.
  # Použití: _gh-governance-codeowners-owner-from-slug <slug> <nameref>
  declare -n _oc_ref="$2"
  _oc_ref=""
  [[ -n "$1" ]] || return 0
  _oc_ref="@${GITHUB_ORG}/$1"
}

_gh-governance-codeowners-owners() {
  # Vlastník dle aktuální konfigurace projektu (klíč pr_reviewers_team).
  # Použití: _gh-governance-codeowners-owners <projectKey> <nameref>
  _gh-governance-codeowners-owner-from-slug \
    "${_GH_CONF[projects/$1/pr_reviewers_team]:-}" "$2"
}

_gh-governance-codeowners-old-owners() {
  # Vlastníci dle konfigurace v commitu ukazatele posledního aplikovaného
  # stavu — heuristika pro rozlišení „ruční zásah do sekce" (warning) od
  # „legitimní změna conf.d" (info). Klíč čte přímo z git objektu bez
  # parseru (stará verze smí být i nevalidní; jde jen o úroveň hlášení).
  # Prázdný výstup = klíč tehdy nebyl, soubor/SHA neexistuje, nebo bez SHA.
  # Použití: _gh-governance-codeowners-old-owners <root> <sha> <projectKey> <nameref>
  declare -n _oo_ref="$4"
  local _line _slug=""
  _oo_ref=""
  [[ -n "$2" ]] || return 0
  while IFS= read -r _line; do
    _line="${_line%$'\r'}"
    [[ "$_line" == pr_reviewers_team=* ]] && { _slug="${_line#pr_reviewers_team=}"; break; }
  done < <(git -C "$1" show "$2:conf.d/projects/$3.conf" 2>/dev/null)
  _gh-governance-codeowners-owner-from-slug "$_slug" "$4"
}

_gh-governance-codeowners-expand() {
  # Expanduje šablonu do nameref: odstraní hlavičku GENEROVANO gov-sync
  # (v gov repu ji nese každý nasazený soubor) a nahradí {{PROJECT_KEY}}
  # a {{OWNERS}}.
  # Použití: _gh-governance-codeowners-expand <soubor> <projectKey> <owners> <nameref>
  declare -n _ce_ref="$4"
  local _content
  if [[ ! -f "$1" ]]; then
    echo "Chyba: Šablona '$1' neexistuje (nasazuje ji gov-sync)." >&2
    return 1
  fi
  _content=$(_gh-governance-deploy-manifest-header-strip < "$1") || return 1
  _content="${_content//\{\{PROJECT_KEY\}\}/$2}"
  _content="${_content//\{\{OWNERS\}\}/$3}"
  _ce_ref="$_content"
}

_gh-governance-codeowners-section() {
  # Sestaví celou spravovanou sekci: značka začátku, expandovaná šablona,
  # značka konce (bez koncového \n — řádkování řeší skládání obsahu).
  # Použití: _gh-governance-codeowners-section <root> <projectKey> <owners> <nameref>
  declare -n _cs_ref="$4"
  local _body
  _gh-governance-codeowners-expand \
    "$1/$_GH_GOVERNANCE_CODEOWNERS_TEMPLATE" "$2" "$3" _body || return 1
  _cs_ref="${_GH_GOVERNANCE_CODEOWNERS_BEGIN}"$'\n'"${_body}"$'\n'"${_GH_GOVERNANCE_CODEOWNERS_END}"
}

_gh-governance-codeowners-notice() {
  # Blok oznámení pro soubor bez spravované sekce (vkládá se na začátek).
  # Použití: _gh-governance-codeowners-notice <projectKey> <nameref>
  declare -n _cn_ref="$2"
  _cn_ref="${_GH_GOVERNANCE_CODEOWNERS_NOTICE_MARK} tento soubor NENI pod spravou
# governance reconcile (chybi spravovana sekce), ackoli projekt '$1' ma
# v conf.d klic pr_reviewers_team — automaticke zadosti o review se z konfigurace
# neaplikuji. Obnoveni spravy: smazte tento soubor, pristi denni reconcile ho
# zalozi znovu se spravovanou sekci (vlastni pravidla si predtim zalohujte)."
}

_gh-governance-codeowners-split() {
  # Rozloží obsah CODEOWNERS na část před sekcí, sekci (včetně značek) a část
  # za sekcí. rc 0 = sekce nalezena; rc 1 = bez sekce. Poškozené značky (jen
  # jedna z dvojice) se považují za „bez sekce" — obsah se pak nepřepisuje,
  # řeší ho větev oznámení. Čistá funkce.
  # Použití: _gh-governance-codeowners-split <obsah> <before_ref> <section_ref> <after_ref>
  declare -n _sp_before="$2" _sp_sec="$3" _sp_after="$4"
  local _line _state=before
  _sp_before=""; _sp_sec=""; _sp_after=""
  # printf místo <<< — herestring by na konec přidal umělý prázdný řádek
  # (obsah končící \n by po rekonstrukci před/sekce/za o řádek narostl).
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    case "$_state" in
      before)
        if [[ "$_line" == "$_GH_GOVERNANCE_CODEOWNERS_BEGIN" ]]; then
          _state=in
          _sp_sec="$_line"
        else
          _sp_before+="${_line}"$'\n'
        fi ;;
      in)
        _sp_sec+=$'\n'"$_line"
        [[ "$_line" == "$_GH_GOVERNANCE_CODEOWNERS_END" ]] && _state=after ;;
      after)
        _sp_after+="${_line}"$'\n' ;;
    esac
  done < <(printf '%s' "$1")
  [[ "$_state" == after ]]
}

_gh-governance-codeowners-has-notice() {
  # rc 0, obsahuje-li obsah řádek oznámení (prefix značky). Čistá funkce.
  # Použití: _gh-governance-codeowners-has-notice <obsah>
  local _line
  while IFS= read -r _line; do
    [[ "$_line" == "$_GH_GOVERNANCE_CODEOWNERS_NOTICE_MARK"* ]] && return 0
  done <<< "$1"
  return 1
}

_gh-governance-codeowners-plan() {
  # Rozhodne akci nad CODEOWNERS dle tabulky chování plánu. Čistá funkce.
  # Akce: create  – soubor neexistuje → založit se sekcí,
  #       rewrite – sekce existuje a liší se → přepsat jen sekci,
  #       noop    – sekce souhlasí s konfigurací,
  #       notice  – soubor bez sekce i oznámení → vložit oznámení na začátek,
  #       warn    – soubor bez sekce, oznámení už má → jen trvalý warning,
  #       remove  – klíč odebrán, sekce existuje, zbývá další obsah,
  #       delete  – klíč odebrán, po odebrání sekce zbude jen bílé místo,
  #       none    – nic (klíč nezadán a soubor cizí nebo žádný).
  # Nový obsah souboru plní <content_ref> (jen pro create|rewrite|notice|remove).
  # Použití: _gh-governance-codeowners-plan <exists 0|1> <obsah> <sekce|''>
  #          <oznámení> <action_ref> <content_ref>
  # Lokály s prefixem _pl_ — bez něj by nameref na proměnnou volajícího mohl
  # kolidovat s lokálem stejného jména a zapisovat mimo volajícího.
  local _pl_exists="$1" _pl_cur="$2" _pl_sec="$3" _pl_not="$4"
  declare -n _pl_action="$5" _pl_content="$6"
  local _pl_before="" _pl_found="" _pl_after="" _pl_rest
  _pl_action=none
  _pl_content=""
  if [[ -z "$_pl_sec" ]]; then
    # pr_reviewers_team nezadán: úklid vlastní sekce; cizí obsah se nechává být.
    [[ "$_pl_exists" == 1 ]] || return 0
    _gh-governance-codeowners-split "$_pl_cur" _pl_before _pl_found _pl_after \
      || return 0
    _pl_rest="${_pl_before}${_pl_after}"
    if [[ -z "${_pl_rest//[[:space:]]/}" ]]; then
      _pl_action=delete
    else
      _pl_action=remove
      _pl_content="$_pl_rest"
    fi
    return 0
  fi
  if [[ "$_pl_exists" != 1 ]]; then
    _pl_action=create
    _pl_content="${_pl_sec}"$'\n'
    return 0
  fi
  if _gh-governance-codeowners-split "$_pl_cur" _pl_before _pl_found _pl_after; then
    if [[ "$_pl_found" == "$_pl_sec" ]]; then
      _pl_action=noop
    else
      _pl_action=rewrite
      _pl_content="${_pl_before}${_pl_sec}"$'\n'"${_pl_after}"
    fi
    return 0
  fi
  if _gh-governance-codeowners-has-notice "$_pl_cur"; then
    _pl_action=warn
  else
    _pl_action=notice
    _pl_content="${_pl_not}"$'\n'"${_pl_cur}"
  fi
  return 0
}

_gh-governance-codeowners-file-read() {
  # Načte soubor spravovaného repa přes Contents API. rc 0 = načteno
  # (content + blob sha do namerefs), rc 1 = neexistuje (HTTP 404),
  # rc 2 = jiná chyba (poslední řádek stderr gh projde).
  # Použití: _gh-governance-codeowners-file-read <repoPath> <cesta> <branch>
  #          <content_ref> <sha_ref>
  declare -n _fr_content="$4" _fr_sha="$5"
  local _resp _err_file _err
  _fr_content=""; _fr_sha=""
  _err_file=$(mktemp) || return 2
  if ! _resp=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
      "repos/$1/contents/$2?ref=$3" \
      --jq '.sha + "\t" + (.content | gsub("\n";""))' 2>"$_err_file"); then
    _err=$(< "$_err_file")
    rm -f "$_err_file"
    grep -qF '(HTTP 404)' <<< "$_err" && return 1
    [[ -n "$_err" ]] && printf '%s\n' "$_err" >&2
    return 2
  fi
  rm -f "$_err_file"
  _fr_sha="${_resp%%$'\t'*}"
  _fr_content=$(printf '%s' "${_resp#*$'\t'}" | base64 -d) || return 2
  return 0
}

_gh-governance-codeowners-file-write() {
  # Založí/aktualizuje soubor přes Contents API (jeden commit do výchozí
  # větve). Prázdné <sha> = založení, jinak update existujícího blobu.
  # Použití: _gh-governance-codeowners-file-write <repoPath> <cesta> <branch>
  #          <obsah> <sha|''> <commit message>
  local _b64
  local -a _args=(-f message="$6" -f branch="$3")
  _b64=$(printf '%s' "$4" | base64 | tr -d '\n') || return 1
  _args+=(-f content="$_b64")
  [[ -n "$5" ]] && _args+=(-f sha="$5")
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api --method PUT \
    "repos/$1/contents/$2" "${_args[@]}" >/dev/null
}

_gh-governance-codeowners-file-delete() {
  # Smaže soubor přes Contents API (jeden commit do výchozí větve).
  # Použití: _gh-governance-codeowners-file-delete <repoPath> <cesta> <branch>
  #          <sha> <commit message>
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api --method DELETE \
    "repos/$1/contents/$2" \
    -f message="$5" -f branch="$3" -f sha="$4" >/dev/null
}

_gh-governance-codeowners-teams-check() {
  # Warning za tým z pr_reviewers_team bez práva write na repu — GitHub
  # CODEOWNERS vlastníka bez write ignoruje (runtime stav repa; statickou
  # vazbu na repository_teams hlídá parser conf.d). 1 GET.
  # Použití: _gh-governance-codeowners-teams-check <repoPath> <projectKey>
  local _listing _slug _perm _team
  local -A _perms=()
  _team="${_GH_CONF[projects/$2/pr_reviewers_team]:-}"
  [[ -n "$_team" ]] || return 0
  _listing=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$1/teams" \
    --paginate --jq '.[] | .slug + "\t" + .permission') || return 1
  while IFS=$'\t' read -r _slug _perm; do
    [[ -n "$_slug" ]] && _perms["$_slug"]="$_perm"
  done <<< "$_listing"
  case "${_perms[$_team]:-}" in
    push|maintain|admin) ;;
    *) _gh-governance-report-add warning "pr_reviewers_team tym bez write" "$1" \
         "tým '$_team' nemá na repu právo write (má '${_perms[$_team]:-žádné}') — GitHub ho v CODEOWNERS ignoruje" ;;
  esac
  return 0
}

_gh-governance-codeowners-readme-sync() {
  # Srovná CODEOWNERS_README.md se stavem sekce: sekce spravovaná → soubor
  # existuje s aktuálním obsahem (přepis při odchylce, bez warningu); sekce
  # nespravovaná → generovaný soubor (hlavička GENEROVANO reconcile) se
  # smaže, cizí soubor se nikdy nemaže. <managed> = 0|1.
  # Použití: _gh-governance-codeowners-readme-sync <repoPath> <branch> <root>
  #          <projectKey> <owners> <managed>
  local _repo_path="$1" _branch="$2" _root="$3" _key="$4" _owners="$5" _managed="$6"
  local _desired="" _current="" _sha="" _exists=1 _rc
  _gh-governance-codeowners-file-read "$_repo_path" \
    "$_GH_GOVERNANCE_CODEOWNERS_README_PATH" "$_branch" _current _sha
  _rc=$?
  [[ $_rc -eq 2 ]] && return 1
  [[ $_rc -eq 1 ]] && _exists=0
  if [[ "$_managed" == 1 ]]; then
    _gh-governance-codeowners-expand \
      "$_root/$_GH_GOVERNANCE_CODEOWNERS_README_TEMPLATE" "$_key" "$_owners" \
      _desired || return 1
    if [[ $_exists -eq 0 || "$_current" != "$_desired" ]]; then
      _gh-governance-codeowners-file-write "$_repo_path" \
        "$_GH_GOVERNANCE_CODEOWNERS_README_PATH" "$_branch" "$_desired"$'\n' \
        "$_sha" "governance: CODEOWNERS_README dle pr_reviewers_team" || return 1
      _gh-governance-report-add info "sprava CODEOWNERS" "$_repo_path" \
        "CODEOWNERS_README.md $( [[ $_exists -eq 0 ]] && echo založen || echo obnoven )"
    fi
    return 0
  fi
  # Sekce nespravovaná: životní cyklus README je svázaný se sekcí.
  [[ $_exists -eq 1 ]] || return 0
  [[ "${_current%%$'\n'*}" == "$_GH_GOVERNANCE_CODEOWNERS_HEADER_MD" ]] || return 0
  _gh-governance-codeowners-file-delete "$_repo_path" \
    "$_GH_GOVERNANCE_CODEOWNERS_README_PATH" "$_branch" "$_sha" \
    "governance: uklid CODEOWNERS_README (sekce neni spravovana)" || return 1
  _gh-governance-report-add info "sprava CODEOWNERS" "$_repo_path" \
    "CODEOWNERS_README.md odstraněn (sekce není spravovaná)"
  return 0
}

_gh-governance-reconcile-codeowners() {
  # Správa CODEOWNERS jednoho spravovaného nearchivovaného repa dle klíče
  # pr_reviewers_team — tabulka chování plánu. Repo s topicem migrace se
  # přeskakuje celé (opakovaná migrace zrcadlí větve z Bitbucketu, commit
  # by kolidoval), repo bez výchozí větve také. Bez klíče i sekce = 0 zápisů;
  # kontrola je stateless (1 GET na repo) — osiřelou sekci uklidí i po ztrátě
  # ukazatele. <pointer_sha> = ukazatel PŘED tímto během (heuristika úrovně
  # hlášení u přepisu sekce; po aplikaci policy už ukazatel míří na RUN_SHA).
  # rc != 0 → volající hlásí error a pokračuje dalším repem.
  # Použití: _gh-governance-reconcile-codeowners <repoName> <branch>
  #          <projectKey> <topicsCSV> <pointer_sha|''>
  local _name="$1" _branch="$2" _key="$3" _topics="$4" _pointer_sha="$5"
  local _repo_path="${GITHUB_ORG}/${_name}" _root _owners="" _old_owners=""
  local _section="" _notice="" _content="" _sha="" _exists=1 _rc
  local _action="" _new="" _old_section="" _b="" _s="" _a="" _managed=0
  [[ ",$_topics," == *",${_BB_MIGRATION_TOPIC_MARKER},"* ]] && return 0
  [[ -n "$_branch" ]] || return 0
  _root=$(_gh-governance-checkout-root) || return 1
  _gh-governance-codeowners-owners "$_key" _owners
  if [[ -n "$_owners" ]]; then
    _gh-governance-codeowners-section "$_root" "$_key" "$_owners" _section || return 1
    _gh-governance-codeowners-notice "$_key" _notice
  fi
  _gh-governance-codeowners-file-read "$_repo_path" \
    "$_GH_GOVERNANCE_CODEOWNERS_PATH" "$_branch" _content _sha
  _rc=$?
  [[ $_rc -eq 2 ]] && return 1
  [[ $_rc -eq 1 ]] && _exists=0
  _gh-governance-codeowners-plan "$_exists" "$_content" "$_section" "$_notice" \
    _action _new
  case "$_action" in
    create)
      _gh-governance-codeowners-file-write "$_repo_path" \
        "$_GH_GOVERNANCE_CODEOWNERS_PATH" "$_branch" "$_new" "" \
        "governance: CODEOWNERS se spravovanou sekci (pr_reviewers_team)" || return 1
      _gh-governance-report-add info "sprava CODEOWNERS" "$_repo_path" \
        "CODEOWNERS založen se spravovanou sekcí (${_owners})"
      _managed=1 ;;
    rewrite)
      _gh-governance-codeowners-file-write "$_repo_path" \
        "$_GH_GOVERNANCE_CODEOWNERS_PATH" "$_branch" "$_new" "$_sha" \
        "governance: sprava sekce CODEOWNERS dle pr_reviewers_team" || return 1
      # Ruční zásah vs. změna conf.d: sekce vzniklá ze staré konfigurace
      # (ukazatel před během) je legitimní stav, cokoli jiného je zásah.
      # Bez ukazatele (adopce) se zásah neprokazuje — info.
      _gh-governance-codeowners-old-owners "$_root" "$_pointer_sha" "$_key" _old_owners
      _old_section=""
      [[ -n "$_old_owners" ]] && _gh-governance-codeowners-section \
        "$_root" "$_key" "$_old_owners" _old_section
      _gh-governance-codeowners-split "$_content" _b _s _a
      if [[ -n "$_old_section" && "$_s" != "$_old_section" ]]; then
        _gh-governance-report-add warning "rucni zasah do CODEOWNERS" "$_repo_path" \
          "obsah spravované sekce se lišil bez změny konfigurace — přepsán dle conf.d"
      else
        _gh-governance-report-add info "sprava CODEOWNERS" "$_repo_path" \
          "spravovaná sekce aktualizována dle conf.d (${_owners})"
      fi
      _managed=1 ;;
    noop)
      _managed=1 ;;
    notice)
      _gh-governance-codeowners-file-write "$_repo_path" \
        "$_GH_GOVERNANCE_CODEOWNERS_PATH" "$_branch" "$_new" "$_sha" \
        "governance: oznameni v CODEOWNERS (soubor neni pod spravou)" || return 1
      _gh-governance-report-add warning "CODEOWNERS mimo spravu" "$_repo_path" \
        "soubor bez spravované sekce — vloženo oznámení; pr_reviewers_team se neaplikuje" ;;
    warn)
      _gh-governance-report-add warning "CODEOWNERS mimo spravu" "$_repo_path" \
        "soubor bez spravované sekce (oznámení už vloženo) — pr_reviewers_team se neaplikuje" ;;
    remove)
      _gh-governance-codeowners-file-write "$_repo_path" \
        "$_GH_GOVERNANCE_CODEOWNERS_PATH" "$_branch" "$_new" "$_sha" \
        "governance: uklid sekce CODEOWNERS po odebrani pr_reviewers_team" || return 1
      _gh-governance-report-add info "sprava CODEOWNERS" "$_repo_path" \
        "spravovaná sekce odstraněna po odebrání pr_reviewers_team" ;;
    delete)
      _gh-governance-codeowners-file-delete "$_repo_path" \
        "$_GH_GOVERNANCE_CODEOWNERS_PATH" "$_branch" "$_sha" \
        "governance: uklid CODEOWNERS po odebrani pr_reviewers_team" || return 1
      _gh-governance-report-add info "sprava CODEOWNERS" "$_repo_path" \
        "CODEOWNERS smazán po odebrání pr_reviewers_team (zbylo by jen bílé místo)" ;;
    none)
      # Klíč nezadán a soubor cizí nebo žádný — README nemá co uklízet
      # (životní cyklus se sekcí; generovaný bez sekce tu nikdy nevznikl).
      return 0 ;;
  esac
  _gh-governance-codeowners-readme-sync "$_repo_path" "$_branch" "$_root" \
    "$_key" "$_owners" "$_managed" || return 1
  [[ -n "$_owners" ]] && { _gh-governance-codeowners-teams-check "$_repo_path" "$_key" || return 1; }
  return 0
}

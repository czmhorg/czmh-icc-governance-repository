#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Správa souborů workflow spravovaných rep podle efektivního klíče workflows
# (defs/defs.md: workflow repa, sablona workflow; docs/implementovano/navrh/workflows-rep.md).
# Cílový stav repa = za každou položku klíče soubor
# .github/workflows/<GH_WORKFLOW_PREFIX>-<název>.yml ve výchozí větvi s hlavičkou
# GENEROVANO, řádkem zdroje a expandovanou šablonou conf.d/workflows/<název>.yml
# gov repa. Kontrola je bezstavová a levná: jeden výpis adresáře (Contents API)
# a srovnání blob SHA chtěného obsahu; obsah se stahuje jen u souborů
# s prefixem, které se liší nebo jsou navíc (rozlišení hlavičky). Soubor
# s prefixem a hlavičkou automatika vlastní (přepíše, osiřelý smaže), bez
# hlavičky jen hlásí (uživatel ho převzal), bez prefixu nikdy nečte.
# Rozhodovací logika je v čistých funkcích (offline testy), zápisy jdou přes
# lib/gh-governance-contents.sh (jeden commit na soubor; přes rulesety projde
# bot svým bypass týmem, PAT bota potřebuje scope workflow). Záměrně mimo
# _gh-repository-policy-*: policy apply volá i migrace bb-migrate a repo
# v migraci soubory mít nesmí.
# Volají ji: denní reconcile (hlavní smyčka), workflow repo-sync
# (lib/gh-governance-repo-sync.sh — jeden projekt, z issue i z pushe do
# conf.d/projects/** a conf.d/workflows/**) a workflow životního cyklu repa
# (_gh-governance-workflows-apply-note — jedno repo, řádky komentáře issue).
# Závislosti: gh-common-defs.sh (_require_vars, GH_WORKFLOW_PREFIX,
# GH_REPO_PREFIX, GITHUB_ORG, GITHUB_ORG_HOSTNAME, GH_GOVERNANCE_REPO, topic
# migrace), lib/gh-conf.sh (_gh-conf-workflows), lib/gh-governance-contents.sh
# (_gh-governance-contents-dir-list/-read/-write/-delete, _gh-governance-blob-sha,
# _GH_GOVERNANCE_WORKFLOWS_DIR),
# lib/gh-governance-report.sh (_gh-governance-report-add, _gh-governance-apply-note),
# lib/gh-governance-state.sh (_gh-governance-checkout-root), git (šablona na
# SHA ukazatele přes git show), sort (řazení plánu; mimo load path).
[[ -n "${_GH_GOVERNANCE_WORKFLOWS_LOADED:-}" ]] && \
  declare -F _gh-governance-reconcile-workflows >/dev/null && return 0
_GH_GOVERNANCE_WORKFLOWS_LOADED=1

# Hlavička generovaného souboru (varianta hlavičky GENEROVANO pro generovaný
# obsah ve spravovaných repech, defs/defs-governance-repo.md) — první řádek;
# jen soubor s touto hlavičkou automatika přepisuje a maže. ASCII kvůli přesné
# shodě řádku; validní YAML komentář.
_GH_GOVERNANCE_WORKFLOW_HEADER='# GENEROVANO reconcile -- needitovat, prepise kazdy beh'
# Druhý řádek (printf formát): šablona, gov repo <org>/<repo>, projekt.
_GH_GOVERNANCE_WORKFLOW_SOURCE_FMT='# zdroj: conf.d/workflows/%s.yml v gov repu %s (klic workflows projektu %s)'
# Adresář šablon v checkoutu gov repa; adresář souborů workflow v repu je
# _GH_GOVERNANCE_WORKFLOWS_DIR z lib/gh-governance-contents.sh (sdílený s tooly).
_GH_GOVERNANCE_WORKFLOW_TEMPLATES_DIR='conf.d/workflows'

_gh-governance-workflow-file() {
  # Cesta spravovaného souboru šablony v repu (defs/defs.md: workflow repa).
  # Použití: _gh-governance-workflow-file <název>  → stdout
  printf '%s/%s-%s.yml\n' "$_GH_GOVERNANCE_WORKFLOWS_DIR" "$GH_WORKFLOW_PREFIX" "$1"
}

_gh-governance-workflow-compose() {
  # Složí chtěný obsah souboru z textu šablony: hlavička GENEROVANO, řádek
  # zdroje, prázdný řádek, šablona s nahrazenými přesnými tokeny
  # {{PROJECT_KEY}}, {{GH_NAME}} a {{REPO_NAME}} (_gh-governance-template-expand;
  # výrazy Actions ${{ … }} zůstávají, neznámé {{…}} se nehlásí). Vždy končí
  # právě jedním \n (koncové prázdné řádky šablony se zahodí). Čistá funkce —
  # sdílí render z checkoutu i z commitu ukazatele.
  # Použití: _gh-governance-workflow-compose <text šablony> <název> <key> <ghName> <nameref>
  declare -n _wc_ref="$5"
  local _body="$1" _src
  while [[ "$_body" == *$'\n' ]]; do _body="${_body%$'\n'}"; done
  _gh-governance-template-expand "$_body" _body \
    "PROJECT_KEY=$3" "GH_NAME=$4" "REPO_NAME=${GH_REPO_PREFIX}-$3-$4"
  printf -v _src "$_GH_GOVERNANCE_WORKFLOW_SOURCE_FMT" "$2" "${GITHUB_ORG}/${GH_GOVERNANCE_REPO}" "$3"
  _wc_ref="${_GH_GOVERNANCE_WORKFLOW_HEADER}"$'\n'"${_src}"$'\n\n'"${_body}"$'\n'
}

_gh-governance-workflow-render() {
  # Chtěný obsah souboru ze šablony v checkoutu gov repa (HEAD = RUN_SHA).
  # Chybějící šablona = rc 1 s hláškou: parser conf.d ji při načtení ověřil,
  # chybí-li, je to drift checkoutu, ne konfigurace.
  # Použití: _gh-governance-workflow-render <root> <název> <key> <ghName> <nameref>
  local _file="$1/$_GH_GOVERNANCE_WORKFLOW_TEMPLATES_DIR/$2.yml" _text
  if [[ ! -f "$_file" ]]; then
    echo "Chyba: Šablona workflow '$_GH_GOVERNANCE_WORKFLOW_TEMPLATES_DIR/$2.yml' v checkoutu gov repa '$1' neexistuje (parser conf.d ji při načtení ověřil — drift checkoutu)." >&2
    return 1
  fi
  _text=$(< "$_file") || return 1
  _gh-governance-workflow-compose "$_text" "$2" "$3" "$4" "$5"
}

_gh-governance-workflow-render-at-commit() {
  # Chtěný obsah dle šablony ve verzi commitu gov repa (heuristika ručního
  # zásahu: obsah, který by dala konfigurace na SHA ukazatele). rc 1 = prázdné
  # SHA nebo šablona v té verzi neexistovala (nameref prázdný, tiše — nic se
  # neprokazuje), rc 2 = checkout nedostupný.
  # Použití: _gh-governance-workflow-render-at-commit <sha> <název> <key> <ghName> <nameref>
  declare -n _wrc_ref="$5"
  local _root _text
  _wrc_ref=""
  [[ -n "$1" ]] || return 1
  _root=$(_gh-governance-checkout-root) || return 2
  _text=$(git -C "$_root" show "$1:$_GH_GOVERNANCE_WORKFLOW_TEMPLATES_DIR/$2.yml" 2>/dev/null) || return 1
  _gh-governance-workflow-compose "$_text" "$2" "$3" "$4" "$5"
}

_gh-governance-workflows-desired() {
  # Chtěné soubory repa dle efektivního CSV šablon: do nameref řádky TSV
  # `<soubor>\t<blob sha>\t<název>` v pořadí CSV (blob SHA chtěného obsahu
  # = srovnání s výpisem adresáře bez stahování). Prázdné CSV = prázdný
  # výstup, rc 0. rc 1 = šablona chybí v checkoutu.
  # Použití: _gh-governance-workflows-desired <root> <key> <ghName> <csv> <nameref>
  declare -n _wd_ref="$5"
  local _name _content _sha
  local -a _names=()
  _wd_ref=""
  _gh-csv-to-array "$4" _names
  for _name in "${_names[@]}"; do
    [[ -n "$_name" ]] || continue
    _gh-governance-workflow-render "$1" "$_name" "$2" "$3" _content || return 1
    _sha=$(_gh-governance-blob-sha "$_content") || return 1
    _wd_ref+="${_wd_ref:+$'\n'}$(_gh-governance-workflow-file "$_name")"$'\t'"$_sha"$'\t'"$_name"
  done
  return 0
}

_gh-governance-workflows-has-header() {
  # rc 0 ⇔ první řádek obsahu je hlavička GENEROVANO (soubor je generovaný).
  # Použití: _gh-governance-workflows-has-header <obsah>
  [[ "${1%%$'\n'*}" == "$_GH_GOVERNANCE_WORKFLOW_HEADER" ]]
}

_gh-governance-workflows-plan() {
  # Rozhodne akce nad soubory workflow repa z výpisu adresáře a chtěných
  # souborů. Čistá funkce; vypíše řádky setříděné LC_ALL=C podle souboru:
  #   create\t<soubor>\t<název>               – chtěný soubor chybí,
  #   check\t<soubor>\t<název>\t<sha v repu>   – existuje, SHA se liší
  #       (orchestrace dočte obsah: hlavička → rewrite, jinak foreign),
  #   orphan\t<soubor>\t<sha v repu>           – soubor <prefix>-*.yml mimo chtěné
  #       (orchestrace dočte obsah: hlavička → delete, jinak foreign).
  # Shoda SHA = nic; položky bez prefixu nebo jiného typu než file se ignorují.
  # Použití: _gh-governance-workflows-plan <listingTSV name\tsha\ttype>
  #          <desiredTSV soubor\tsha\tnázev> <prefix>
  local _listing="$1" _desired="$2" _prefix="$3"
  local _lname _lsha _ltype _file _dsha _dname
  local -A _have=() _want=()
  local -a _rows=()
  while IFS=$'\t' read -r _lname _lsha _ltype; do
    [[ -n "$_lname" && "$_ltype" == file ]] || continue
    _have["$_lname"]="$_lsha"
  done <<< "$_listing"
  while IFS=$'\t' read -r _file _dsha _dname; do
    [[ -n "$_file" ]] || continue
    _lname="${_file##*/}"
    _want["$_lname"]=1
    if [[ ! -v _have["$_lname"] ]]; then
      _rows+=("create"$'\t'"$_file"$'\t'"$_dname")
    elif [[ "${_have[$_lname]}" != "$_dsha" ]]; then
      _rows+=("check"$'\t'"$_file"$'\t'"$_dname"$'\t'"${_have[$_lname]}")
    fi
  done <<< "$_desired"
  for _lname in "${!_have[@]}"; do
    [[ "$_lname" == "$_prefix-"*.yml && ! -v _want["$_lname"] ]] || continue
    _rows+=("orphan"$'\t'"$_GH_GOVERNANCE_WORKFLOWS_DIR/$_lname"$'\t'"${_have[$_lname]}")
  done
  [[ ${#_rows[@]} -gt 0 ]] || return 0
  printf '%s\n' "${_rows[@]}" | LC_ALL=C sort -t $'\t' -k2,2
  return 0
}

_gh-governance-workflows-rewrite-level() {
  # Úroveň hlášení přepisu generovaného souboru: warning (rucni zasah do
  # workflow), když soubor v repu neodpovídá ani obsahu, který dávala šablona
  # na SHA ukazatele — lišil se, ačkoli ho konfigurace od ukazatele nezměnila
  # (porovnání blob SHA souboru s blob SHA renderu šablony na ukazateli).
  # Jinak info: bez ukazatele (adopce), šablona na ukazateli neexistovala,
  # nebo soubor odpovídá staré šabloně (legitimní změna conf.d). Vzor
  # CODEOWNERS (old-owners). Stdout: info | warning.
  # Použití: _gh-governance-workflows-rewrite-level <pointer_sha|''> <název> <key> <ghName> <sha souboru v repu>
  local _old="" _old_sha
  if _gh-governance-workflow-render-at-commit "$1" "$2" "$3" "$4" _old 2>/dev/null && [[ -n "$_old" ]]; then
    if _old_sha=$(_gh-governance-blob-sha "$_old") && [[ "$_old_sha" != "$5" ]]; then
      echo warning
      return 0
    fi
  fi
  echo info
}

_gh-governance-workflows-apply-orphan() {
  # Osiřelý soubor s prefixem (není v efektivním klíči): s hlavičkou smazat
  # (info), bez hlavičky jen přidat text warningu do nameref pole (soubor
  # uživatel převzal nebo založil vlastní). Soubor, který mezitím zmizel,
  # se přeskočí. rc 1 = selhání API.
  # Použití: _gh-governance-workflows-apply-orphan <repoPath> <branch> <soubor> <foreign_ref>
  declare -n _ao_foreign="$4"
  local _content="" _sha="" _rc
  _gh-governance-contents-read "$1" "$3" "$2" _content _sha
  _rc=$?
  [[ $_rc -ne 2 ]] || return 1
  [[ $_rc -eq 0 ]] || return 0
  if _gh-governance-workflows-has-header "$_content"; then
    _gh-governance-contents-delete "$1" "$3" "$2" "$_sha" \
      "governance: uklid workflow ${3##*/} (neni v klici workflows)" || return 1
    _gh-governance-report-add info "sprava workflow" "$1" \
      "odstraněn $3 (není v efektivním klíči workflows)"
  else
    _ao_foreign+=("$3 s rezervovaným prefixem nemá hlavičku GENEROVANO — není generovaný, governance ho nemění ani nemaže")
  fi
  return 0
}

_gh-governance-workflows-apply-desired() {
  # Chtěný soubor šablony <název>: chybí → založit (info); existuje s jiným SHA
  # → s hlavičkou přepsat (info aktualizován / warning rucni zasah dle
  # _gh-governance-workflows-rewrite-level), bez hlavičky jen text warningu do
  # nameref pole (konfigurace se neaplikuje). Soubor, který mezi výpisem
  # a čtením zmizel, se založí. rc 1 = selhání API/checkoutu.
  # Použití: _gh-governance-workflows-apply-desired <repoPath> <branch> <root> <key>
  #          <ghName> <pointer_sha|''> <create|check> <soubor> <název> <foreign_ref>
  declare -n _ad_foreign="${10}"
  local _content="" _sha="" _new="" _rc _level
  if [[ "$7" == check ]]; then
    _gh-governance-contents-read "$1" "$8" "$2" _content _sha
    _rc=$?
    [[ $_rc -ne 2 ]] || return 1
    if [[ $_rc -eq 0 ]] && ! _gh-governance-workflows-has-header "$_content"; then
      _ad_foreign+=("$8 nemá hlavičku GENEROVANO — konfigurace šablony $9 se neaplikuje; obnovení správy = soubor smazat")
      return 0
    fi
  fi
  _gh-governance-workflow-render "$3" "$9" "$4" "$5" _new || return 1
  _gh-governance-contents-write "$1" "$8" "$2" "$_new" "$_sha" \
    "governance: workflow $9 dle klice workflows" || return 1
  if [[ -z "$_sha" ]]; then
    _gh-governance-report-add info "sprava workflow" "$1" "založen $8 (šablona $9)"
    return 0
  fi
  _level=$(_gh-governance-workflows-rewrite-level "$6" "$9" "$4" "$5" "$_sha")
  if [[ "$_level" == warning ]]; then
    _gh-governance-report-add warning "rucni zasah do workflow" "$1" \
      "$8 se lišil bez změny šablony $9 ani klíče workflows — v GH změněno ručně, přepsán dle conf.d"
  else
    _gh-governance-report-add info "sprava workflow" "$1" \
      "$8 aktualizován dle conf.d (šablona $9)"
  fi
  return 0
}

_gh-governance-reconcile-workflows() {
  # Správa souborů workflow jednoho spravovaného nearchivovaného repa dle
  # efektivního klíče workflows (defs/defs.md, workflow repa; tabulka chování
  # návrhu). Repo s topicem migrace se přeskakuje celé (opakovaná migrace
  # zrcadlí Bitbucket, commit by kolidoval), repo bez výchozí větve také.
  # Bezstavově: 1 výpis adresáře na repo (404 = žádné soubory), obsah se čte
  # jen u lišících se a osiřelých souborů s prefixem; bez klíče a bez souborů
  # s prefixem = 1 GET, 0 zápisů. Pořadí akcí: smazání osiřelých → založení/
  # přepis → warningy souborů bez hlavičky. <pointer_sha> = ukazatel PŘED
  # tímto během (úroveň hlášení přepisu). rc != 0 jen při selhání
  # API/checkoutu → volající hlásí error a pokračuje dalším repem.
  # Použití: _gh-governance-reconcile-workflows <repoName> <branch> <projectKey>
  #          <topicsCSV> <pointer_sha|''>
  local _name="$1" _branch="$2" _key="$3" _topics="$4" _pointer_sha="$5"
  local _gh_name="${_name#"${GH_REPO_PREFIX}-${_key}-"}"
  local _repo_path="${GITHUB_ORG}/${_name}" _root _csv="" _source=""
  local _desired="" _listing="" _plan _rc _action _file _f3 _f4 _warn
  local -a _foreign=()
  _bb-migration-topic-present "$_topics" "$_BB_MIGRATION_TOPIC_MARKER" && return 0
  [[ -n "$_branch" ]] || return 0
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX GH_WORKFLOW_PREFIX GH_GOVERNANCE_REPO || return 1
  _root=$(_gh-governance-checkout-root) || return 1
  _gh-conf-workflows "$_key" "$_gh_name" _csv _source
  _gh-governance-workflows-desired "$_root" "$_key" "$_gh_name" "$_csv" _desired || return 1
  _listing=$(_gh-governance-contents-dir-list "$_repo_path" "$_GH_GOVERNANCE_WORKFLOWS_DIR" "$_branch")
  _rc=$?
  [[ $_rc -ne 2 ]] || return 1
  [[ $_rc -eq 0 ]] || _listing=""
  _plan=$(_gh-governance-workflows-plan "$_listing" "$_desired" "$GH_WORKFLOW_PREFIX")
  [[ -n "$_plan" ]] || return 0
  while IFS=$'\t' read -r _action _file _f3 _f4; do
    [[ "$_action" == orphan ]] || continue
    _gh-governance-workflows-apply-orphan "$_repo_path" "$_branch" "$_file" _foreign || return 1
  done <<< "$_plan"
  while IFS=$'\t' read -r _action _file _f3 _f4; do
    [[ "$_action" == create || "$_action" == check ]] || continue
    _gh-governance-workflows-apply-desired "$_repo_path" "$_branch" "$_root" "$_key" "$_gh_name" \
      "$_pointer_sha" "$_action" "$_file" "$_f3" _foreign || return 1
  done <<< "$_plan"
  for _warn in "${_foreign[@]}"; do
    _gh-governance-report-add warning "workflow mimo spravu" "$_repo_path" "$_warn"
  done
  return 0
}

_gh-governance-workflows-apply-note() {
  # Správa souborů workflow jednoho repa ve workflow životního cyklu
  # (new/unarchive/move/rename): položky reportu _gh-governance-reconcile-workflows
  # jako řádky poznámky `Workflows: <typ> – <detail>` do komentáře issue —
  # společné tělo _gh-governance-apply-note (lib/gh-governance-report.sh:
  # migrace → vynecháno, nula položek → beze změny, rc != 0 → zápis selhal;
  # rc vždy 0, report volajícího se obnoví).
  # Použití: _gh-governance-workflows-apply-note <repoName> <branch> <projectKey>
  #          <topicsCSV> <pointer_sha|''> <note_ref>
  _gh-governance-apply-note "Workflows" "$6" "$4" \
    _gh-governance-reconcile-workflows "$1" "$2" "$3" "$4" "$5"
}

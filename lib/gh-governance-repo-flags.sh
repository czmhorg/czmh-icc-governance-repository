#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Správa příznaků repa spravovaných rep podle klíčů allow_auto_merge
# a actions_create_pr (defs/defs.md: priznaky repa; docs/navrh/workflows-rep.md).
# Příznak repa = nastavení GitHub repa (ne soubor v repu): allow_auto_merge
# (GET/PATCH repos/{r}) a actions_create_pr (GET/PUT
# repos/{r}/actions/permissions/workflow; default_workflow_permissions se
# přebírá z GET — governance práva GITHUB_TOKEN nemění). Sémantika třístavová:
# klíč chybí = příznak se nečte ani nemění (repo bez klíčů = 0 API volání),
# true/false = cílový stav; čte se jen zadaný příznak, zapisuje jen při
# odchylce. Org politika je strop: repo-level actions_create_pr=true při
# vypnuté org politice končí HTTP 409 s definitivním textem → warning
# priznak repa urcuje organizace (náprava mimo governance). Rozhodovací logika
# je v čisté funkci (offline testy), zápisy jdou přes _gh-api-input-retry
# (lib/gh-repository-policy.sh). Záměrně mimo _gh-repository-policy-*: policy
# apply volá i migrace bb-migrate; repo v migraci se vynechává (dorovná
# repo-sync po bb-audit --finalize).
# Volají ji: denní reconcile (hlavní smyčka), workflow repo-sync
# (lib/gh-governance-repo-sync.sh — jeden projekt) a workflow životního cyklu
# repa (_gh-governance-repo-flags-apply-note — jedno repo, řádky komentáře issue).
# Závislosti: gh-common-defs.sh (_require_vars, GH_REPO_PREFIX, GITHUB_ORG,
# GITHUB_ORG_HOSTNAME, topic migrace, _bb-migration-topic-present),
# lib/gh-conf.sh (_gh-conf-repo-flag), lib/gh-repository-policy.sh
# (_gh-api-input-retry), lib/gh-governance-report.sh (_gh-governance-report-add,
# _gh-governance-apply-note), lib/gh-governance-state.sh
# (_gh-governance-conf-field-unchanged).
[[ -n "${_GH_GOVERNANCE_REPO_FLAGS_LOADED:-}" ]] && \
  declare -F _gh-governance-reconcile-repo-flags >/dev/null && return 0
_GH_GOVERNANCE_REPO_FLAGS_LOADED=1

# Text definitivní chyby zápisu actions_create_pr=true při vypnuté org politice
# (HTTP 409 Conflict; ověřeno 2026-11-08, docs/github/actions-create-pr-permission.md):
# _gh-api-input-retry ho neopakuje a vrací 2.
_GH_GOVERNANCE_REPO_FLAGS_ORG_TEXT='does not allow GitHub Actions to create or approve pull requests'

_gh-governance-repo-flags-read() {
  # Přečte aktuální hodnoty zadaných příznaků repa: <need_auto>=1 → GET
  # repos/{r} (.allow_auto_merge), <need_pr>=1 → GET
  # repos/{r}/actions/permissions/workflow (default_workflow_permissions pro
  # pozdější PUT a can_approve_pull_request_reviews). Nečtené hodnoty zůstanou
  # prázdné. rc 1 = selhání GET (stderr gh projde dál).
  # Použití: _gh-governance-repo-flags-read <repoPath> <need_auto 0|1> <need_pr 0|1>
  #          <auto_ref> <pr_ref> <perm_ref>
  declare -n _rfr_auto="$4" _rfr_pr="$5" _rfr_perm="$6"
  local _row
  _rfr_auto=""; _rfr_pr=""; _rfr_perm=""
  if [[ "$2" == 1 ]]; then
    _rfr_auto=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$1" --jq '.allow_auto_merge') || return 1
  fi
  if [[ "$3" == 1 ]]; then
    _row=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$1/actions/permissions/workflow" \
      --jq '[.default_workflow_permissions, .can_approve_pull_request_reviews] | @tsv') || return 1
    IFS=$'\t' read -r _rfr_perm _rfr_pr <<< "$_row"
  fi
  return 0
}

_gh-governance-repo-flags-plan() {
  # Rozhodne zápisy příznaků repa. Čistá funkce; vypíše po řádcích
  #   set\t<příznak>\t<stará hodnota>\t<nová hodnota>
  # za každý zadaný příznak (neprázdná chtěná hodnota), jehož aktuální hodnota
  # se liší; shoda nebo nezadaný příznak = nic. Pořadí allow_auto_merge,
  # actions_create_pr (jako _GH_CONF_REPO_FLAG_FIELDS).
  # Použití: _gh-governance-repo-flags-plan <auto_want> <auto_have> <pr_want> <pr_have>
  [[ -z "$1" || "$1" == "$2" ]] || printf 'set\tallow_auto_merge\t%s\t%s\n' "$2" "$1"
  [[ -z "$3" || "$3" == "$4" ]] || printf 'set\tactions_create_pr\t%s\t%s\n' "$4" "$3"
  return 0
}

_gh-governance-repo-flags-write-auto() {
  # Zapíše allow_auto_merge repa (PATCH repos/{r}) s retry na přechodné chyby.
  # Použití: _gh-governance-repo-flags-write-auto <repoPath> <true|false>
  _gh-api-input-retry "repos/$1" PATCH "{\"allow_auto_merge\":$2}" \
    "příznaku allow_auto_merge repa '$1'"
}

_gh-governance-repo-flags-write-create-pr() {
  # Zapíše actions_create_pr repa (PUT repos/{r}/actions/permissions/workflow);
  # default_workflow_permissions posílá beze změny (hodnota z GET — tělo PUT
  # ho vyžaduje). rc 2 = odmítnuto politikou org/enterprise (text
  # _GH_GOVERNANCE_REPO_FLAGS_ORG_TEXT, bez opakování), rc 1 = jiné selhání.
  # Použití: _gh-governance-repo-flags-write-create-pr <repoPath> <default_workflow_permissions> <true|false>
  _gh-api-input-retry "repos/$1/actions/permissions/workflow" PUT \
    "{\"default_workflow_permissions\":\"$2\",\"can_approve_pull_request_reviews\":$3}" \
    "příznaku actions_create_pr repa '$1'" "$_GH_GOVERNANCE_REPO_FLAGS_ORG_TEXT"
}

_gh-governance-reconcile-repo-flags() {
  # Správa příznaků jednoho spravovaného nearchivovaného repa dle efektivních
  # klíčů allow_auto_merge a actions_create_pr (defs/defs.md, priznaky repa).
  # Repo s topicem migrace se přeskakuje celé; bez obou klíčů 0 API volání;
  # jinak 1 GET za zadaný příznak a PATCH/PUT jen při odchylce. Položky
  # reportu: sprava priznaku repa (info, `<příznak>: <stará> → <nová>`),
  # rucni zasah do priznaku repa (warning — hodnota se lišila, ačkoli klíč od
  # SHA ukazatele beze změny: _gh-governance-conf-field-unchanged), priznak
  # repa urcuje organizace (warning — zápis odmítla org politika, HTTP 409).
  # <pointer_sha> = ukazatel PŘED tímto během (adopce = '' → info). rc != 0 jen
  # při selhání API → volající hlásí error a pokračuje dalším repem.
  # Použití: _gh-governance-reconcile-repo-flags <repoName> <projectKey>
  #          <topicsCSV> <pointer_sha|''>
  local _name="$1" _key="$2" _topics="$3" _pointer_sha="$4"
  local _gh_name="${_name#"${GH_REPO_PREFIX}-${_key}-"}"
  local _repo_path="${GITHUB_ORG}/${_name}" _src
  local _auto_want="" _pr_want="" _need_auto=0 _need_pr=0
  local _auto_have="" _pr_have="" _perm="" _plan _action _flag _old _new _rc
  _bb-migration-topic-present "$_topics" "$_BB_MIGRATION_TOPIC_MARKER" && return 0
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX || return 1
  _gh-conf-repo-flag "$_key" "$_gh_name" allow_auto_merge _auto_want _src || return 1
  _gh-conf-repo-flag "$_key" "$_gh_name" actions_create_pr _pr_want _src || return 1
  [[ -z "$_auto_want" ]] || _need_auto=1
  [[ -z "$_pr_want" ]] || _need_pr=1
  [[ $_need_auto -eq 1 || $_need_pr -eq 1 ]] || return 0
  _gh-governance-repo-flags-read "$_repo_path" "$_need_auto" "$_need_pr" \
    _auto_have _pr_have _perm || return 1
  _plan=$(_gh-governance-repo-flags-plan "$_auto_want" "$_auto_have" "$_pr_want" "$_pr_have")
  [[ -n "$_plan" ]] || return 0
  while IFS=$'\t' read -r _action _flag _old _new; do
    [[ "$_action" == set ]] || continue
    _rc=0
    case "$_flag" in
      allow_auto_merge)
        _gh-governance-repo-flags-write-auto "$_repo_path" "$_new" || _rc=$? ;;
      actions_create_pr)
        _gh-governance-repo-flags-write-create-pr "$_repo_path" "$_perm" "$_new" || _rc=$? ;;
    esac
    case "$_rc" in
      0)
        if _gh-governance-conf-field-unchanged "$_pointer_sha" "$_key" "$_gh_name" "$_flag" "$_new"; then
          _gh-governance-report-add warning "rucni zasah do priznaku repa" "$_repo_path" \
            "$_flag: $_old → $_new — v GH změněno ručně, vráceno dle conf.d"
        else
          _gh-governance-report-add info "sprava priznaku repa" "$_repo_path" \
            "$_flag: $_old → $_new"
        fi ;;
      2)
        _gh-governance-report-add warning "priznak repa urcuje organizace" "$_repo_path" \
          "$_flag=$_new nelze nastavit (politika organizace/enterprise; v GH zůstává $_old)" ;;
      *) return 1 ;;
    esac
  done <<< "$_plan"
  return 0
}

_gh-governance-repo-flags-apply-note() {
  # Správa příznaků jednoho repa ve workflow životního cyklu (new/unarchive/
  # move/rename): položky reportu _gh-governance-reconcile-repo-flags jako
  # řádky poznámky `Příznaky repa: <typ> – <detail>` do komentáře issue —
  # společné tělo _gh-governance-apply-note (lib/gh-governance-report.sh:
  # migrace → vynecháno, nula položek → beze změny, rc != 0 → zápis selhal;
  # rc vždy 0, report volajícího se obnoví).
  # Použití: _gh-governance-repo-flags-apply-note <repoName> <projectKey>
  #          <topicsCSV> <pointer_sha|''> <note_ref>
  _gh-governance-apply-note "Příznaky repa" "$5" "$3" \
    _gh-governance-reconcile-repo-flags "$1" "$2" "$3" "$4"
}

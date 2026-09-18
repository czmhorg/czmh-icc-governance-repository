#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Jistota doručení, vrstvy 2 a 3 (docs/navrh/gh-pr-funkce.md, kapitola
# *Jistota doručení*; docs/plans/plan-gh-pr-revize.md, etapa E): denní
# reconcile hlásí projekt bez pr_reviewers_team (vrstva 2) a u otevřených PR
# spravovaných rep bez žádosti o review žádá tým projektu, resp. hlásí PR,
# u kterých žádost zanikla po review (vrstva 3). Rozhodovací logika je
# v čisté funkci (offline testy); výčet PR jde jedním GraphQL search dotazem
# (docs/github/graphql-search-review-requests.md), žádost přes REST
# requested_reviewers (docs/github/requested-reviewers-rest.md) — stejný
# helper má i klient (gh-functions-user.sh), gov repo klienta nenasazuje.
# Závislosti: gh-common-defs.sh (_require_vars, GITHUB_ORG*), lib/gh-conf.sh
# (_gh-conf-effective, _GH_CONF), lib/gh-governance-report.sh.
[[ -n "${_GH_GOVERNANCE_PR_REVIEW_LOADED:-}" ]] && \
  declare -F _gh-governance-reconcile-pr-review >/dev/null && return 0
_GH_GOVERNANCE_PR_REVIEW_LOADED=1

# Strop výsledků search API (docs/github/search-api-limit-1000.md).
_GH_GOVERNANCE_PR_REVIEW_SEARCH_MAX=1000

_gh-governance-pr-review-project-check() {
  # Vrstva 2: projekt bez pr_reviewers_team → warning v reportu (žádosti
  # o review nevznikají automaticky ani z CODEOWNERS, ani z gh-pr, ani
  # z vrstvy 3). Nezadaný klíč je rozhodnutí správce projektu — položka
  # zůstává v každém denním reportu, dokud klíč chybí.
  # Použití: _gh-governance-pr-review-project-check <projectKey>
  local _team=""
  _gh-conf-effective "$1" "" pr_reviewers_team _team
  [[ -n "$_team" ]] && return 0
  _gh-governance-report-add warning "projekt bez pr_reviewers_team" "-" \
    "projekt '$1': žádosti o review nevznikají automaticky (CODEOWNERS, gh-pr ani denní kontrola tým nežádají)"
}

_gh-governance-pr-review-list() {
  # Vypíše otevřené PR organizace mimo drafty a archivovaná repa jedním
  # GraphQL search dotazem (stránkování $endCursor). Řádky TSV:
  #   count\t<issueCount>                            (první řádek každé stránky)
  #   pr\t<repoName>\t<číslo>\t<reviewDecision|->\t<žádostí>\t<review>
  # reviewDecision: APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | - (repo
  # bez pravidla povinného review vrací null). totalCount bez first/last je
  # v GraphQL přípustný (ověřeno živě 2026-09-18). rc != 0 = dotaz selhal.
  # Použití: _out=$(_gh-governance-pr-review-list) || return 1
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME || return 1
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api graphql --paginate \
    -f q="org:${GITHUB_ORG} is:pr is:open draft:false archived:false" \
    -f query='query($q:String!,$endCursor:String){
      search(query:$q, type: ISSUE, first: 100, after:$endCursor){
        issueCount
        pageInfo{ hasNextPage endCursor }
        nodes{ ... on PullRequest{
          number
          repository{ name }
          reviewDecision
          reviewRequests{ totalCount }
          reviews{ totalCount } } } } }' \
    --jq '"count\t\(.data.search.issueCount)",
          (.data.search.nodes[]
           | ["pr", .repository.name, .number, (.reviewDecision // "-"),
              .reviewRequests.totalCount, .reviews.totalCount] | @tsv)'
}

_gh-governance-pr-review-plan() {
  # Rozhodne akci nad jedním PR dle tabulky vrstvy 3 návrhu. Čistá funkce,
  # vypíše jedno slovo:
  #   request – bez žádosti, bez jakéhokoli review, projekt má tým → bot
  #             požádá pr_reviewers_team,
  #   info    – bez žádosti, ale s review (komentář bez verdiktu, výhrady)
  #             → jen hlášení; na tahu je autor,
  #   skip    – žádost existuje, PR je schválen, nebo projekt tým nemá
  #             (to hlásí vrstva 2 per projekt, ne per PR).
  # Použití: _gh-governance-pr-review-plan <reviewDecision> <žádostí> <review> <tým|''>
  local _decision="$1" _requests="$2" _reviews="$3" _team="$4"
  if [[ "$_requests" != 0 || "$_decision" == APPROVED ]]; then
    echo skip
  elif [[ "$_reviews" != 0 ]]; then
    echo info
  elif [[ -n "$_team" ]]; then
    echo request
  else
    echo skip
  fi
}

_gh-governance-pr-review-request() {
  # Požádá tým o review přes REST requested_reviewers (round robin proběhne
  # synchronně, výsledek je v odpovědi POST). Vypíše výsledný seznam
  # požádaných (loginy, týmy jako "tým <slug>"); rc != 0 = API odmítlo
  # (typicky 422: tým bez přístupu k repu), poslední řádek stderr nese důvod.
  # Použití: _req=$(_gh-governance-pr-review-request <org/repo> <číslo> <slug>) || return 1
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh api -X POST \
    "repos/$1/pulls/$2/requested_reviewers" -f "team_reviewers[]=$3" \
    --jq '[(.requested_reviewers[] | .login), (.requested_teams[] | "tým " + .slug)] | join(", ")'
}

_gh-governance-reconcile-pr-review() {
  # Vrstva 3 pro celou organizaci: projde otevřené PR (jeden search dotaz),
  # PR mimo mapu spravovaných rep (gov repo, archivovaná, v migraci, cizí)
  # přeskočí, u ostatních rozhodne dle _gh-governance-pr-review-plan a tým
  # bere z efektivní konfigurace repa (nastavení repa přepisuje projekt,
  # none = bez týmu). Selhání jedné žádosti běh nezastaví (warning).
  # <map_ref> = asoc. pole repoName → "key\tghName" naplněné hlavní smyčkou
  # reconcile. rc != 0 jen při selhání search dotazu.
  # Použití: _gh-governance-reconcile-pr-review <map_ref>
  # Lokály s prefixem _prr_ — nameref na pole volajícího nesmí kolidovat.
  declare -n _prr_map="$1"
  local _prr_out _prr_kind _prr_name _prr_num _prr_decision _prr_requests _prr_reviews
  local _prr_count="" _prr_key _prr_gh_name _prr_team _prr_action _prr_repo _prr_req _prr_err
  _prr_out=$(_gh-governance-pr-review-list) || return 1
  while IFS=$'\t' read -r _prr_kind _prr_name _prr_num _prr_decision _prr_requests _prr_reviews; do
    case "$_prr_kind" in
      count)
        [[ -n "$_prr_count" ]] && continue
        _prr_count="$_prr_name"
        if (( _prr_count > _GH_GOVERNANCE_PR_REVIEW_SEARCH_MAX )); then
          _gh-governance-report-add warning "vypis pr orezan" "$GITHUB_ORG" \
            "otevřených PR: ${_prr_count} > ${_GH_GOVERNANCE_PR_REVIEW_SEARCH_MAX} (strop search API) — část PR bez žádosti o review se nekontroluje"
        fi
        continue ;;
      pr) ;;
      *) continue ;;
    esac
    [[ -n "${_prr_map[$_prr_name]:-}" ]] || continue
    IFS=$'\t' read -r _prr_key _prr_gh_name <<< "${_prr_map[$_prr_name]}"
    _prr_team=""
    _gh-conf-effective "$_prr_key" "$_prr_gh_name" pr_reviewers_team _prr_team
    _prr_action=$(_gh-governance-pr-review-plan "$_prr_decision" "$_prr_requests" \
      "$_prr_reviews" "$_prr_team")
    _prr_repo="${GITHUB_ORG}/${_prr_name}"
    case "$_prr_action" in
      request)
        _prr_err=$(mktemp) || return 1
        if _prr_req=$(_gh-governance-pr-review-request "$_prr_repo" "$_prr_num" \
            "$_prr_team" 2>"$_prr_err"); then
          _gh-governance-report-add info "pr bez zadosti o review" "$_prr_repo" \
            "PR #${_prr_num} bez žádosti o review — požádán tým ${_prr_team} (požádáni: ${_prr_req:--})"
        else
          _gh-governance-report-add warning "zadost o review selhala" "$_prr_repo" \
            "PR #${_prr_num} bez žádosti o review, žádost na tým ${_prr_team} odmítnuta: $(tail -n 1 "$_prr_err")"
        fi
        rm -f "$_prr_err" ;;
      info)
        _gh-governance-report-add info "pr s review bez zadosti" "$_prr_repo" \
          "PR #${_prr_num}: review bez schválení (${_prr_decision}), žádost o review zanikla — na tahu je autor" ;;
    esac
  done <<< "$_prr_out"
  return 0
}

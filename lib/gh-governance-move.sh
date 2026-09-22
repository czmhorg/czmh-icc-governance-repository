#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Přesun repa mezi GH projekty (move-repository, split-project; návrh
# docs/implementovano/navrh/rozdeleni-projektu.md) a přejmenování repa uvnitř
# projektu (rename-repository; návrh docs/implementovano/navrh/gh-rename.md) jedním
# orchestrátorem nad dvojicemi (srcKey, srcName) → (dstKey, dstName): řízené
# přejmenování + přepnutí topicu ghp-* (jen přesun) + aplikace efektivní
# politiky cílové dvojice + zápis CODEOWNERS pod novým jménem + přesun
# ukazatele state/ a řádku completion manifestu; volitelné zrušení GitHub
# redirectu starého jména dočasným repem
# (ověřené chování: docs/github/rename-redirect-obsazeni-jmena.md).
# Závislosti: gh-common-defs.sh, lib/gh-conf.sh, lib/gh-repository-policy.sh,
# lib/gh-governance-state.sh (_gh-governance-*-to-remove-between),
# lib/gh-governance-manifest.sh, lib/gh-governance-repo-ops.sh,
# lib/gh-governance-reconcile.sh (GH_GOVERNANCE_CAPACITY_MAX),
# lib/gh-governance-codeowners.sh (_gh-governance-codeowners-apply-note –
# zápis CODEOWNERS pod novým jménem po politice cílové dvojice).
[[ -n "${_GH_GOVERNANCE_MOVE_LOADED:-}" ]] && \
  declare -F _gh-governance-move-run >/dev/null && return 0
_GH_GOVERNANCE_MOVE_LOADED=1

# Formát topicu GitHubu (sdílený tvar s _bb-audit-topic-swap v bb-migrate.sh).
_GH_GOVERNANCE_MOVE_TOPIC_REGEX='^[a-z0-9][a-z0-9-]{0,49}$'

_gh-governance-move-topic-swap() {
  # Atomicky přepne topic ghp-<srcKey> na ghp-<dstKey> jedním PUT
  # repos/{path}/topics (ostatní topicy beze změny). Vstupem je CSV topiců
  # z metadat repa (_gh-governance-repo-info), ne další API čtení.
  # Použití: _gh-governance-move-topic-swap <repo_path> <topicsCSV> <srcKey> <dstKey>
  local _repo_path="$1" _topics="$2" _src="$3" _dst="$4" _item _json=""
  local _from="${GH_PROJECT_TOPIC_PREFIX}${_src}" _to="${GH_PROJECT_TOPIC_PREFIX}${_dst}"
  local -a _names=()
  IFS=',' read -ra _names <<< "$_topics"
  for _item in "${_names[@]}"; do
    [[ -z "$_item" ]] && continue
    [[ "$_item" == "$_from" ]] && _item="$_to"
    if ! _gh-match "$_item" "$_GH_GOVERNANCE_MOVE_TOPIC_REGEX"; then
      echo "Chyba: Topic '$_item' repa '$_repo_path' nemá platný formát – PUT topics by ho zahodil." >&2
      return 1
    fi
    _json+="${_json:+,}\"$_item\""
  done
  _gh-api-input-retry "repos/$_repo_path/topics" PUT "{\"names\":[$_json]}" \
    "přepnutí topicu '$_from' → '$_to' repa '$_repo_path'"
}

_gh-governance-move-manifest-archived() {
  # Naplní nameref původním archived flagem repa z completion manifestu
  # (true/false; prázdné = řádek chybí). Řádek se přepisuje až posledním
  # krokem přesunu, takže i uprostřed přerušené sekvence nese původní stav –
  # zdroj pravdy pro resume (návrh, Idempotence a přerušený běh).
  # Použití: local _a; _gh-governance-move-manifest-archived <projectKey> <ghName> _a
  local _key="$1" _name="$2" _file
  declare -n _archived_ref="$3"
  _archived_ref=""
  _file=$(_gh-governance-manifest-file) || return 1
  [[ -f "$_file" ]] || return 0
  _archived_ref=$(awk -F'\t' -v k="$_key" -v n="$_name" \
    '$1==n && $2==k {print $3; exit}' "$_file")
  return 0
}

_gh-governance-move-capacity-ok() {
  # Ověří kapacitu cílového projektu v podmnožině daného archived flagu
  # (axiom Kapacita projektu): počet řádků completion manifestu musí být
  # < GH_GOVERNANCE_CAPACITY_MAX, jinak by přesun axiom porušil.
  # rc 0 = OK, 1 = kapacita vyčerpána (s hláškou), 2 = chyba.
  # Použití: _gh-governance-move-capacity-ok <dstKey> <true|false>
  local _dst="$1" _archived="$2" _file _count=0
  _file=$(_gh-governance-manifest-file) || return 2
  if [[ -f "$_file" ]]; then
    _count=$(awk -F'\t' -v k="$_dst" -v a="$_archived" \
      '$2==k && $3==a {n++} END {print n+0}' "$_file")
  fi
  if (( _count >= GH_GOVERNANCE_CAPACITY_MAX )); then
    echo "Chyba: Projekt '$_dst' má v podmnožině archived=$_archived už $_count rep – přesun by porušil axiom Kapacita projektu (max $GH_GOVERNANCE_CAPACITY_MAX)." >&2
    return 1
  fi
  return 0
}

_gh-governance-move-name-info() {
  # Metadata JMÉNA (ne repa): _gh-governance-repo-info, ale rename redirect
  # se nepovažuje za existenci – GET repos/{path} redirect následuje a vrátil
  # by cizí (typicky právě přesunuté) repo. Vrací-li lookup jiné full_name
  # než dotazovanou cestu, jméno je volné (exists=false) a skutečný cíl
  # redirectu zůstává v klíči redirect_to.
  # Použití: local -A _i=(); _gh-governance-move-name-info <repo_path> _i
  local _repo_path="$1"
  declare -n _mvn_info_ref="$2"
  _gh-governance-repo-info "$_repo_path" _mvn_info_ref || return 1
  _mvn_info_ref[redirect_to]=""
  if [[ "${_mvn_info_ref[exists]}" == true \
      && "${_mvn_info_ref[full_name],,}" != "${_repo_path,,}" ]]; then
    _mvn_info_ref[redirect_to]="${_mvn_info_ref[full_name]}"
    _mvn_info_ref[exists]=false
  fi
  return 0
}

_gh-governance-move-detect() {
  # Rozpozná stav operace (srcKey, srcName) → (dstKey, dstName) – přesun
  # (mění se klíč) nebo přejmenování (mění se jméno) – a naplní namerefy: stav
  # (fresh|half|done|missing|taken|conflict) a metadata existujícího repa
  # (_gh-governance-repo-info). fresh = repo starého jména je spravovaným
  # repem zdrojového projektu; half = staré jméno zaniklo, repo nového jména
  # nese ještě topic ghp-<srcKey> (přerušený přesun – dokončit od přepnutí
  # topicu; u přejmenování, src == dst, nevzniká – topic se nemění a stav je
  # rovnou done); done = repo nového jména s topicem ghp-<dstKey> (zbývá
  # konvergence a přesun ukazatele); taken = fresh, ale nové jméno je
  # obsazené; missing = neexistuje ani jedno jméno; conflict = existující
  # repo neodpovídá žádnému očekávanému stavu. rc 1 jen provozní chyba.
  # Použití: local _s; local -A _i=(); _gh-governance-move-detect <srcKey> <srcName> <dstKey> <dstName> _s _i
  local _src="$1" _src_name="$2" _dst="$3" _dst_name="$4" _old_name _new_name _ghp_count _ghp
  # Jména namerefů záměrně unikátní (_mvd_*): hodnota namerefu se předává dál
  # do _gh-governance-repo-info a shoda se jménem jejího parametru (_info_ref)
  # by byla cyklická reference.
  declare -n _mvd_state_ref="$5" _mvd_info_ref="$6"
  local -A _mvd_new_info=()
  _mvd_state_ref=""
  _old_name=$(_gh-governance-repo-name "$_src" "$_src_name") || return 1
  _new_name=$(_gh-governance-repo-name "$_dst" "$_dst_name") || return 1
  # Lookup jmen přes name-info: rename redirect starého jména na přesunuté
  # repo se nesmí počítat jako existence (jinak by resume nikdy nenastal).
  _gh-governance-move-name-info "${GITHUB_ORG}/${_old_name}" _mvd_info_ref || return 1
  if [[ "${_mvd_info_ref[exists]}" == true ]]; then
    if ! _gh-governance-managed-verify "${GITHUB_ORG}/${_old_name}" "$_src" \
        "${_mvd_info_ref[topics]}"; then
      _mvd_state_ref=conflict
      return 0
    fi
    _gh-governance-move-name-info "${GITHUB_ORG}/${_new_name}" _mvd_new_info || return 1
    if [[ "${_mvd_new_info[exists]}" == true ]]; then
      echo "Chyba: Nové jméno '${GITHUB_ORG}/${_new_name}' je už obsazené." >&2
      _mvd_state_ref=taken
      return 0
    fi
    _mvd_state_ref=fresh
    return 0
  fi
  _gh-governance-move-name-info "${GITHUB_ORG}/${_new_name}" _mvd_info_ref || return 1
  if [[ "${_mvd_info_ref[exists]}" != true ]]; then
    echo "Chyba: Repo '${GITHUB_ORG}/${_old_name}' ani '${GITHUB_ORG}/${_new_name}' neexistuje." >&2
    _mvd_state_ref=missing
    return 0
  fi
  _gh-governance-ghp-topics "${_mvd_info_ref[topics]}" _ghp_count _ghp
  if [[ $_ghp_count -eq 1 && "$_ghp" == "${GH_PROJECT_TOPIC_PREFIX}${_dst}" ]]; then
    _mvd_state_ref=done
  elif [[ "$_src" != "$_dst" && $_ghp_count -eq 1 \
      && "$_ghp" == "${GH_PROJECT_TOPIC_PREFIX}${_src}" ]]; then
    _mvd_state_ref=half
  else
    echo "Chyba: Repo '${GITHUB_ORG}/${_new_name}' má neočekávané topicy ('${_mvd_info_ref[topics]}') – stav operace nelze určit." >&2
    _mvd_state_ref=conflict
  fi
  return 0
}

_gh-governance-move-apply-policy() {
  # Aplikuje na přesunuté/přejmenované repo efektivní konfiguraci cílové
  # dvojice (dstKey, dstName) – včetně případného nastavení repa v cíli –
  # a odebere pozůstatky zdrojové dvojice dle diffu ukazatele: {efektivní týmy
  # (srcKey, srcName) na SHA ukazatele state/<staréJméno>} − {efektivní týmy
  # (dstKey, dstName) na RUN_SHA}, totéž Jenkins login (jen dle klíčů – login
  # je na doméně projektu). U přejmenování (src == dst) je diff neprázdný jen
  # z rozdílu nastavení repa (staré jméno mělo, nové nemá). Kostra dle
  # _gh-governance-apply-policy-and-state; ukazatel NEzapisuje (dělá
  # závěrečný krok _gh-governance-move-run). Adopce (repo bez ukazatele):
  # nic se neodebírá.
  # Použití: _gh-governance-move-apply-policy <repo_path> <staréRepoName> <branch> <srcKey> <srcName> <dstKey> <dstName> <removed_array_name> <adopted_flag_name> <removed_login_name>
  local _repo_path="$1" _old_name="$2" _branch="$3" _src="$4" _src_name="$5"
  local _dst="$6" _dst_name="$7"
  declare -n _removed_ref="$8" _adopted_ref="$9" _removed_login_ref="${10}"
  local _pointer_sha="" _run_sha _rm_out _rm_login=""
  local -a _rm_teams=()
  _removed_ref=()
  _adopted_ref=false
  _removed_login_ref=""
  _run_sha=$(_gh-governance-run-sha) || return 1
  _pointer_sha=$(_gh-governance-state-read "$_old_name")
  case $? in
    0) ;;
    1) _adopted_ref=true ;;
    *) return 1 ;;
  esac
  _gh-repository-policy-apply "$_repo_path" "$_branch" "$_dst" "$_dst_name" || return 1
  if [[ "$_adopted_ref" == false ]]; then
    # Na rozdíl od jednoklíčového diffu se odebírá i při pointer == RUN_SHA –
    # týmy obou stran se liší na téže verzi konfigurace.
    _gh-governance-teams-to-remove-between "$_src" "$_pointer_sha" "$_src_name" \
      "$_dst" "$_run_sha" "$_dst_name" _rm_teams || return 1
    _rm_out=$(mktemp) || return 1
    if ! _gh-governance-teams-remove "$_repo_path" "$_dst" "$_dst_name" _rm_teams > "$_rm_out"; then
      rm -f "$_rm_out"
      return 1
    fi
    mapfile -t _removed_ref < "$_rm_out"
    rm -f "$_rm_out"
    _gh-governance-jenkins-to-remove-between "$_src" "$_pointer_sha" "$_dst" "$_run_sha" _rm_login || return 1
    if [[ -n "$_rm_login" ]]; then
      _gh-jenkins-collaborator-remove "$_repo_path" "$_dst" "$_rm_login" || return 1
      _removed_login_ref="$_rm_login"
    fi
  fi
  return 0
}


_gh-governance-move-warnings() {
  # Naplní nameref asoc. pole upozorněními na ruční odchylky repa od efektivní
  # konfigurace v cílovém projektu (terminologie reconcile reportu; přesun je
  # nemění, jen hlásí): teams / rulesets / collaborators – víceřádkové
  # seznamy. U archivovaného repa volat před zpětnou archivací.
  # Použití: local -A _w=(); _gh-governance-move-warnings <repo_path> <dstKey> <ghName> _w
  local _repo_path="$1" _dst="$2" _gh_name="$3" _expected _live _team _extra
  declare -n _warn_ref="$4"
  local -A _policy=()
  _warn_ref=([teams]="" [rulesets]="" [collaborators]="")
  _expected=$(_gh-repository-policy-expected-teams "$_dst" "$_gh_name") || return 1
  while IFS=$'\t' read -r _team _extra; do
    [[ -n "$_team" ]] && _policy["$_team"]=1
  done <<< "$_expected"
  _live=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/teams" \
    --paginate --jq '.[].slug') || return 1
  while IFS= read -r _team; do
    [[ -n "$_team" ]] || continue
    [[ "$_team" == "$GH_SECURITY_MANAGERS_TEAM" ]] && continue
    [[ -v _policy["$_team"] ]] && continue
    _warn_ref[teams]+="${_warn_ref[teams]:+$'\n'}$_team"
  done <<< "$_live"
  _live=$(_gh-ruleset-list "$_repo_path") || return 1
  while IFS=$'\t' read -r _extra _team; do
    [[ -n "$_team" ]] || continue
    [[ "$_team" == "${GH_RULESET_PREFIX}-"* ]] && continue
    _warn_ref[rulesets]+="${_warn_ref[rulesets]:+$'\n'}$_team"
  done <<< "$_live"
  _live=$(_gh-repository-policy-extra-collaborators-list "$_repo_path" "$_dst" "$_gh_name") || return 1
  while IFS=$'\t' read -r _team _extra; do
    [[ -n "$_team" ]] || continue
    _warn_ref[collaborators]+="${_warn_ref[collaborators]:+$'\n'}$_team ($_extra)"
  done <<< "$_live"
  return 0
}

_gh-governance-move-break-redirect() {
  # Zruší GitHub redirect starého jména: obsadí ho prázdným dočasným repem
  # (bez commitu, bez topicu) a ihned podá žádost o jeho smazání mechanikou
  # gh-delete (issue v GH_DELETE_HELPER_REPO + track-delete issue v gov
  # repu). Smazání je asynchronní (černá skříňka delete-repository);
  # zaseknutou žádost zviditelní denní reconcile (divoké repo + zaseknuté
  # smazání). Selhání track-delete issue je jen varování (pojistkou je noční
  # reconcile sweep). Nameref naplní URL delete issue (pro komentář).
  # Nameref result: broken (redirect zrušen teď), absent (redirect už
  # neexistoval – nic k rušení), occupied (staré jméno nese skutečné repo –
  # dočasné z minulého běhu, nebo cizí; nic se nezakládá).
  # Použití: local _u _r; _gh-governance-move-break-redirect <staréRepoName> <novéRepoName> _u _r
  local _old_name="$1" _new_name="$2" _repo_path _issue_url _track_url
  declare -n _delete_issue_ref="$3" _redirect_result_ref="$4"
  local -A _old_info=()
  _delete_issue_ref=""
  _redirect_result_ref=""
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_DELETE_HELPER_REPO GH_GOVERNANCE_REPO GH_NEW_REPO_VISIBILITY || return 1
  _repo_path="${GITHUB_ORG}/${_old_name}"
  # Idempotence (opakovaný běh): GET repos/{staréJméno} následuje rename
  # redirect – full_name rozliší skutečné repo (obsazeno) od redirectu
  # (je co rušit) a 404 od už zrušeného redirectu (nic k rušení).
  _gh-governance-move-name-info "$_repo_path" _old_info || return 1
  if [[ "${_old_info[exists]}" == true ]]; then
    echo "Zrušení redirectu přeskočeno: staré jméno '$_repo_path' je už obsazené (dočasné repo z minulého běhu, nebo cizí repo)." >&2
    _redirect_result_ref=occupied
    return 0
  fi
  if [[ -z "${_old_info[redirect_to]}" ]]; then
    echo "Redirect starého jména '$_repo_path' už neexistuje – zrušení není potřeba."
    _redirect_result_ref=absent
    return 0
  fi
  _redirect_result_ref=broken
  _gh-api-input-retry "orgs/$GITHUB_ORG/repos" POST \
    "{\"name\":\"$_old_name\",\"visibility\":\"$GH_NEW_REPO_VISIBILITY\",\"auto_init\":false,\"description\":\"Docasne repo - rusi redirect po presunu na $_new_name. Bude smazano.\"}" \
    "založení dočasného repa '$_repo_path' (zrušení redirectu)" || return 1
  if ! _issue_url=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue create \
      --repo "$GH_DELETE_HELPER_REPO" \
      --title "Delete repository: $_repo_path" \
      --body "$_repo_path"); then
    echo "Chyba: Nepodařilo se podat žádost o smazání dočasného repa '$_repo_path' – repo zůstává (denní kontrola ho ohlásí jako divoké)." >&2
    return 1
  fi
  _delete_issue_ref="$_issue_url"
  if _track_url=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue create \
      --repo "${GITHUB_ORG}/${GH_GOVERNANCE_REPO}" \
      --label track-delete \
      --title "track-delete: $_repo_path" \
      --body "$(printf 'repo_path=%s\ndelete_issue=%s' "$_repo_path" "$_issue_url")" \
      2>/dev/null); then
    echo "Zrušení redirectu: dočasné repo '$_repo_path' založeno, žádost o smazání podána ($_issue_url, tracking $_track_url)."
  else
    echo "Varování: Track-delete issue pro dočasné repo '$_repo_path' se nepodařilo založit – úklid dořeší noční reconcile." >&2
  fi
  return 0
}

_gh-governance-move-validate() {
  # Validace před první mutací (návrh, Validace) pro dvojice (srcKey, srcName)
  # → (dstKey, dstName): projekty existují, mění se právě jedna složka
  # (obě shodné = „nic se nemění“, obě různé = nepodporováno; obojí provozní
  # chyba bez typu – parsery to vylučují typy same_project/same_name), formát
  # a délka nového jména, stav repa (detect), volnost nového jména a kapacita
  # cílové podmnožiny (jen fresh a jen při změně klíče – u přejmenování se
  # počet rep projektu nemění). Naplní namerefy: stav, metadata repa, původní
  # archived flag a typ chyby pro close not_planned
  # (not_managed|name_taken|capacity_exceeded; prázdný = provozní chyba).
  # Použití: local _s _a _e; local -A _i=(); _gh-governance-move-validate <srcKey> <srcName> <dstKey> <dstName> _s _i _a _e
  local _src="$1" _src_name="$2" _dst="$3" _dst_name="$4" _mhn
  declare -n _v_state_ref="$5" _v_info_ref="$6" _v_archived_ref="$7" _v_error_ref="$8"
  _v_error_ref=""
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX GH_PROJECT_TOPIC_PREFIX || return 1
  # Existence obou projektů v conf.d (rezervovaný klíč existovat nemůže –
  # parser conf.d ho odmítá, _gh-conf-reserved-project-key).
  _bb-require-pk "$_src" _mhn || return 1
  _bb-require-pk "$_dst" _mhn || return 1
  if [[ "$_src" == "$_dst" && "$_src_name" == "$_dst_name" ]]; then
    echo "Chyba: Nic se nemění – projekt i jméno repa jsou shodné ('$_src/$_src_name')." >&2
    return 1
  fi
  if [[ "$_src" != "$_dst" && "$_src_name" != "$_dst_name" ]]; then
    echo "Chyba: Změna projektu i jména v jednom kroku není podporována." >&2
    return 1
  fi
  _gh-governance-repo-name "$_dst" "$_dst_name" >/dev/null || return 1
  _gh-validate-admin-team "$_dst" GITHUB_REPO_TEAMS || return 1
  _gh-governance-run-sha >/dev/null || return 1
  _gh-governance-move-detect "$_src" "$_src_name" "$_dst" "$_dst_name" _v_state_ref _v_info_ref || return 1
  case "$_v_state_ref" in
    fresh|half|done) ;;
    taken)   _v_error_ref=name_taken; return 1 ;;
    *)       _v_error_ref=not_managed; return 1 ;;
  esac
  # Původní archived flag: manifest je zdroj pravdy pro resume, fallback
  # živý stav repa (řádek může chybět – manifest se dorovnává nočně).
  _gh-governance-move-manifest-archived "$_src" "$_src_name" _v_archived_ref || return 1
  [[ -n "$_v_archived_ref" ]] || _v_archived_ref="${_v_info_ref[archived]}"
  if [[ "$_v_state_ref" == fresh && "$_src" != "$_dst" ]]; then
    _gh-governance-move-capacity-ok "$_dst" "$_v_archived_ref"
    case $? in
      0) ;;
      1) _v_error_ref=capacity_exceeded; return 1 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

_gh-governance-move-summary-settings() {
  # Doplní do summary efektivní konfiguraci cílové dvojice (nastavení repa
  # v cíli se použilo) a klíče souborů nastavení obou stran pro komentář
  # (zdrojový soubor zůstává jako nastavení bez repa – bot conf.d nemění).
  # Použití: _gh-governance-move-summary-settings <summary_assoc_name> <srcKey> <srcName> <dstKey> <dstName>
  declare -n _ss_ref="$1"
  local _src="$2" _src_name="$3" _dst="$4" _dst_name="$5" _eff
  _gh-conf-effective "$_dst" "$_dst_name" repository_teams _eff
  _ss_ref[expected_teams]="$_eff"
  _gh-conf-effective "$_dst" "$_dst_name" rulesets _eff
  _ss_ref[rulesets]="$_eff"
  _gh-conf-repo-settings-keys "$_src" "$_src_name" _eff
  _ss_ref[src_settings]="$_eff"
  _gh-conf-repo-settings-keys "$_dst" "$_dst_name" _eff
  _ss_ref[dst_settings]="$_eff"
  _ss_ref[mhn]=$(_gh-repository-policy-properties-expected-mhn "$_dst") || return 1
  return 0
}

_gh-governance-move-run() {
  # Hlavní orchestrátor přesunu repa mezi projekty (workflow move-repository
  # a split-project; dstName == srcName) i přejmenování repa uvnitř projektu
  # (workflow rename-repository; dstKey == srcKey). Kroky dle návrhů:
  # validace → (dearchivace) → rename → přepnutí topicu (jen přesun) →
  # politika cílové dvojice + upozornění → CODEOWNERS pod novým jménem
  # (nearchivované repo; selhání = jen text v summary) → (zrušení
  # redirectu) → (zpětná archivace) → přesun ukazatele state/ a řádku
  # manifestu jedním commitem.
  # Idempotentní: navazuje na rozpracovaný stav (detect). Nameref summary
  # naplní podklady pro komentář/summary (_gh-governance-move-comment; klíč
  # op = move|rename řídí texty; klíč codeowners = řádky poznámky CODEOWNERS,
  # vždy neprázdný); klíč error_type nese typ validačního odmítnutí (jinak
  # provozní chyba).
  # Použití: local -A _s=(); _gh-governance-move-run <srcKey> <srcName> <dstKey> <dstName> <keep|cancel> _s
  local _src="$1" _src_name="$2" _dst="$3" _dst_name="$4" _redirect="$5"
  declare -n _sum_ref="$6"
  local _state="" _archived="" _error="" _old_name _new_name _new_path _branch
  local _op=move _op_txt="přesunu" _run_sha _adopted=false _removed_login=""
  local _delete_issue="" _redirect_result="" _pointer="" _co_note=""
  local -a _removed=()
  local -A _info=() _warn=()
  case "$_redirect" in
    keep|cancel) ;;
    *) echo "Chyba: Režim redirectu musí být keep nebo cancel (je '$_redirect')." >&2
       return 1 ;;
  esac
  _sum_ref=([error_type]="")
  _old_name=$(_gh-governance-repo-name "$_src" "$_src_name") || return 1
  _new_name=$(_gh-governance-repo-name "$_dst" "$_dst_name") || return 1
  _new_path="${GITHUB_ORG}/${_new_name}"
  if ! _gh-governance-move-validate "$_src" "$_src_name" "$_dst" "$_dst_name" \
      _state _info _archived _error; then
    _sum_ref[error_type]="$_error"
    return 1
  fi
  # Validace zaručila změnu právě jedné složky.
  [[ "$_src" == "$_dst" ]] && { _op=rename; _op_txt="přejmenování"; }
  _run_sha=$(_gh-governance-run-sha) || return 1
  _sum_ref[op]="$_op"; _sum_ref[src_key]="$_src"; _sum_ref[dst_key]="$_dst"
  _sum_ref[src_name]="$_src_name"; _sum_ref[dst_name]="$_dst_name"
  _sum_ref[old_repo]="$_old_name"; _sum_ref[new_repo]="$_new_name"
  _sum_ref[url]="https://${GITHUB_ORG_HOSTNAME}/${_new_path}"
  _sum_ref[redirect]="$_redirect"; _sum_ref[archived]="$_archived"
  _sum_ref[state]="$_state"
  if [[ "$_op" == rename ]]; then
    echo "Přejmenování repa: ${GITHUB_ORG}/${_old_name} → ${_new_path} (stav: $_state, archivované: $_archived, redirect: $_redirect)."
  else
    echo "Přesun repa: ${GITHUB_ORG}/${_old_name} → ${_new_path} (stav: $_state, archivované: $_archived, redirect: $_redirect)."
  fi

  # Dearchivace na dobu operace (zpětná archivace před zápisem state/);
  # repo nese podle stavu ještě staré, nebo už nové jméno.
  local _cur_path="$_new_path"
  [[ "$_state" == fresh ]] && _cur_path="${GITHUB_ORG}/${_old_name}"
  if [[ "$_archived" == true && "${_info[archived]}" == true ]]; then
    _gh-api-input-retry "repos/$_cur_path" PATCH '{"archived":false}' \
      "dearchivace repa '$_cur_path' (na dobu $_op_txt)" || return 1
  fi
  if [[ "$_state" == fresh ]]; then
    _gh-api-input-retry "repos/${GITHUB_ORG}/${_old_name}" PATCH \
      "{\"name\":\"$_new_name\"}" "přejmenování repa na '$_new_name'" || return 1
  fi
  if [[ "$_op" == move && ( "$_state" == fresh || "$_state" == half ) ]]; then
    _gh-governance-move-topic-swap "$_new_path" "${_info[topics]}" "$_src" "$_dst" || return 1
  fi
  _branch="${_info[default_branch]}"
  if [[ -z "$_branch" ]]; then
    echo "Chyba: Repo '$_new_path' nemá výchozí větev." >&2
    return 1
  fi
  # Ukazatel před aplikací policy (do zápisu state/ níže je pod starým
  # jménem; po restartu už pryč = prázdný = info) – heuristika úrovně hlášení
  # správy CODEOWNERS. Jen u přejmenování: heuristika odvozuje „starého“
  # vlastníka z konfigurace cílové dvojice na SHA ukazatele, ale při přesunu
  # nese sekce vlastníka zdrojového projektu — změna je legitimní, ne ruční
  # zásah (ověřeno v pískovišti), proto přesun jde bez ukazatele (= info).
  if [[ "$_op" == rename ]]; then
    _pointer=$(_gh-governance-state-read "$_old_name" 2>/dev/null) || _pointer=""
  fi
  _gh-governance-move-apply-policy "$_new_path" "$_old_name" "$_branch" "$_src" "$_src_name" \
    "$_dst" "$_dst_name" _removed _adopted _removed_login || return 1
  _gh-governance-move-warnings "$_new_path" "$_dst" "$_dst_name" _warn || return 1
  # CODEOWNERS pod novým jménem dle efektivní konfigurace cílové dvojice.
  # Topics = stav před swapem (nese ghp-<src>) – apply-note testuje jen topic
  # migrace. Archivované repo se níže zpět archivuje (Contents API by pak
  # selhalo) a reconcile ho přeskakuje → jen text, dorovná dearchivace.
  if [[ "$_archived" == true ]]; then
    _co_note="CODEOWNERS: nezapsáno (repo archivované; dorovná se při dearchivaci)"
  else
    _gh-governance-codeowners-apply-note "$_new_name" "$_branch" "$_dst" \
      "${_info[topics]}" "$_pointer" _co_note
  fi
  if [[ "$_redirect" == cancel ]]; then
    # I při dokončování (half/done) – zrušení redirectu mohlo v minulém běhu
    # selhat; existující repo i chybějící redirect funkce sama idempotentně
    # přeskočí (result occupied/absent).
    _gh-governance-move-break-redirect "$_old_name" "$_new_name" \
      _delete_issue _redirect_result || return 1
  fi
  if [[ "$_archived" == true ]]; then
    _gh-api-input-retry "repos/$_new_path" PATCH '{"archived":true}' \
      "zpětná archivace repa '$_new_path'" || return 1
  fi
  _gh-governance-state-remove "$_old_name" || return 1
  _gh-governance-state-write "$_new_name" "$_run_sha" || return 1
  _gh-governance-manifest-remove "$_src" "$_src_name" || return 1
  _gh-governance-manifest-upsert "$_dst" "$_dst_name" "$_archived" || return 1
  _gh-governance-state-push "${_op}-repository: $_old_name -> $_new_name" || return 1

  _sum_ref[adopted]="$_adopted"
  _sum_ref[removed_teams]=$(printf '%s\n' "${_removed[@]-}")
  _sum_ref[removed_login]="$_removed_login"
  _sum_ref[delete_issue]="$_delete_issue"
  _sum_ref[redirect_result]="$_redirect_result"
  _gh-governance-move-summary-settings _sum_ref "$_src" "$_src_name" "$_dst" "$_dst_name" || return 1
  _sum_ref[warn_teams]="${_warn[teams]}"
  _sum_ref[warn_rulesets]="${_warn[rulesets]}"
  _sum_ref[warn_collaborators]="${_warn[collaborators]}"
  _sum_ref[codeowners]="$_co_note"
  [[ ${#_removed[@]} -gt 0 ]] && \
    printf 'Odebrán tým dle diffu konfigurace: %s\n' "${_removed[@]}"
  [[ -n "$_removed_login" ]] && \
    echo "Odebrán Jenkins collaborator '$_removed_login' dle diffu konfigurace."
  printf '%s\n' "$_co_note"
  if [[ "$_op" == rename ]]; then
    echo "Hotovo: repo přejmenováno na '$_new_name' ('$_new_path')."
  else
    echo "Hotovo: repo přesunuto do projektu '$_dst' jako '$_new_path'."
  fi
  return 0
}


_gh-governance-split-map-check() {
  # Zvaliduje mapu rozdělení projektu (docs/implementovano/navrh/rozdeleni-projektu.md,
  # fáze 0/2): TSV řádky ghName<TAB>newProjectKey[<TAB>keep], bez hlavičky
  # a prázdných řádků, LF, unikátní ghName, cílový klíč ≠ zdrojový,
  # setříděno LC_ALL=C podle ghName (deterministický diff v gov repu).
  # Fail-fast nastavení repa (návrh nastavení-repa, split-project): repo se
  # souborem nastavení ve zdroji a bez něj v cíli je chyba (viz
  # _gh-governance-split-settings-missing). Kořen pro state/ = rodič conf.d
  # bez ověření gitu – kontrola zůstává offline i pro plánovací tool nad
  # prostým adresářem conf.d (bez state/ = žádný hotový přesun).
  # Vypíše všechny nalezené chyby; rc = 0 validní, 1 = chyby.
  # Použití: _gh-governance-split-map-check <mapa.tsv> <srcKey>
  local _map="$1" _src="$2" _line _name _key _redirect _extra _n=0 _errors=0
  local _root="${_GH_COMMON_CONF_D%/*}"
  local -A _seen=()
  if [[ ! -f "$_map" ]]; then
    echo "Chyba: Mapa '$_map' neexistuje." >&2
    return 1
  fi
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    _n=$(( _n + 1 ))
    if [[ "$_line" == *$'\r'* ]]; then
      echo "Chyba: mapa řádek $_n: CR znak – mapa musí mít LF konce řádků." >&2
      _errors=$(( _errors + 1 )); continue
    fi
    if [[ -z "$_line" ]]; then
      echo "Chyba: mapa řádek $_n: prázdný řádek není povolen." >&2
      _errors=$(( _errors + 1 )); continue
    fi
    IFS=$'\t' read -r _name _key _redirect _extra <<< "$_line"
    if [[ -n "$_extra" ]]; then
      echo "Chyba: mapa řádek $_n: více než 3 sloupce." >&2
      _errors=$(( _errors + 1 )); continue
    fi
    if ! _gh-match "$_name" "$_GH_GHNAME_REGEX"; then
      echo "Chyba: mapa řádek $_n: ghName '$_name' neodpovídá formátu (defs/defs.md)." >&2
      _errors=$(( _errors + 1 ))
    fi
    if ! _gh-match "$_key" "$_GH_PROJECT_KEY_REGEX"; then
      echo "Chyba: mapa řádek $_n: cílový klíč '$_key' neodpovídá formátu (defs/defs.md)." >&2
      _errors=$(( _errors + 1 ))
    elif [[ "$_key" == "$_src" ]]; then
      echo "Chyba: mapa řádek $_n: cílový klíč je shodný se zdrojovým projektem '$_src'." >&2
      _errors=$(( _errors + 1 ))
    elif _gh-governance-split-settings-missing "$_src" "$_name" "$_key" "$_root"; then
      echo "Chyba: mapa řádek $_n: repo '$_name' má nastavení ve zdrojovém projektu (conf.d/projects/$_src/$_name.conf) a nemá ho v cílovém '$_key' – založ conf.d/projects/$_key/$_name.conf PR, nebo soubor ve zdroji PR smaž (výchozí politika cíle)." >&2
      _errors=$(( _errors + 1 ))
    fi
    case "$_redirect" in
      ""|keep) ;;
      *) echo "Chyba: mapa řádek $_n: třetí sloupec smí být jen 'keep' (je '$_redirect')." >&2
         _errors=$(( _errors + 1 )) ;;
    esac
    if [[ -v _seen["$_name"] ]]; then
      echo "Chyba: mapa řádek $_n: duplicitní ghName '$_name'." >&2
      _errors=$(( _errors + 1 ))
    fi
    _seen["$_name"]=1
  done < "$_map"
  if [[ $_n -eq 0 ]]; then
    echo "Chyba: Mapa '$_map' je prázdná." >&2
    _errors=$(( _errors + 1 ))
  elif ! LC_ALL=C sort -c -t$'\t' -k1,1 "$_map" 2>/dev/null; then
    echo "Chyba: Mapa není setříděná podle ghName (LC_ALL=C sort -t\$'\\t' -k1,1)." >&2
    _errors=$(( _errors + 1 ))
  fi
  [[ $_errors -eq 0 ]]
}

_gh-governance-split-settings-missing() {
  # rc 0 ⇔ repo má nastavení repa ve zdrojovém projektu, v cílovém ne
  # a přesun ještě neproběhl (ukazatel state/<prefix>-<dst>-<ghName>
  # pod <root> neexistuje – hotová repa restartovaný běh přeskakuje,
  # soubor ve zdroji se maže až závěrečným PR). Čistá offline funkce
  # nad indexem konfigurace a adresářem state/ pod <root>.
  # Použití: _gh-governance-split-settings-missing <srcKey> <ghName> <dstKey> <root>
  local _src="$1" _name="$2" _dst="$3" _root="$4"
  _gh-conf-repo-has-settings "$_src" "$_name" || return 1
  _gh-conf-repo-has-settings "$_dst" "$_name" && return 1
  [[ ! -f "$_root/state/${GH_REPO_PREFIX}-${_dst}-${_name}" ]]
}

_gh-governance-split-map-rows() {
  # Načte řádky (předem zvalidované) mapy do nameref pole položek
  # "ghName<TAB>newProjectKey<TAB>keep|cancel" (třetí sloupec doplněn).
  # Použití: local -a _rows=(); _gh-governance-split-map-rows <mapa.tsv> _rows
  local _map="$1" _line _name _key _redirect _extra
  declare -n _rows_ref="$2"
  _rows_ref=()
  [[ -f "$_map" ]] || return 1
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ -z "$_line" ]] && continue
    IFS=$'\t' read -r _name _key _redirect _extra <<< "$_line"
    [[ "$_redirect" == keep ]] || _redirect=cancel
    _rows_ref+=("$_name"$'\t'"$_key"$'\t'"$_redirect")
  done < "$_map"
  return 0
}

_gh-governance-move-comment-settings() {
  # Interní: řádky komentáře o nastavení repa (použité v cíli, ponechané ve
  # zdroji jako nastavení bez repa) – texty dle operace (op = move|rename).
  # Použití: _gh-governance-move-comment-settings <summary_assoc_name>
  declare -n _cs_ref="$1"
  local _dst_file="conf.d/projects/${_cs_ref[dst_key]}/${_cs_ref[dst_name]}.conf"
  local _src_file="conf.d/projects/${_cs_ref[src_key]}/${_cs_ref[src_name]}.conf"
  if [[ "${_cs_ref[op]:-move}" == rename ]]; then
    [[ -n "${_cs_ref[dst_settings]:-}" ]] && \
      echo "- pod novým jménem existuje nastavení repa \`$_dst_file\` (${_cs_ref[dst_settings]// /, }) a bylo použito"
    [[ -n "${_cs_ref[src_settings]:-}" ]] && \
      echo "- nastavení pod starým jménem zůstalo: \`$_src_file\` (${_cs_ref[src_settings]// /, }) je teď nastavení bez repa – smaž ho PR do gov repa"
  else
    [[ -n "${_cs_ref[dst_settings]:-}" ]] && \
      echo "- v cílovém projektu existuje nastavení repa \`$_dst_file\` (${_cs_ref[dst_settings]// /, }) a bylo použito"
    [[ -n "${_cs_ref[src_settings]:-}" ]] && \
      echo "- nastavení repa ve zdrojovém projektu zůstalo: \`$_src_file\` (${_cs_ref[src_settings]// /, }) je teď nastavení bez repa – smaž ho PR do gov repa"
  fi
  return 0
}

_gh-governance-move-comment() {
  # Vyrenderuje markdown závěrečného komentáře issue / summary splitu ze
  # summary operace (návrhy, Závěrečný komentář issue): shrnutí, provedené
  # změny (včetně nastavení repa), upozornění na ruční odchylky (terminologie
  # reconcile warningů; operace je neměnila, repo si je nese s sebou). Texty
  # se řídí klíčem op (move = přesun mezi projekty, rename = přejmenování).
  # Použití: _gh-governance-move-comment <summary_assoc_name>
  local _line _rename=false _op_txt="přesun" _op_neg="neměnil"
  declare -n _c_ref="$1"
  [[ "${_c_ref[op]:-move}" == rename ]] && { _rename=true; _op_txt="přejmenování"; _op_neg="neměnilo"; }
  if [[ "$_rename" == true ]]; then
    echo "Přejmenování repa dokončeno: \`${_c_ref[old_repo]}\` → [\`${_c_ref[new_repo]}\`](${_c_ref[url]}) (projekt \`${_c_ref[src_key]}\` beze změny)."
  else
    echo "Přesun repa dokončen: \`${_c_ref[old_repo]}\` → [\`${_c_ref[new_repo]}\`](${_c_ref[url]}) (projekt \`${_c_ref[src_key]}\` → \`${_c_ref[dst_key]}\`)."
  fi
  echo ""
  echo "**Provedené změny:**"
  if [[ "$_rename" == true ]]; then
    echo "- politika projektu aplikována (týmy: \`${_c_ref[expected_teams]}\`; rulesety: \`${_c_ref[rulesets]}\`; property MHN: \`${_c_ref[mhn]}\`)"
  else
    echo "- politika cílového projektu aplikována (týmy: \`${_c_ref[expected_teams]}\`; rulesety: \`${_c_ref[rulesets]}\`; property MHN: \`${_c_ref[mhn]}\`)"
  fi
  # Řádky poznámky CODEOWNERS (summary klíč codeowners; `:-` – testy plní
  # summary ručně).
  if [[ -n "${_c_ref[codeowners]:-}" ]]; then
    while IFS= read -r _line; do
      [[ -n "$_line" ]] && echo "- $_line"
    done <<< "${_c_ref[codeowners]}"
  fi
  _gh-governance-move-comment-settings _c_ref
  if [[ -n "${_c_ref[removed_teams]}" ]]; then
    while IFS= read -r _line; do
      [[ -n "$_line" ]] || continue
      if [[ "$_rename" == true ]]; then
        echo "- odebrán tým dle diffu ukazatele (nastavení starého jména): \`$_line\`"
      else
        echo "- odebrán tým zdrojového projektu dle diffu ukazatele: \`$_line\`"
      fi
    done <<< "${_c_ref[removed_teams]}"
  fi
  [[ -n "${_c_ref[removed_login]}" ]] && \
    echo "- odebrán Jenkins collaborator zdrojové domény: \`${_c_ref[removed_login]}\`"
  [[ "${_c_ref[adopted]}" == true ]] && \
    echo "- adopce: repo bylo bez ukazatele posledního aplikovaného stavu – nic se neodebíralo, ukazatel založen"
  [[ "${_c_ref[archived]}" == true ]] && \
    echo "- repo bylo archivované: dearchivováno na dobu $_op_txt a znovu archivováno"
  if [[ "${_c_ref[redirect]}" == cancel ]]; then
    case "${_c_ref[redirect_result]:-}" in
      broken)
        echo "- redirect starého jména zrušen – stará URL přestala fungovat${_c_ref[delete_issue]:+ (žádost o smazání dočasného repa: ${_c_ref[delete_issue]})}" ;;
      absent)
        echo "- redirect starého jména už neexistoval (zrušen dříve) – stará URL nefunguje" ;;
      *)
        echo "- zrušení redirectu přeskočeno – staré jméno je obsazené repem (dočasné repo čekající na smazání, nebo cizí repo); zkontroluj ručně" ;;
    esac
  else
    echo "- redirect starého jména ponechán (\`--redirect\`) – stará URL funguje, dokud staré jméno někdo neobsadí"
  fi
  if [[ -n "${_c_ref[warn_teams]}${_c_ref[warn_rulesets]}${_c_ref[warn_collaborators]}" ]]; then
    echo ""
    echo "**Upozornění** ($_op_txt nic z toho $_op_neg, repo si to nese s sebou):"
    [[ -n "${_c_ref[warn_teams]}" ]] && while IFS= read -r _line; do
      [[ -n "$_line" ]] && echo "- tým přiřazený navíc: \`$_line\`"
    done <<< "${_c_ref[warn_teams]}"
    [[ -n "${_c_ref[warn_rulesets]}" ]] && while IFS= read -r _line; do
      [[ -n "$_line" ]] && echo "- ruleset přiřazený navíc: \`$_line\`"
    done <<< "${_c_ref[warn_rulesets]}"
    [[ -n "${_c_ref[warn_collaborators]}" ]] && while IFS= read -r _line; do
      [[ -n "$_line" ]] && echo "- collaborator přiřazený navíc: \`$_line\`"
    done <<< "${_c_ref[warn_collaborators]}"
  fi
  return 0
}

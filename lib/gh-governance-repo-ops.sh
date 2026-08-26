#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Jádro governance operací new/archive/unarchive nad spravovanými repy.
# Volají je entry skripty governance/bin/gov-*.sh – lokálně (krok 2 PoC)
# i z workflows gov repa.
# Závislosti: gh-common-defs.sh, lib/gh-conf.sh, lib/gh-repository-policy.sh,
# lib/gh-governance-state.sh, lib/gh-governance-manifest.sh.
[[ -n "${_GH_GOVERNANCE_REPO_OPS_LOADED:-}" ]] && \
  declare -F _gh-governance-new >/dev/null && return 0
_GH_GOVERNANCE_REPO_OPS_LOADED=1

_gh-governance-repo-name() {
  # Zvaliduje ghName (formát _GH_GHNAME_REGEX dle defs/defs.md, délka
  # výsledného ghRepoName ≤ 100) a vypíše ghRepoName =
  # <GH_REPO_PREFIX>-<projectKey>-<ghName>.
  # Použití: _gh-governance-repo-name <projectKey> <ghName>
  local _key="$1" _name="$2" _repo_name
  if ! _gh-match "$_name" "$_GH_GHNAME_REGEX"; then
    echo "Chyba: ghName '$_name' neodpovídá formátu $_GH_GHNAME_REGEX (defs/defs.md)." >&2
    return 1
  fi
  _repo_name="${GH_REPO_PREFIX}-${_key}-${_name}"
  if [[ ${#_repo_name} -gt 100 ]]; then
    echo "Chyba: ghRepoName '$_repo_name' překračuje limit 100 znaků (má ${#_repo_name})." >&2
    return 1
  fi
  printf '%s\n' "$_repo_name"
}

_gh-governance-repo-info() {
  # Načte metadata repa do nameref asoc. pole: exists (true/false), archived,
  # default_branch, topics (CSV), full_name. rc 0 i pro neexistující repo
  # (exists=false); rc 1 = chyba API. Pozor: GET repos/{path} následuje GitHub
  # rename redirect – full_name odlišný od dotazované cesty znamená, že pod
  # dotazovaným jménem repo neleží (jméno nese jen redirect).
  # Použití: local -A _i=(); _gh-governance-repo-info <repo_path> _i
  local _repo_path="$1" _row _error_file _error _full _archived _branch _topics _extra
  declare -n _info_ref="$2"
  _info_ref=([exists]=false [archived]=false [default_branch]="" [topics]="" [full_name]="")
  _error_file=$(mktemp) || return 1
  if _row=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path" \
      --jq '[(.full_name // ""), ((.archived // false) | tostring), (.default_branch // ""), ((.topics // []) | join(","))] | @tsv' \
      2>"$_error_file"); then
    rm -f "$_error_file"
    IFS=$'\t' read -r _full _archived _branch _topics _extra <<< "$_row"
    _info_ref[exists]=true
    _info_ref[archived]="$_archived"
    _info_ref[default_branch]="$_branch"
    _info_ref[topics]="$_topics"
    _info_ref[full_name]="$_full"
    return 0
  fi
  _error=$(< "$_error_file")
  rm -f "$_error_file"
  grep -qF '(HTTP 404)' <<< "$_error" && return 0
  [[ -n "$_error" ]] && printf '%s\n' "$_error" >&2
  echo "Chyba: Nepodařilo se načíst metadata repa '$_repo_path'." >&2
  return 1
}

_gh-governance-ghp-topics() {
  # Spočítá topicy ghp-* v CSV seznamu topiců do nameref proměnných
  # (počet a poslední nalezený topic). Jediné místo této logiky.
  # Použití: local _n _t; _gh-governance-ghp-topics <topicsCSV> _n _t
  local _topics="$1" _item
  declare -n _count_ref="$2" _topic_ref="$3"
  local -a _topic_arr=()
  _count_ref=0
  _topic_ref=""
  IFS=',' read -ra _topic_arr <<< "$_topics"
  for _item in "${_topic_arr[@]}"; do
    if [[ "$_item" == "$GH_PROJECT_TOPIC_PREFIX"* ]]; then
      _count_ref=$(( _count_ref + 1 ))
      _topic_ref="$_item"
    fi
  done
  return 0
}

_gh-governance-managed-verify() {
  # Ověří spravovanost repa projektu dle defs/defs.md: právě jeden topic
  # ghp-* a ten je ghp-<projectKey> (název dle konvence zaručuje konstrukce
  # ghRepoName volajícím). rc 1 se srozumitelnou chybou, pokud repo spravované není.
  # Použití: _gh-governance-managed-verify <repo_path> <projectKey> <topicsCSV>
  local _repo_path="$1" _key="$2" _topics="$3" _ghp_count _ghp
  local _expected="${GH_PROJECT_TOPIC_PREFIX}${_key}"
  _gh-governance-ghp-topics "$_topics" _ghp_count _ghp
  if [[ $_ghp_count -eq 1 && "$_ghp" == "$_expected" ]]; then
    return 0
  fi
  if [[ $_ghp_count -eq 0 ]]; then
    echo "Chyba: Repo '$_repo_path' nemá topic '$_expected' – není spravovaným repem projektu (divoké repo, viz defs/defs.md)." >&2
  elif [[ $_ghp_count -gt 1 ]]; then
    echo "Chyba: Repo '$_repo_path' má více topiců ${GH_PROJECT_TOPIC_PREFIX}* – víceznačné repo (viz defs/defs.md)." >&2
  else
    echo "Chyba: Repo '$_repo_path' má topic '$_ghp', očekává se '$_expected' – nepatří projektu." >&2
  fi
  return 1
}

_gh-governance-apply-policy-and-state() {
  # Společné jádro new/unarchive/reconcile: aplikuje repository policy,
  # odebere týmy a Jenkins login staré domény dle diffu konfigurace
  # ukazatel→RUN_SHA a zapíše ukazatel do checkoutu (commit+push dělá
  # volající přes _gh-governance-state-push).
  # Adopce (repo bez ukazatele): nic se neodebírá, ukazatel se založí.
  # Výstupy: nameref pole odebraných týmů, nameref adopce (true/false),
  # nameref odebraného Jenkins loginu (prázdný = nic).
  # Použití: _gh-governance-apply-policy-and-state <repo_path> <ghRepoName> <branch> <projectKey> <removed_array_name> <adopted_flag_name> <removed_login_name>
  local _repo_path="$1" _repo_name="$2" _branch="$3" _key="$4"
  declare -n _removed_ref="$5" _adopted_ref="$6" _removed_login_ref="$7"
  local _pointer_sha="" _run_sha _rm_out _rm_login=""
  local -a _rm_teams=()
  _removed_ref=()
  _adopted_ref=false
  _removed_login_ref=""
  _run_sha=$(_gh-governance-run-sha) || return 1
  _pointer_sha=$(_gh-governance-state-read "$_repo_name")
  case $? in
    0) ;;
    1) _adopted_ref=true ;;
    *) return 1 ;;
  esac
  _gh-repository-policy-apply "$_repo_path" "$_branch" "$_key" || return 1
  if [[ "$_adopted_ref" == false && "$_pointer_sha" != "$_run_sha" ]]; then
    _gh-governance-teams-to-remove "$_key" "$_pointer_sha" "$_run_sha" _rm_teams || return 1
    _rm_out=$(mktemp) || return 1
    if ! _gh-governance-teams-remove "$_repo_path" "$_key" _rm_teams > "$_rm_out"; then
      rm -f "$_rm_out"
      return 1
    fi
    mapfile -t _removed_ref < "$_rm_out"
    rm -f "$_rm_out"
    # Jenkins login staré domény (přesun projektu / výměna jenkins_user):
    # stejný mechanismus diffu ukazatele, DELETE 404-tolerantně.
    _gh-governance-jenkins-to-remove "$_key" "$_pointer_sha" "$_run_sha" _rm_login || return 1
    if [[ -n "$_rm_login" ]]; then
      _gh-jenkins-collaborator-remove "$_repo_path" "$_key" "$_rm_login" || return 1
      _removed_login_ref="$_rm_login"
    fi
  fi
  _gh-governance-state-write "$_repo_name" "$_run_sha"
}

_gh-governance-new() {
  # Založí (nebo konverguje existující) spravované repo projektu: create
  # s auto_init (větev musí existovat před rulesety, viz
  # docs/github/repo-create-auto-init-prazdne-repo.md), topic ghp-<key>,
  # aplikace policy, odebrání týmů dle ukazatele, posun ukazatele + push.
  # Existující repo není chyba – provede se jen konvergence.
  # Použití: _gh-governance-new <projectKey> <ghName>
  local _key="$1" _name="$2" _mhn _repo_name _repo_path _branch _attempt
  local _adopted=false _removed_login=""
  local -a _removed=()
  local -A _info=()
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX GH_PROJECT_TOPIC_PREFIX GH_NEW_REPO_VISIBILITY || return 1
  case "$GH_NEW_REPO_VISIBILITY" in
    public|private|internal) ;;
    *) echo "Chyba: GH_NEW_REPO_VISIBILITY musí být public, private nebo internal (je '$GH_NEW_REPO_VISIBILITY')." >&2
       return 1 ;;
  esac
  _bb-require-pk "$_key" _mhn || return 1
  _repo_name=$(_gh-governance-repo-name "$_key" "$_name") || return 1
  _repo_path="${GITHUB_ORG}/${_repo_name}"
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-governance-run-sha >/dev/null || return 1
  _gh-governance-repo-info "$_repo_path" _info || return 1

  if [[ "${_info[exists]}" == true ]]; then
    if [[ "${_info[archived]}" == true ]]; then
      echo "Chyba: Repo '$_repo_path' už existuje a je archivované – konvergence není možná (použij gh-unarchive)." >&2
      return 1
    fi
    echo "Repo '$_repo_path' už existuje – provádím konvergenci k INI konfiguraci."
    # Bez topicu ghp-* (divoké repo) je konvergence legitimní adopce (topic
    # se doplní níže); cizí nebo vícenásobný topic ghp-* nepřepisujeme.
    local _ghp_count _ghp
    _gh-governance-ghp-topics "${_info[topics]}" _ghp_count _ghp
    if [[ $_ghp_count -gt 0 ]]; then
      _gh-governance-managed-verify "$_repo_path" "$_key" "${_info[topics]}" || return 1
    fi
  else
    printf 'Zakládám repo %s (viditelnost: %s).\n' "$_repo_path" "$GH_NEW_REPO_VISIBILITY"
    _gh-api-input-retry "orgs/$GITHUB_ORG/repos" POST \
      "{\"name\":\"$_repo_name\",\"visibility\":\"$GH_NEW_REPO_VISIBILITY\",\"auto_init\":true}" \
      "založení repa '$_repo_path'" || return 1
  fi

  _gh-governance-repo-info "$_repo_path" _info || return 1
  _branch="${_info[default_branch]}"
  if [[ -z "$_branch" ]]; then
    echo "Chyba: Repo '$_repo_path' nemá výchozí větev." >&2
    return 1
  fi
  # auto_init commit může chvíli vznikat – počkej, až větev skutečně existuje.
  for _attempt in 1 2 3 4 5; do
    GH_HOST="$GITHUB_ORG_HOSTNAME" gh api \
      "repos/$_repo_path/git/ref/heads/$(_url_encode_path "$_branch")" \
      >/dev/null 2>&1 && break
    if [[ "$_attempt" == 5 ]]; then
      echo "Chyba: Výchozí větev '$_branch' repa '$_repo_path' nevznikla (auto_init)." >&2
      return 1
    fi
    sleep 2
  done

  GH_HOST="$GITHUB_ORG_HOSTNAME" gh repo edit "$_repo_path" \
    --add-topic "${GH_PROJECT_TOPIC_PREFIX}${_key}" >/dev/null || return 1

  _gh-governance-apply-policy-and-state "$_repo_path" "$_repo_name" "$_branch" "$_key" \
    _removed _adopted _removed_login || return 1
  _gh-governance-manifest-upsert "$_key" "$_name" false || return 1
  _gh-governance-state-push "new-repository: $_repo_name" || return 1
  [[ ${#_removed[@]} -gt 0 ]] && \
    printf 'Odebrán tým dle diffu konfigurace: %s\n' "${_removed[@]}"
  [[ -n "$_removed_login" ]] && \
    echo "Odebrán Jenkins collaborator '$_removed_login' dle diffu konfigurace."
  echo "Hotovo: repo '$_repo_path' odpovídá INI konfiguraci projektu '$_key'."
}

_gh-governance-archive() {
  # Archivuje spravované nearchivované repo projektu (PATCH archived=true).
  # Ukazatel posledního aplikovaného stavu se neposouvá – zmrazí se sám;
  # pushuje se jen přepnutí řádku completion manifestu (archived=true,
  # i pro už archivované repo – konvergence manifestu).
  # Použití: _gh-governance-archive <projectKey> <ghName>
  local _key="$1" _name="$2" _mhn _repo_name _repo_path
  local -A _info=()
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX GH_PROJECT_TOPIC_PREFIX || return 1
  _bb-require-pk "$_key" _mhn || return 1
  _repo_name=$(_gh-governance-repo-name "$_key" "$_name") || return 1
  _repo_path="${GITHUB_ORG}/${_repo_name}"
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-governance-repo-info "$_repo_path" _info || return 1
  if [[ "${_info[exists]}" != true ]]; then
    echo "Chyba: Repo '$_repo_path' neexistuje." >&2
    return 1
  fi
  _gh-governance-managed-verify "$_repo_path" "$_key" "${_info[topics]}" || return 1
  if [[ "${_info[archived]}" == true ]]; then
    echo "Repo '$_repo_path' už je archivované – jen konverguji completion manifest."
  else
    _gh-api-input-retry "repos/$_repo_path" PATCH '{"archived":true}' \
      "archivace repa '$_repo_path'" || return 1
    echo "Hotovo: repo '$_repo_path' je archivované."
  fi
  _gh-governance-manifest-upsert "$_key" "$_name" true || return 1
  _gh-governance-state-push "archive-repository: $_repo_name" || return 1
}

_gh-governance-unarchive() {
  # Dearchivuje spravované repo projektu a hned aplikuje politiku včetně
  # odebrání týmů dle zmrazeného ukazatele; po úspěchu ukazatel posune.
  # Nearchivované repo není chyba – provede se jen konvergence.
  # Použití: _gh-governance-unarchive <projectKey> <ghName>
  local _key="$1" _name="$2" _mhn _repo_name _repo_path _branch
  local _adopted=false _removed_login=""
  local -a _removed=()
  local -A _info=()
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX GH_PROJECT_TOPIC_PREFIX || return 1
  _bb-require-pk "$_key" _mhn || return 1
  _repo_name=$(_gh-governance-repo-name "$_key" "$_name") || return 1
  _repo_path="${GITHUB_ORG}/${_repo_name}"
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _gh-governance-run-sha >/dev/null || return 1
  _gh-governance-repo-info "$_repo_path" _info || return 1
  if [[ "${_info[exists]}" != true ]]; then
    echo "Chyba: Repo '$_repo_path' neexistuje." >&2
    return 1
  fi
  _gh-governance-managed-verify "$_repo_path" "$_key" "${_info[topics]}" || return 1
  if [[ "${_info[archived]}" == true ]]; then
    _gh-api-input-retry "repos/$_repo_path" PATCH '{"archived":false}' \
      "dearchivace repa '$_repo_path'" || return 1
    echo "Repo '$_repo_path' dearchivováno – aplikuji politiku."
  else
    echo "Repo '$_repo_path' není archivované – provádím jen konvergenci politiky."
  fi
  _branch="${_info[default_branch]}"
  if [[ -z "$_branch" ]]; then
    echo "Chyba: Repo '$_repo_path' nemá výchozí větev." >&2
    return 1
  fi
  _gh-governance-apply-policy-and-state "$_repo_path" "$_repo_name" "$_branch" "$_key" \
    _removed _adopted _removed_login || return 1
  _gh-governance-manifest-upsert "$_key" "$_name" false || return 1
  _gh-governance-state-push "unarchive-repository: $_repo_name" || return 1
  [[ "$_adopted" == true ]] && \
    echo "Adopce repa: ukazatel posledního aplikovaného stavu založen, nic se neodebíralo."
  [[ ${#_removed[@]} -gt 0 ]] && \
    printf 'Odebrán tým dle diffu konfigurace: %s\n' "${_removed[@]}"
  [[ -n "$_removed_login" ]] && \
    echo "Odebrán Jenkins collaborator '$_removed_login' dle diffu konfigurace."
  echo "Hotovo: repo '$_repo_path' odpovídá INI konfiguraci projektu '$_key'."
}

_gh-governance-track-delete() {
  # Sleduje zánik repa po podané žádosti o smazání (track-delete issue,
  # defs/defs-governance-repo.md): polluje existenci repa přímým dotazem;
  # teprve po prokázaném HTTP 404 uklidí ukazatel state/<ghRepoName> i řádek
  # completion manifestu a pushne. Nic na GitHubu nemaže.
  # rc 0 = repo zaniklo a úklid proběhl, rc 2 = repo po timeoutu stále
  # existuje (není selhání), rc 1 = provozní chyba.
  # Použití: _gh-governance-track-delete <projectKey> <ghName>
  local _key="$1" _name="$2" _repo_name _repo_path
  local _timeout_s _elapsed_s=0
  local -A _info=()
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_REPO_PREFIX || return 1
  _repo_name=$(_gh-governance-repo-name "$_key" "$_name") || return 1
  _repo_path="${GITHUB_ORG}/${_repo_name}"
  _timeout_s=$(( GH_GOVERNANCE_TRACK_DELETE_TIMEOUT_MIN * 60 ))
  echo "Sleduji zánik repa '$_repo_path' (max ${GH_GOVERNANCE_TRACK_DELETE_TIMEOUT_MIN} min po ${GH_GOVERNANCE_TRACK_DELETE_INTERVAL_S} s)."
  while :; do
    # API chyba (rc 1) je neprůkazná – poll pokračuje; úklid smí spustit
    # jen jednoznačné 404 (rc 0 + exists=false).
    if _gh-governance-repo-info "$_repo_path" _info \
        && [[ "${_info[exists]}" == false ]]; then
      _gh-governance-state-remove "$_repo_name" || return 1
      _gh-governance-manifest-remove "$_key" "$_name" || return 1
      _gh-governance-state-push "track-delete: $_repo_name" || return 1
      echo "Hotovo: repo '$_repo_path' zaniklo, ukazatel i řádek manifestu uklizeny."
      return 0
    fi
    if (( _elapsed_s >= _timeout_s )); then
      break
    fi
    sleep "$GH_GOVERNANCE_TRACK_DELETE_INTERVAL_S"
    (( _elapsed_s += GH_GOVERNANCE_TRACK_DELETE_INTERVAL_S )) || true
  done
  echo "Repo '$_repo_path' po ${GH_GOVERNANCE_TRACK_DELETE_TIMEOUT_MIN} min stále existuje – úklid neproveden." >&2
  return 2
}

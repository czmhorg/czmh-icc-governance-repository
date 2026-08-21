#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Pracovní repa funkcí (docs/implementovano/pracovni-repa-funkci.md): trvalé klony
# v ${GH_WORK_REPOS_ROOT}, se kterými pracují výhradně funkce (pracovní klon
# gov repa, pracovní klony řídicích rep migrace). Modul poskytuje zámek per
# pracovní repo, layout cest pod kořenem a sync (clone / fetch + ff) bez
# uložení tokenu do .git/config.
# Automaticky se dokončuje jen vlastní nedokončená operace: push vlastních
# commitů, které jsou po čerstvém fetchi čistým předstihem nad origin, úklid
# vlastního .git/index.lock (pod zámkem repa) a smazání částečného klonu
# <dir>.partial. Necommitnuté změny (vlastní nedokončená transakce) se
# zahazují s hláškou. Cizí obsah (divergence, cizí origin, ne-git adresář) se nikdy nemaže ani
# nepřepisuje — _gh-work-repo-error vypíše akční hlášku pro ruční zásah.
# Pořadí práce s pracovním repem: zámek → sync → práce → uvolnění zámku.
# Závislosti: git; GH_WORK_REPOS_ROOT definuje gh-common-defs.sh.
[[ -n "${_GH_WORK_REPO_LOADED:-}" ]] && \
  declare -F _gh-work-repo-sync >/dev/null && return 0
_GH_WORK_REPO_LOADED=1

# Timeout čekání na obsazený zámek v sekundách (testy hodnotu snižují).
: "${_GH_WORK_LOCK_TIMEOUT_S:=30}"

_gh-work-repos-root() {
  # Vypíše kořen pracovních rep funkcí.
  # Použití: _gh-work-repos-root
  printf '%s\n' "${GH_WORK_REPOS_ROOT:-${HOME}/.local/state/gh-work}"
}

# Layout pod kořenem (návrh, kapitola Umístění): gov-repo/ (pracovní klon gov
# repa, cestu odvozuje gh-common-defs.sh) a migrate-to-github/<projectKey>/
# (pracovní klony řídicích rep migrace). Cesty definuje výhradně tento modul —
# sdílí je bb-migrate.sh a tools/clean-work-repos.sh.
_GH_WORK_MIGRATE_SUBDIR="migrate-to-github"

_bb-migrate-control-dir() {
  # Vypíše cestu trvalého pracovního klonu řídicího repa migrace projektu.
  # Použití: _bb-migrate-control-dir <projectKey>
  printf '%s\n' "$(_gh-work-repos-root)/${_GH_WORK_MIGRATE_SUBDIR}/$1"
}

_gh-work-repo-lock() {
  # Zamkne pracovní repo (mkdir je atomický); zámek <repo_dir>.lock se drží po
  # celou práci s klonem. Obsazený zámek živým procesem → čekání max
  # _GH_WORK_LOCK_TIMEOUT_S s (à 1 s), po timeoutu akční chyba. Osiřelý zámek
  # (uložený PID už neběží) se převezme — jediná povolená automatika; čas
  # v zámku je jen diagnostika pro člověka.
  # Použití: _gh-work-repo-lock <repo_dir>
  local _dir="$1" _lock="$1.lock" _pid _since _waited=0
  mkdir -p "$(dirname "$_lock")" || return 1
  while :; do
    if mkdir "$_lock" 2>/dev/null; then
      printf '%s\n%s\n' $$ "$(date '+%Y-%m-%d %H:%M:%S')" > "$_lock/pid"
      return 0
    fi
    _pid="" _since=""
    { read -r _pid; read -r _since; } < "$_lock/pid" 2>/dev/null
    if [[ -n "$_pid" ]] && ! kill -0 "$_pid" 2>/dev/null; then
      rm -rf "$_lock"
      continue
    fi
    if (( _waited >= _GH_WORK_LOCK_TIMEOUT_S )); then
      echo "Chyba: Pracovní repo '$_dir' je zamčené jiným během (PID ${_pid:-neznámý}, od ${_since:-neznámo}, zámek '$_lock')." >&2
      echo "Počkej na doběhnutí procesu ${_pid:-}; pokud už neběží, smaž adresář zámku: rm -rf '$_lock'" >&2
      return 1
    fi
    sleep 1
    _waited=$(( _waited + 1 ))
  done
}

_gh-work-repo-unlock() {
  # Uvolní zámek pracovního repa.
  # Použití: _gh-work-repo-unlock <repo_dir>
  rm -rf "$1.lock"
}

_gh-work-repo-mask-auth() {
  # Vymaskuje v textu přihlašovací část tokenizované URL (user:token@ → ***@
  # a samotný token → ***), aby šel chybový výstup gitu bezpečně vypsat —
  # git v hláškách URL opakuje. Bez přihlašovací části vrací text beze změny.
  # Použití: _gh-work-repo-mask-auth <text> <auth_url>
  local _text="$1" _auth_url="$2" _cred _secret
  if [[ "$_auth_url" == *://*@* ]]; then
    _cred="${_auth_url#*://}"; _cred="${_cred%%@*}"
    _text="${_text//"$_cred@"/***@}"
    _secret="${_cred#*:}"
    [[ -z "$_secret" ]] || _text="${_text//"$_secret"/***}"
  fi
  printf '%s\n' "$_text"
}

_gh-work-repo-clean-cmd() {
  # Vypíše příkaz tools/clean-work-repos.sh pro dané pracovní repo podle jeho
  # místa v layoutu (gov-repo → gov, migrate-to-github/<key> → migrate <key>);
  # pro cestu mimo layout nevypíše nic.
  # Použití: _gh-work-repo-clean-cmd <repo_dir>
  local _root _key
  _root=$(_gh-work-repos-root)
  case "$1" in
    "$_root/gov-repo") echo "bash tools/clean-work-repos.sh gov" ;;
    "$_root/$_GH_WORK_MIGRATE_SUBDIR"/*)
      _key="${1#"$_root/$_GH_WORK_MIGRATE_SUBDIR/"}"
      [[ -z "$_key" || "$_key" == */* ]] || echo "bash tools/clean-work-repos.sh migrate $_key"
      ;;
  esac
}

_gh-work-repo-error() {
  # Akční hláška po selhání git operace v pracovním repu; opravu (typicky
  # delete + reclone přes tools/clean-work-repos.sh) provádí vždy člověk.
  # Vrací 1, aby šla použít přímo v návratové cestě volajícího.
  # Použití: _gh-work-repo-error <repo_dir> <operace> <detail/výstup gitu>
  local _cmd
  echo "Chyba: Git operace '$2' v pracovním repu '$1' selhala." >&2
  [[ -n "$3" ]] && printf '%s\n' "$3" >&2
  _cmd=$(_gh-work-repo-clean-cmd "$1")
  if [[ -n "$_cmd" ]]; then
    echo "Zkontroluj 'git -C \"$1\" status'. Pokud v klonu není nic, co má platit, smaž ho: $_cmd --apply (rozpracovaný klon smaže jen $_cmd --force --apply) — příští běh si ho naclonuje znovu." >&2
  else
    echo "Zkontroluj 'git -C \"$1\" status'; pokud v repu nejsou rozpracované změny, můžeš adresář smazat a funkce si ho příště naclonuje znovu." >&2
  fi
  return 1
}

_gh-work-repo-clear-index-lock() {
  # Odstraní .git/index.lock po přerušené git operaci. Volá se výhradně pod
  # zámkem pracovního repa — jediný git proces v klonu byl náš a zabil ho
  # signál, lock tedy nikoho nechrání. Vždy vrací 0.
  # Použití: _gh-work-repo-clear-index-lock <repo_dir>
  local _gitdir
  _gitdir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  [[ -e "$_gitdir/index.lock" ]] || return 0
  echo "Odstraňuji osiřelý '$_gitdir/index.lock' (zbytek přerušené git operace; repo je pod zámkem tohoto běhu)." >&2
  rm -f "$_gitdir/index.lock"
  return 0
}

_gh-work-repo-push() {
  # Push pracovního repa. Bez <auth_url> plain push (credential helper;
  # remote-tracking ref posune git sám). S <auth_url> push tokenizovanou URL
  # pouze jako argumentem a ruční posun refs/remotes/origin/<branch>, aby
  # kontrola předstihu při příštím syncu neviděla falešný předstih. Při
  # selhání vypíše na stdout výstup gitu s vymaskovaným tokenem a vrací 1 —
  # volající doplní kontext.
  # Použití: _gh-work-repo-push <repo_dir> [<branch> <auth_url>]
  local _dir="$1" _branch="${2:-}" _auth_url="${3:-}" _out
  if [[ -z "$_auth_url" ]]; then
    _out=$(git -C "$_dir" push -q origin HEAD 2>&1) && return 0
  elif _out=$(git -C "$_dir" push -q "$_auth_url" "HEAD:refs/heads/$_branch" 2>&1); then
    git -C "$_dir" update-ref "refs/remotes/origin/$_branch" HEAD
    return 0
  fi
  _gh-work-repo-mask-auth "$_out" "$_auth_url"
  return 1
}

_gh-work-repo-clone-auth() {
  # Klon s tokenizovanou URL: init + remote origin = <plain_url> + fetch
  # tokenizovanou URL pouze jako argumentem (token nezůstává v .git/config)
  # + checkout větve. Výstup gitu jde na stdout (volající ho maskuje).
  # Použití: _gh-work-repo-clone-auth <tmp_dir> <plain_url> <branch> <auth_url>
  git init -q "$1" 2>&1 \
    && git -C "$1" remote add origin "$2" 2>&1 \
    && git -C "$1" fetch -q "$4" "+refs/heads/$3:refs/remotes/origin/$3" 2>&1 \
    && git -C "$1" checkout -q -b "$3" "origin/$3" 2>&1
}

_gh-work-repo-clone() {
  # První naklonování pracovního repa do <repo_dir>.partial a po úspěchu
  # přesun na <repo_dir> — existence adresáře repa tak vždy znamená úplný
  # klon (částečný klon po zabitém procesu uklidí sync). Bez <auth_url> plain
  # clone (credential helper), s <auth_url> _gh-work-repo-clone-auth.
  # Nedokončený klon se maže — nejde o uživatelská data.
  # Použití: _gh-work-repo-clone <repo_dir> <plain_url> [<branch> <auth_url>]
  local _dir="$1" _url="$2" _branch="${3:-}" _auth_url="${4:-}" _tmp="$1.partial"
  local _out _op _rc
  rm -rf "$_tmp"
  if [[ -z "$_auth_url" ]]; then
    _op="clone"
    _out=$(git clone --quiet "$_url" "$_tmp" 2>&1); _rc=$?
  else
    _op="clone (init + fetch)"
    _out=$(_gh-work-repo-clone-auth "$_tmp" "$_url" "$_branch" "$_auth_url"); _rc=$?
  fi
  if [[ $_rc -eq 0 ]]; then
    _out=$(mv "$_tmp" "$_dir" 2>&1) && return 0
    _op="přesun klonu"
  fi
  rm -rf "$_tmp"
  _gh-work-repo-error "$_dir" "$_op" "$(_gh-work-repo-mask-auth "$_out" "$_auth_url")"
}

_gh-work-repo-check-origin() {
  # Ověří, že adresář je git repo s očekávaným origin.
  # Použití: _gh-work-repo-check-origin <repo_dir> <plain_url>
  local _out
  if ! git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
    _gh-work-repo-error "$1" "kontrola repa" "adresář existuje, ale není git repo"
    return 1
  fi
  _out=$(git -C "$1" remote get-url origin 2>&1)
  if [[ "$_out" != "$2" ]]; then
    _gh-work-repo-error "$1" "kontrola remote" "origin URL '$_out' neodpovídá očekávané '$2'"
    return 1
  fi
}

_gh-work-repo-ensure-clean() {
  # Zajistí čistý pracovní strom. Necommitnuté zbytky jsou vždy vlastní
  # nedokončená transakce (v klonu pracují jen funkce) — vypíší se a zahodí
  # včetně stagenutých a nesledovaných souborů (reset --hard + clean); příští
  # běh výsledek dopočítá znovu z živých dat.
  # Použití: _gh-work-repo-ensure-clean <repo_dir>
  local _dir="$1" _out
  _out=$(git -C "$_dir" status --porcelain 2>&1) || {
    _gh-work-repo-error "$_dir" "status" "$_out"; return 1; }
  [[ -n "$_out" ]] || return 0
  echo "Zahazuji rozpracované změny z přerušeného běhu v pracovním repu '$_dir':" >&2
  printf '%s\n' "$_out" | sed 's/^/  /' >&2
  _out=$(git -C "$_dir" reset -q --hard HEAD 2>&1 && git -C "$_dir" clean -qfd 2>&1) \
    && return 0
  _gh-work-repo-error "$_dir" "zahození změn" "$_out"
}

_gh-work-repo-fetch() {
  # Stáhne stav origin: s <auth_url> jen danou větev tokenizovanou URL jako
  # argumentem (chybový výstup s vymaskovaným tokenem), jinak plain fetch.
  # Použití: _gh-work-repo-fetch <repo_dir> <branch> <auth_url>
  local _out
  if [[ -n "$3" ]]; then
    _out=$(git -C "$1" fetch -q "$3" "+refs/heads/$2:refs/remotes/origin/$2" 2>&1) && return 0
    _gh-work-repo-error "$1" "fetch" "$(_gh-work-repo-mask-auth "$_out" "$3")"
    return 1
  fi
  _out=$(git -C "$1" fetch -q origin 2>&1) && return 0
  _gh-work-repo-error "$1" "fetch" "$_out"
}

_gh-work-repo-push-ahead() {
  # Dopushuje vlastní commity předchozího běhu (origin je po čerstvém fetchi
  # předkem HEAD, push je ff). Selhání je akční chyba — commity zůstávají,
  # příští sync push zopakuje.
  # Použití: _gh-work-repo-push-ahead <repo_dir> <branch> <auth_url> <upstream>
  local _dir="$1" _branch="$2" _auth_url="$3" _upstream="$4" _n _out
  _n=$(git -C "$_dir" rev-list --count "$_upstream..HEAD" 2>/dev/null)
  echo "Pushuji $_n nepushnutý(ch) commit(ů) z předchozího běhu v pracovním repu '$_dir'..." >&2
  if _out=$(_gh-work-repo-push "$_dir" "$_branch" "$_auth_url") \
     && [[ "$(git -C "$_dir" rev-list --count "$_upstream..HEAD" 2>/dev/null)" == 0 ]]; then
    return 0
  fi
  _gh-work-repo-error "$_dir" "push nepushnutých commitů" \
    "${_out:+$_out$'\n'}commity nad $_upstream: $_n (vlastní commity předchozího běhu)."$'\n'"Po odstranění příčiny spusť běh znovu (sync push zopakuje), nebo pushni ručně: git -C \"$_dir\" push origin HEAD${_branch:+:$_branch}"
}

_gh-work-repo-reconcile() {
  # Srovná HEAD s čerstvě staženým origin: shoda → nic; HEAD předek origin →
  # ff merge; origin předek HEAD → push vlastních commitů; divergence → ruční
  # zásah (nic se nepřepisuje).
  # Použití: _gh-work-repo-reconcile <repo_dir> <branch> <auth_url>
  local _dir="$1" _branch="$2" _auth_url="$3" _upstream _up _out
  [[ -n "$_branch" ]] && _upstream="refs/remotes/origin/$_branch" || _upstream="@{u}"
  _up=$(git -C "$_dir" rev-parse "$_upstream" 2>&1) || {
    _gh-work-repo-error "$_dir" "kontrola upstreamu" "$_up"; return 1; }
  [[ "$(git -C "$_dir" rev-parse HEAD 2>/dev/null)" != "$_up" ]] || return 0
  if git -C "$_dir" merge-base --is-ancestor HEAD "$_up" 2>/dev/null; then
    _out=$(git -C "$_dir" merge --ff-only --quiet "$_up" 2>&1) && return 0
    _gh-work-repo-error "$_dir" "merge --ff-only" "$_out"
    return 1
  fi
  if git -C "$_dir" merge-base --is-ancestor "$_up" HEAD 2>/dev/null; then
    _gh-work-repo-push-ahead "$_dir" "$_branch" "$_auth_url" "$_upstream"
    return $?
  fi
  _gh-work-repo-error "$_dir" "kontrola divergence" \
    "lokální HEAD a $_upstream se rozešly (lokálně navíc: $(git -C "$_dir" rev-list --count "$_up..HEAD" 2>/dev/null), na origin navíc: $(git -C "$_dir" rev-list --count "HEAD..$_up" 2>/dev/null)). Prošetři 'git -C \"$_dir\" log --oneline --left-right $_upstream...HEAD'; automaticky se nic nepřepisuje."
}

_gh-work-repo-update() {
  # Aktualizace existujícího pracovního repa: kontrola repa a originu → úklid
  # index.lock → čistý strom (zahození zbytků) → fetch → srovnání s čerstvým origin
  # (ff / push vlastních commitů / divergence = ruční zásah). Kontroly běží až
  # po fetchi, aby už pushnutý commit s neposunutým remote-tracking refem
  # nevypadal jako nepushnutý.
  # Použití: _gh-work-repo-update <repo_dir> <plain_url> [<branch> <auth_url>]
  local _dir="$1" _url="$2" _branch="${3:-}" _auth_url="${4:-}"
  _gh-work-repo-check-origin "$_dir" "$_url" || return 1
  _gh-work-repo-clear-index-lock "$_dir"
  _gh-work-repo-ensure-clean "$_dir" || return 1
  _gh-work-repo-fetch "$_dir" "$_branch" "$_auth_url" || return 1
  _gh-work-repo-reconcile "$_dir" "$_branch" "$_auth_url"
}

_gh-work-repo-sync() {
  # Synchronizuje pracovní repo (životní cyklus dle návrhu): neexistuje →
  # clone, existuje → aktualizace. Osiřelý částečný klon <repo_dir>.partial
  # (zabitý proces během klonu) se smaže — vytvořila ho funkce, není co
  # ztratit. Volá se pod zámkem (_gh-work-repo-lock). S <auth_url> (BB:
  # user:token v URL) se tokenizovaná URL používá výhradně jako argument
  # fetche a pushe — v .git/config zůstává jen <plain_url>.
  # Použití: _gh-work-repo-sync <repo_dir> <plain_url> [<branch> <auth_url>]
  local _dir="$1"
  rm -rf "$_dir.partial"
  if [[ ! -d "$_dir" ]]; then
    _gh-work-repo-clone "$@"
  else
    _gh-work-repo-update "$@"
  fi
}

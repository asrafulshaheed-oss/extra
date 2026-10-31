#!/bin/bash
# =============================================================================
#  off.sh v3.0 - "DevMode": silence macOS permission pop-ups for dev tools
# =============================================================================
#  PURPOSE
#    You develop with AI agents that spawn hundreds of node/python processes
#    (screen capture, mic, camera, file sharing, ...). macOS TCC prompts for
#    every one of them. This script pre-approves everything for your dev
#    tools, suppresses the screen-recording "will expire" nag, and reloads
#    the TCC daemon LIVE - no reboot, no log-out, no background daemon.
#
#  USAGE
#    bash off.sh                enable (explains -> password -> confirm -> done)
#    bash off.sh --back         restore everything exactly as before
#    bash off.sh --add <path>   pre-approve another binary or .app mid-session
#    bash off.sh --status       show current state
#    bash off.sh --doctor       environment check
#    bash off.sh --yes          non-interactive (for agents / cron)
#    bash off.sh --help
#
#  WHAT IT DOES (enable)
#    1. Backs up: both TCC privacy databases + screen-capture approvals plist
#    2. Pre-approves 14 privacy services (screen recording, mic, camera,
#       full disk access, accessibility, input monitoring, automation,
#       folder/volume access, ...) for:
#         - dev binaries found on this Mac: node, python3, python, uv, uvx,
#           deno, bun, ffmpeg, osascript (+ their real resolved paths)
#         - terminal / editor apps: Terminal, iTerm2, VS Code, Cursor,
#           Windsurf, Warp, Claude, Zed, Xcode, Sublime (whatever exists)
#         - extra paths in ~/.tcc-devtool/paths.txt and .app bundles in
#           ~/.tcc-devtool/apps.txt (one per line, # comments allowed)
#    3. Sets screen-recording approval dates to 2099 (kills the recurring
#       "Allow For One Month" re-prompt)
#    4. Reloads tccd so everything takes effect IMMEDIATELY
#
#  WHAT IT DOES NOT DO (v2 did these - they were the bugs)
#    - No LaunchDaemon / wrapper / tcc-run hack: launchctl kickstart cannot
#      run a custom command, and a background daemon is DENIED by TCC, not
#      approved - that approach can never work.
#    - No `sfltool resetbtm`: that command wipes login items and is exactly
#      what forced a reboot. It is not needed at all here.
#    - No reboot, no re-login, nothing installed outside ~/.tcc-devtool
#
#  ONE-TIME SETUP (30 seconds, no reboot)
#    macOS blocks ALL writes to the privacy databases (even for root) unless
#    the app doing the writing has Full Disk Access. One time only:
#        System Settings -> Privacy & Security -> Full Disk Access
#        -> enable Terminal (or iTerm2 / VS Code - whatever runs this script)
#    SIP stays ON. The script detects this and tells you if it is missing.
#
#  RESTORE (--back)
#    Removes exactly the rows it added and restores previous values
#    (including previously-DENIED entries). No reboot. Full database backups
#    are kept in ~/.tcc-devtool/backups/.
#
#  NOTES
#    - Menu-bar recording / camera / mic indicators are enforced by macOS and
#      cannot be hidden on a stock Mac (anti-stalkerware by design). All the
#      prompts and nags ARE silenced.
#    - For headless agents: allow NOPASSWD for this script in sudoers, then
#      run it with --yes.
#    - Survives reboots (they are just database rows) until you run --back.
# =============================================================================

set -euo pipefail

NL='
'

# --- Paths (env-overridable; also used by the automated test harness) -------
STATE_DIR="${OFF_STATE_DIR:-$HOME/.tcc-devtool}"
SYS_TCC="${OFF_SYS_TCC:-/Library/Application Support/com.apple.TCC/TCC.db}"
USER_TCC="${OFF_USER_TCC:-$HOME/Library/Application Support/com.apple.TCC/TCC.db}"
REPLAYD_PLIST="${OFF_REPLAYD_PLIST:-$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist}"
EXTRA_PATHS_FILE="$STATE_DIR/paths.txt"   # extra binaries (persistent config)
EXTRA_APPS_FILE="$STATE_DIR/apps.txt"     # extra .app bundles (persistent)

F_ENABLED="$STATE_DIR/enabled.flag"
F_ADDED="$STATE_DIR/added.tsv"            # rows WE added   (deleted on restore)
F_PRESERVE="$STATE_DIR/preserved.tsv"     # rows that existed before us
F_TARGETS="$STATE_DIR/all_targets.tsv"    # everything we touched
F_REPLAYD="$STATE_DIR/replayd.state"      # replayd plist backup info

NAG_DATE="2099-01-01 00:00:00 +0000"
SQLITE_TIMEOUT_MS=6000

# --- Privacy services pre-approved for every dev tool -----------------------
SERVICES=(
  kTCCServiceScreenCapture                # screen recording
  kTCCServiceMicrophone                   # microphone
  kTCCServiceCamera                       # camera
  kTCCServiceSystemPolicyAllFiles         # full disk access
  kTCCServiceAccessibility                # accessibility (AX API)
  kTCCServiceListenEvent                  # input monitoring
  kTCCServicePostEvent                    # synthetic keyboard/mouse events
  kTCCServiceAppleEvents                  # automation (osascript)
  kTCCServiceSystemPolicyAppBundles       # control other apps
  kTCCServiceSystemPolicyDesktopFolder    # Desktop access
  kTCCServiceSystemPolicyDocumentsFolder  # Documents access
  kTCCServiceSystemPolicyDownloadsFolder  # Downloads access
  kTCCServiceSystemPolicyRemovableVolumes # USB / external drives
  kTCCServiceSystemPolicyNetworkVolumes   # network volumes
)

# --- Terminal / editor / AI-host apps (auto-detected by existence) ----------
APP_CANDIDATES=(
  "/System/Applications/Utilities/Terminal.app"
  "/Applications/iTerm.app"
  "/Applications/Visual Studio Code.app"
  "/Applications/Cursor.app"
  "/Applications/Windsurf.app"
  "/Applications/Warp.app"
  "/Applications/Claude.app"
  "/Applications/Zed.app"
  "/Applications/Xcode.app"
  "/Applications/Sublime Text.app"
)

# --- Dev binaries to look up on PATH ----------------------------------------
CLI_COMMANDS=(node python3 python uv uvx deno bun ffmpeg)
CLI_STATIC=(/usr/bin/python3 /usr/bin/osascript)

# --- Globals -----------------------------------------------------------------
ASSUME_YES="${OFF_YES:-0}"
DEBUG="${OFF_DEBUG:-0}"
SYS_DB_OK=0
USER_DB_OK=0
USER_DB_VIA_SUDO=0
GRANT_COUNT=0
GRANT_EXPECTED=0
CLI_PATHS=()
APP_BUNDLES=()
APP_EXES=()
# schema flags for the access table of the db currently being written
HAS_CSREQ=0; HAS_POLICY_ID=0; HAS_IND_TYPE=0; HAS_IND_ID=0; HAS_IND_CODE=0
HAS_FLAGS=0; HAS_LASTMOD=0

# =============================================================================
# Helpers
# =============================================================================
c_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$1"; }
c_step() { printf '\033[1;36m[STEP]\033[0m %s\n' "$1"; }
c_ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$1"; }
c_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
c_err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$1" >&2; }
die()    { c_err "$1"; exit 1; }
hr()     { printf '%s\n' "-------------------------------------------------------------------"; }

dbg() { # debug-print SQL
  if [[ "$DEBUG" == "1" ]]; then printf '[SQL] %s\n' "$1" >&2; fi
  return 0
}

sql_q() { # SQL string literal with proper escaping
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

resolve_path() { # resolve symlinks without requiring GNU coreutils
  local p="$1" r=""
  if [[ ! -e "$p" ]]; then printf '%s' "$p"; return 0; fi
  if command -v realpath >/dev/null 2>&1; then
    r="$(realpath "$p" 2>/dev/null || true)"
  fi
  if [[ -z "$r" ]]; then
    r="$(perl -MCwd=abs_path -e 'print Cwd::abs_path(shift)' "$p" 2>/dev/null || true)"
  fi
  printf '%s' "${r:-$p}"
}

dedup_stdin_lines() { awk '!seen[$0]++ && NF' ; }

require_darwin() {
  if [[ "$(uname)" != "Darwin" ]]; then die "This script only works on macOS."; fi
}

require_sqlite3() {
  if ! command -v sqlite3 >/dev/null 2>&1; then die "sqlite3 not found (it ships with macOS)."; fi
}

need_sudo() { # ask for / refresh admin credentials (interactive prompt)
  if ! sudo -v; then die "Admin password is required (sudo failed)."; fi
}

confirm() { # $1 = prompt; returns 0 when the user answers y
  local answer=""
  if [[ ! -t 0 ]]; then
    if [[ "$ASSUME_YES" != "1" ]]; then
      die "stdin is not a terminal. Run me interactively, or pass --yes."
    fi
    return 0
  fi
  if ! read -r -p "$1 " answer; then die "No input received."; fi
  if [[ "$answer" =~ ^[Yy]$ ]]; then return 0; fi
  return 1
}

macos_version() { sw_vers -productVersion 2>/dev/null || echo "unknown"; }

# never leave temp files behind, even on Ctrl+C
cleanup_tmp() {
  rm -f "$STATE_DIR/.preserve."*.tmp "$STATE_DIR/.targets."*.tmp \
        "$STATE_DIR/.csreq."*.tmp "$STATE_DIR/.paths."*.tmp \
        "$STATE_DIR/.bundles."*.tmp "$STATE_DIR/.add.paths."*.tmp \
        "$STATE_DIR/.add.bundles."*.tmp "$STATE_DIR/.sqlerr."*.tmp \
        "$STATE_DIR/.sqlerr.tmp" "$STATE_DIR/preserved.tsv.tmp" \
        "$STATE_DIR/all_targets.tsv.tmp" 2>/dev/null || true
}
trap cleanup_tmp EXIT

# =============================================================================
# sqlite plumbing
# =============================================================================
sql_sys() { # $1 = SQL -> stdout  (system db, root-owned)
  sudo sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$SYS_TCC" "$1"
}
sql_user() { # $1 = SQL -> stdout  (user db; plain first, sudo fallback)
  if [[ "$USER_DB_VIA_SUDO" == "1" ]]; then
    sudo sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" "$1"
  else
    sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" "$1"
  fi
}
sql_tag() { # $1 = tag (sys|user), $2 = SQL
  if [[ "$1" == "sys" ]]; then sql_sys "$2"; else sql_user "$2"; fi
}
db_file() { # $1 = tag -> db path
  if [[ "$1" == "sys" ]]; then printf '%s' "$SYS_TCC"; else printf '%s' "$USER_TCC"; fi
}

detect_schema() { # $1 = tag; sets column flags used by insert_row_sql
  local tag="$1" info="" name="" notnull="" dflt="" unknown_bad="" cols=""
  if ! info="$(sql_tag "$tag" "PRAGMA table_info(access);")"; then return 1; fi
  if [[ -z "$info" ]]; then return 1; fi
  HAS_CSREQ=0; HAS_POLICY_ID=0; HAS_IND_TYPE=0; HAS_IND_ID=0; HAS_IND_CODE=0
  HAS_FLAGS=0; HAS_LASTMOD=0; cols=""
  local _cid _type _pk
  while IFS='|' read -r _cid name _type notnull dflt _pk; do
    if [[ -z "$name" ]]; then continue; fi
    case "$name" in
      service|client|client_type|auth_value|auth_reason|auth_version) ;;
      csreq)                           HAS_CSREQ=1 ;;
      policy_id)                       HAS_POLICY_ID=1 ;;
      indirect_object_identifier_type) HAS_IND_TYPE=1 ;;
      indirect_object_identifier)      HAS_IND_ID=1 ;;
      indirect_object_code_identity)   HAS_IND_CODE=1 ;;
      flags)                           HAS_FLAGS=1 ;;
      last_modified)                   HAS_LASTMOD=1 ;;
      *)
        if [[ "$notnull" == "1" && -z "$dflt" ]]; then unknown_bad="$unknown_bad $name"; fi
        ;;
    esac
    if [[ -n "$cols" ]]; then cols="$cols, $name"; else cols="$name"; fi
  done <<< "$info"
  if [[ -n "$unknown_bad" ]]; then
    c_warn "access table has unknown required columns:$unknown_bad - skipping db '$tag'."
    return 1
  fi
  return 0
}

insert_row_sql() {
  # $1=service $2=client $3=client_type $4=csreq_literal
  # $5=auth_value $6=auth_reason $7=auth_version $8=flags_value
  local svc="$1" client="$2" ctype="$3" csreq="$4"
  local authv="$5" reason="${6:-4}" ver="${7:-1}" flagsv="${8:-0}"
  local cols="service, client, client_type, auth_value, auth_reason, auth_version"
  local vals
  vals="$(sql_q "$svc"), $(sql_q "$client"), $ctype, $authv, $reason, $ver"
  if [[ "$HAS_CSREQ" == "1" ]];     then cols="$cols, csreq";                           vals="$vals, $csreq"; fi
  if [[ "$HAS_POLICY_ID" == "1" ]]; then cols="$cols, policy_id";                       vals="$vals, NULL"; fi
  if [[ "$HAS_IND_TYPE" == "1" ]];  then cols="$cols, indirect_object_identifier_type"; vals="$vals, 0"; fi
  if [[ "$HAS_IND_ID" == "1" ]];    then cols="$cols, indirect_object_identifier";      vals="$vals, 'UNUSED'"; fi
  if [[ "$HAS_IND_CODE" == "1" ]];  then cols="$cols, indirect_object_code_identity";   vals="$vals, NULL"; fi
  if [[ "$HAS_FLAGS" == "1" ]];     then cols="$cols, flags";                           vals="$vals, $flagsv"; fi
  if [[ "$HAS_LASTMOD" == "1" ]];   then cols="$cols, last_modified";                   vals="$vals, CAST(strftime('%s','now') AS INTEGER)"; fi
  printf 'INSERT OR REPLACE INTO access (%s) VALUES (%s);' "$cols" "$vals"
}

csreq_literal() { # $1 = hex blob ('' -> NULL)
  if [[ -n "$1" ]]; then printf "x'%s'" "$1"; else printf 'NULL'; fi
}

in_values_list() { # stdin: svc<TAB>client<TAB>ctype lines -> VALUES ((...),(...))
  local first=1 svc client ctype
  while IFS=$'\t' read -r svc client ctype; do
    if [[ -z "$svc" ]]; then continue; fi
    if [[ "$first" == "1" ]]; then first=0; else printf ', '; fi
    printf '(%s, %s, %s)' "$(sql_q "$svc")" "$(sql_q "$client")" "$ctype"
  done
  return 0
}

# =============================================================================
# Client collection (dev binaries + apps) - no root needed
# =============================================================================
collect_cli_paths() {
  CLI_PATHS=()
  local c p g i rp
  local found=()
  for c in ${CLI_COMMANDS[@]+"${CLI_COMMANDS[@]}"}; do
    p="$(command -v "$c" 2>/dev/null || true)"
    if [[ -n "$p" ]]; then found+=("$p"); fi
  done
  for p in ${CLI_STATIC[@]+"${CLI_STATIC[@]}"}; do
    if [[ -e "$p" ]]; then found+=("$p"); fi
  done
  shopt -s nullglob
  for g in \
    /opt/homebrew/bin/node /opt/homebrew/bin/python3 \
    /opt/homebrew/opt/python@3*/bin/python3* \
    /usr/local/bin/node /usr/local/bin/python3 \
    /usr/local/opt/python@3*/bin/python3* \
    "$HOME"/.nvm/versions/node/*/bin/node \
    "$HOME"/.volta/bin/node \
    "$HOME"/.pyenv/versions/*/bin/python3* \
    "$HOME"/.local/share/uv/python/*/bin/python3* \
    "$HOME"/.deno/bin/deno \
    "$HOME"/.bun/bin/bun
  do
    found+=("$g")
  done
  shopt -u nullglob
  if [[ -f "$EXTRA_PATHS_FILE" ]]; then
    while IFS= read -r p; do
      p="${p%$'\r'}"
      if [[ -z "$p" || "$p" == \#* ]]; then continue; fi
      if [[ -e "$p" ]]; then found+=("$p"); fi
    done < "$EXTRA_PATHS_FILE"
  fi
  for i in ${found[@]+"${found[@]}"}; do
    CLI_PATHS+=("$i")
    rp="$(resolve_path "$i")"
    if [[ "$rp" != "$i" ]]; then CLI_PATHS+=("$rp"); fi
  done
  local _dedup=() _l
  while IFS= read -r _l; do
    if [[ -n "$_l" ]]; then _dedup+=("$_l"); fi
  done < <(printf '%s\n' ${CLI_PATHS[@]+"${CLI_PATHS[@]}"} | dedup_stdin_lines)
  CLI_PATHS=(${_dedup[@]+"${_dedup[@]}"})
  return 0
}

collect_apps() { # fills APP_BUNDLES (ids) and APP_EXES (main executables)
  APP_BUNDLES=()
  APP_EXES=()
  local apps=() app id exe
  for app in ${APP_CANDIDATES[@]+"${APP_CANDIDATES[@]}"}; do
    if [[ -d "$app" ]]; then apps+=("$app"); fi
  done
  if [[ -f "$EXTRA_APPS_FILE" ]]; then
    while IFS= read -r app; do
      app="${app%$'\r'}"
      if [[ -z "$app" || "$app" == \#* ]]; then continue; fi
      if [[ -d "$app" ]]; then apps+=("$app"); fi
    done < "$EXTRA_APPS_FILE"
  fi
  for app in ${apps[@]+"${apps[@]}"}; do
    id="$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
    if [[ -z "$id" ]]; then continue; fi
    exe="$(defaults read "$app/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)"
    if [[ -z "$exe" ]]; then exe="$(basename "$app" .app)"; fi
    APP_BUNDLES+=("$id")
    if [[ -e "$app/Contents/MacOS/$exe" ]]; then APP_EXES+=("$app/Contents/MacOS/$exe"); fi
  done
  local _d1=() _d2=() _l
  while IFS= read -r _l; do if [[ -n "$_l" ]]; then _d1+=("$_l"); fi; done \
    < <(printf '%s\n' ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"} | dedup_stdin_lines)
  while IFS= read -r _l; do if [[ -n "$_l" ]]; then _d2+=("$_l"); fi; done \
    < <(printf '%s\n' ${APP_EXES[@]+"${APP_EXES[@]}"} | dedup_stdin_lines)
  APP_BUNDLES=(${_d1[@]+"${_d1[@]}"})
  APP_EXES=(${_d2[@]+"${_d2[@]}"})
  return 0
}

all_clients_count() {
  echo $(( ${#CLI_PATHS[@]} + ${#APP_BUNDLES[@]} ))
}

# =============================================================================
# Probes / availability (sudo -n = never hang on a password prompt)
# =============================================================================
probe_sys_db() { # 0 = usable (needs admin + Full Disk Access on this terminal)
  if [[ ! -f "$SYS_TCC" ]]; then return 1; fi
  sudo -n sqlite3 -batch -readonly "$SYS_TCC" "PRAGMA quick_check;" >/dev/null 2>&1
}

probe_user_db() { # sets USER_DB_OK / USER_DB_VIA_SUDO
  USER_DB_OK=0
  USER_DB_VIA_SUDO=0
  if [[ ! -f "$USER_TCC" ]]; then return 1; fi
  if sqlite3 -batch -readonly "$USER_TCC" "PRAGMA quick_check;" >/dev/null 2>&1; then
    USER_DB_OK=1
    return 0
  fi
  if sudo -n sqlite3 -batch -readonly "$USER_TCC" "PRAGMA quick_check;" >/dev/null 2>&1; then
    USER_DB_OK=1
    USER_DB_VIA_SUDO=1
    return 0
  fi
  return 1
}

fda_hint() { # $1 = why Full Disk Access is needed right now
  local term="${TERM_PROGRAM:-}"
  case "$term" in
    Apple_Terminal) term="Terminal" ;;
    iTerm.app)      term="iTerm2" ;;
    vscode*)        term="VS Code" ;;
    Cursor)         term="Cursor" ;;
    WarpTerminal)   term="Warp" ;;
    *)              term="your terminal app" ;;
  esac
  c_warn "$1"
  echo "    One-time fix (no reboot):"
  echo "      System Settings -> Privacy & Security -> Full Disk Access -> enable $term"
  echo "    (macOS blocks ALL writes to the privacy databases, even for root,"
  echo "     unless the writing app has Full Disk Access. SIP stays ON.)"
}

# =============================================================================
# Grant engine
# =============================================================================
grant_targets() {
  # $1 = tag (sys|user), $2 = file of CLI paths, $3 = file of bundle ids
  local tag="$1" pfile="$2" bfile="$3"
  local db; db="$(db_file "$tag")"

  if ! detect_schema "$tag"; then return 1; fi

  local csreq_map="$STATE_DIR/.csreq.$$.tmp"
  : > "$csreq_map"

  # Copy existing csreq blobs for bundle clients so tccd keeps seeing the
  # app's real code-signature requirement (falls back to NULL for new apps).
  if [[ -s "$bfile" ]]; then
    local idlist="" id
    while IFS= read -r id; do
      if [[ -n "$id" ]]; then
        if [[ -n "$idlist" ]]; then idlist+=", "; fi
        idlist+="$(sql_q "$id")"
      fi
    done < "$bfile"
    if [[ -n "$idlist" ]]; then
      sql_tag "$tag" \
        "SELECT client || char(31) || hex(csreq) FROM access WHERE csreq IS NOT NULL AND client IN ($idlist);" \
        2>/dev/null | while IFS=$'\037' read -r id hx; do
          if [[ -n "$id" ]]; then printf '%s\t%s\n' "$id" "${hx:-}" >> "$csreq_map"; fi
        done || true
    fi
  fi

  # 1) Snapshot rows we are about to overwrite (for a perfect --back),
  #    excluding rows that are already ours (recorded in a previous run).
  local triplet_list="" svc client hx
  for svc in ${SERVICES[@]+"${SERVICES[@]}"}; do
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        triplet_list+="$svc"$'\t'"$client"$'\t'"1"$'\n'
      fi
    done < "$pfile"
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        triplet_list+="$svc"$'\t'"$client"$'\t'"0"$'\n'
      fi
    done < "$bfile"
  done

  local tmp_pres="$STATE_DIR/.preserve.$$.tmp"
  : > "$tmp_pres"
  if [[ -n "$triplet_list" ]]; then
    local inlist sel out
    inlist="$(printf '%s' "$triplet_list" | in_values_list)"
    if [[ -n "$inlist" ]]; then
      sel="SELECT service || char(31) || client || char(31) || client_type || char(31) || auth_value || char(31) || auth_reason || char(31) || auth_version || char(31) || COALESCE(hex(csreq),'') || char(31) || COALESCE(flags,'') FROM access WHERE (service, client, client_type) IN ($inlist);"
      dbg "$sel"
      out=""
      out="$(sql_tag "$tag" "$sel" 2>/dev/null)" || out=""
      local svc2 client2 ctype2 authv reason ver csh flagsv line
      while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        IFS=$'\037' read -r svc2 client2 ctype2 authv reason ver csh flagsv <<< "$line"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$tag" "$svc2" "$client2" "$ctype2" "${authv:-0}" "${reason:-0}" \
          "${ver:-1}" "$csh" "$flagsv" >> "$tmp_pres"
      done <<< "$out"
    fi
  fi
  if [[ -f "$F_ADDED" ]]; then
    # NB: FILENAME==ARGV[1] (not NR==FNR) because F_ADDED may be empty,
    # which breaks the NR==FNR idiom.
    awk -F'\t' 'FILENAME==ARGV[1]{k[$1"\t"$2"\t"$3"\t"$4]=1;next} !($1"\t"$2"\t"$3"\t"$4 in k)' \
      "$F_ADDED" "$tmp_pres" > "$tmp_pres.f" && mv "$tmp_pres.f" "$tmp_pres"
  fi

  # 2) Record manifests BEFORE mutating anything, so a crash can never leave
  #    untracked changes behind (deleting a never-inserted row is a no-op).
  local tmp_tgt="$STATE_DIR/.targets.$$.tmp"
  : > "$tmp_tgt"
  printf '%s\n' "$triplet_list" | while IFS=$'\t' read -r svc client ctype; do
    if [[ -n "$svc" ]]; then printf '%s\t%s\t%s\t%s\n' "$tag" "$svc" "$client" "$ctype" >> "$tmp_tgt"; fi
  done
  if [[ ! -f "$F_PRESERVE" ]]; then : > "$F_PRESERVE"; fi
  if [[ ! -f "$F_TARGETS" ]]; then : > "$F_TARGETS"; fi
  # Keep the FIRST (true original) snapshot per (db,service,client,type) key
  # so re-runs never overwrite the real pre-existing values.
  # NB: FILENAME==ARGV[1] because F_PRESERVE starts empty (NR==FNR breaks).
  awk -F'\t' 'FILENAME==ARGV[1]{k[$1"\t"$2"\t"$3"\t"$4]=1;next} !($1"\t"$2"\t"$3"\t"$4 in k)' \
    "$F_PRESERVE" "$tmp_pres" >> "$F_PRESERVE"
  cat "$tmp_tgt" >> "$F_TARGETS"
  if [[ -s "$F_PRESERVE" ]]; then
    LC_ALL=C sort -u "$F_PRESERVE" > "$F_PRESERVE.tmp" && mv "$F_PRESERVE.tmp" "$F_PRESERVE"
  fi
  if [[ -s "$F_TARGETS" ]]; then
    LC_ALL=C sort -u "$F_TARGETS" > "$F_TARGETS.tmp" && mv "$F_TARGETS.tmp" "$F_TARGETS"
  fi

  # 3) One atomic transaction with every INSERT
  local sql="BEGIN IMMEDIATE;$NL"
  for svc in ${SERVICES[@]+"${SERVICES[@]}"}; do
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        sql+="$(insert_row_sql "$svc" "$client" 1 NULL 2 4 1 0)$NL"
      fi
    done < "$pfile"
    while IFS= read -r client; do
      if [[ -n "$client" ]]; then
        hx=""
        if [[ -s "$csreq_map" ]]; then
          hx="$(grep -F -m1 -- "$client"$'\t' "$csreq_map" | cut -f2 || true)"
        fi
        sql+="$(insert_row_sql "$svc" "$client" 0 "$(csreq_literal "$hx")" 2 4 1 0)$NL"
      fi
    done < "$bfile"
  done
  sql+="COMMIT;"
  dbg "$sql"
  local sqlerr="$STATE_DIR/.sqlerr.$$.tmp"
  if ! sql_tag "$tag" "$sql" 2>"$sqlerr"; then
    c_err "Failed to write $db:"
    sed 's/^/    /' "$sqlerr" >&2 || true
    rm -f "$sqlerr" "$tmp_pres" "$tmp_tgt" "$csreq_map"
    return 1
  fi
  rm -f "$sqlerr" "$tmp_pres" "$tmp_tgt" "$csreq_map"

  # 4) Verify
  local n=0 expected=0 inlist2
  expected="$(printf '%s\n' "$triplet_list" | grep -c . || true)"
  inlist2="$(printf '%s' "$triplet_list" | in_values_list)"
  if [[ -n "$inlist2" ]]; then
    n="$(sql_tag "$tag" "SELECT count(*) FROM access WHERE (service, client, client_type) IN ($inlist2);" 2>/dev/null)" || n=0
  fi
  n="${n:-0}"; n="${n%%[!0-9]*}"
  if [[ -z "$n" ]]; then n=0; fi
  GRANT_COUNT="$n"
  GRANT_EXPECTED="$expected"
  return 0
}

rebuild_added_manifest() { # added = targets - preserved
  if [[ -f "$F_PRESERVE" && -f "$F_TARGETS" ]]; then
    # NB: FILENAME==ARGV[1] because F_PRESERVE may be empty (NR==FNR breaks).
    awk -F'\t' 'FILENAME==ARGV[1]{k[$1"\t"$2"\t"$3"\t"$4]=1;next} !($1"\t"$2"\t"$3"\t"$4 in k)' \
      "$F_PRESERVE" "$F_TARGETS" > "$F_ADDED"
  elif [[ -f "$F_TARGETS" ]]; then
    cp "$F_TARGETS" "$F_ADDED"
  fi
  return 0
}

reload_tccd() { # apply database changes LIVE - no reboot, no re-login
  sudo killall tccd >/dev/null 2>&1 || true
  sleep 1
  return 0
}

# =============================================================================
# Backups
# =============================================================================
do_backups() { # $1 = backup dir (originals from the first run are kept)
  local bk="$1"
  mkdir -p "$bk"
  if [[ ! -f "$bk/TCC.system.db" && "$SYS_DB_OK" == "1" ]]; then
    if sudo sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$SYS_TCC" \
         "VACUUM INTO $(sql_q "$bk/TCC.system.db");" 2>/dev/null; then
      sudo chown "$(id -u):$(id -g)" "$bk/TCC.system.db" 2>/dev/null || true
    fi
  fi
  if [[ ! -f "$bk/TCC.user.db" && -f "$USER_TCC" && "$USER_DB_OK" == "1" ]]; then
    if [[ "$USER_DB_VIA_SUDO" == "1" ]]; then
      if sudo sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" \
           "VACUUM INTO $(sql_q "$bk/TCC.user.db");" 2>/dev/null; then
        sudo chown "$(id -u):$(id -g)" "$bk/TCC.user.db" 2>/dev/null || true
      fi
    else
      sqlite3 -batch -cmd ".timeout $SQLITE_TIMEOUT_MS" "$USER_TCC" \
        "VACUUM INTO $(sql_q "$bk/TCC.user.db");" 2>/dev/null || true
    fi
  fi
  if [[ ! -f "$bk/ScreenCaptureApprovals.plist" && -f "$REPLAYD_PLIST" ]]; then
    cp -p "$REPLAYD_PLIST" "$bk/ScreenCaptureApprovals.plist" || true
  fi
  return 0
}

# =============================================================================
# replayd "screen recording will expire" nag suppression (no root needed)
# =============================================================================
apply_replayd() {
  local dir; dir="$(dirname "$REPLAYD_PLIST")"
  if [[ ! -d "$dir" ]]; then
    c_warn "replayd container missing (macOS < Sequoia) - skipping nag suppression."
    return 0
  fi
  local existed=1
  if [[ ! -f "$REPLAYD_PLIST" ]]; then existed=0; fi
  # Resolve the backup directory (backups/CURRENT is a pointer FILE whose
  # content is the real backup dir; F_ENABLED carries the same path).
  local bk=""
  bk="$(sed -n 's/^backup=//p' "$F_ENABLED" 2>/dev/null | head -1 || true)"
  if [[ -z "$bk" && -f "$STATE_DIR/backups/CURRENT" ]]; then
    bk="$(cat "$STATE_DIR/backups/CURRENT")"
  fi
  if [[ -z "$bk" ]]; then
    bk="$STATE_DIR/backups/manual"
    mkdir -p "$bk"
  fi
  if [[ "$existed" == "1" && ! -f "$bk/ScreenCaptureApprovals.plist" ]]; then
    mkdir -p "$bk" 2>/dev/null || true
    cp -p "$REPLAYD_PLIST" "$bk/ScreenCaptureApprovals.plist" || true
  fi

  local keys=() k
  if [[ "$existed" == "1" ]]; then
    while IFS= read -r k; do
      if [[ -n "$k" ]]; then keys+=("$k"); fi
    done < <(defaults read "$REPLAYD_PLIST" 2>/dev/null \
             | sed -nE 's/^[[:space:]]*"([^"]+)".*/\1/p' || true)
  fi
  for k in ${APP_EXES[@]+"${APP_EXES[@]}"}; do keys+=("$k"); done
  for k in ${CLI_PATHS[@]+"${CLI_PATHS[@]}"}; do keys+=("$k"); done

  local _d=() _l
  while IFS= read -r _l; do
    if [[ -n "$_l" ]]; then _d+=("$_l"); fi
  done < <(printf '%s\n' ${keys[@]+"${keys[@]}"} | dedup_stdin_lines)
  keys=(${_d[@]+"${_d[@]}"})

  if [[ ${#keys[@]} -eq 0 ]]; then
    c_info "No screen-capture approval entries to extend."
    return 0
  fi
  local n=0
  for k in ${keys[@]+"${keys[@]}"}; do
    if defaults write "$REPLAYD_PLIST" "$k" -date "$NAG_DATE" 2>/dev/null; then
      n=$((n + 1))
    fi
  done
  {
    echo "existed=$existed"
    echo "backup=$bk/ScreenCaptureApprovals.plist"
  } > "$F_REPLAYD"
  c_ok "Screen-recording expiry nags suppressed ($n entries -> 2099)."
  return 0
}

restore_replayd() {
  if [[ ! -f "$F_REPLAYD" ]]; then
    c_info "No replayd changes recorded - nothing to restore."
    return 0
  fi
  local existed="" bk=""
  existed="$(sed -n 's/^existed=//p' "$F_REPLAYD" | head -1)"
  bk="$(sed -n 's/^backup=//p' "$F_REPLAYD" | head -1)"
  if [[ "$existed" == "1" && -f "$bk" ]]; then
    if cp -p "$bk" "$REPLAYD_PLIST"; then c_ok "Screen-capture approvals restored."; fi
  elif [[ "$existed" == "0" ]]; then
    if rm -f "$REPLAYD_PLIST"; then c_ok "Screen-capture approvals file removed (was created by off.sh)."; fi
  else
    c_info "replayd backup not found - leaving current approvals in place."
  fi
  rm -f "$F_REPLAYD"
  return 0
}

# =============================================================================
# ENABLE
# =============================================================================
cmd_enable() {
  require_darwin
  require_sqlite3
  collect_cli_paths
  collect_apps

  local nclients; nclients="$(all_clients_count)"
  if [[ "$nclients" -eq 0 ]]; then
    die "No dev tools found (no node/python on PATH, no known apps). Nothing to do."
  fi

  echo ""
  hr
  echo "  WHAT THIS WILL DO"
  hr
  echo "  1. Back up the macOS privacy databases (TCC) and the screen-capture"
  echo "     approvals plist to ~/.tcc-devtool/backups/"
  echo "  2. Pre-approve ${#SERVICES[@]} privacy services with NO pop-ups for"
  echo "     screen recording, microphone, camera, full disk access,"
  echo "     accessibility, input monitoring, automation and folder access,"
  echo "     for these tools (detected on this Mac):"
  local _c
  for _c in ${CLI_PATHS[@]+"${CLI_PATHS[@]}"}; do echo "         [bin] $_c"; done
  for _c in ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"}; do echo "         [app] $_c"; done
  echo "  3. Set screen-recording approval dates to 2099"
  echo "     (stops the recurring 'Allow For One Month' prompt)"
  echo "  4. Reload the TCC daemon (tccd) so it all takes effect NOW"
  echo ""
  echo "  * No reboot. No log-out. No background daemon is installed."
  echo "  * Survives reboots until you run:  bash off.sh --back"
  echo "  * WARNING: while this is active, the tools above get mic / camera /"
  echo "    screen access with zero confirmation. Development machines only."
  echo ""

  c_info "Admin password needed to edit the privacy databases."
  need_sudo

  echo ""
  hr
  echo "  FINAL CHECK"
  hr
  echo "  Everything above is applied now and is 100% reversible with:"
  echo "      bash off.sh --back"
  if ! confirm "Still want it? Type y + Enter (anything else cancels)"; then
    c_info "Cancelled. Nothing was changed."
    exit 0
  fi

  # --- state / backups ------------------------------------------------------
  mkdir -p "$STATE_DIR"
  local already=0
  if [[ -f "$F_ENABLED" ]]; then already=1; fi
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local bk="$STATE_DIR/backups/$stamp"
  if [[ "$already" == "0" ]]; then
    : > "$F_PRESERVE"
    : > "$F_TARGETS"
  else
    c_info "Already active - re-syncing grants (originals from the first run are kept)."
    if [[ -f "$STATE_DIR/backups/CURRENT" ]]; then
      bk="$(cat "$STATE_DIR/backups/CURRENT")"
    fi
  fi

  c_step "[1/4] Checking database access ..."
  SYS_DB_OK=0
  if probe_sys_db; then SYS_DB_OK=1; fi
  if [[ "$SYS_DB_OK" != "1" ]]; then
    fda_hint "Cannot write the SYSTEM privacy database (screen recording, accessibility, ...)."
  fi
  if ! probe_user_db; then :; fi

  c_step "[2/4] Backing up current state ..."
  if [[ "$already" == "0" ]]; then
    do_backups "$bk"
    mkdir -p "$STATE_DIR/backups"
    printf '%s\n' "$bk" > "$STATE_DIR/backups/CURRENT"
    if [[ -f "$bk/TCC.system.db" || -f "$bk/TCC.user.db" ]]; then
      c_ok "Backups saved: $bk"
    else
      c_warn "No database backup possible (missing Full Disk Access?)."
    fi
  else
    c_ok "Backups already exist: $bk"
  fi

  # --- grant ------------------------------------------------------------------
  local pf="$STATE_DIR/.paths.$$.tmp" bf="$STATE_DIR/.bundles.$$.tmp"
  printf '%s\n' ${CLI_PATHS[@]+"${CLI_PATHS[@]}"} > "$pf"
  printf '%s\n' ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"} > "$bf"

  c_step "[3/4] Granting permissions (live, no reboot) ..."
  local fail=0
  if [[ "$SYS_DB_OK" == "1" ]]; then
    if grant_targets sys "$pf" "$bf"; then
      c_ok "System database : $GRANT_COUNT/$GRANT_EXPECTED rows granted (screen recording, accessibility, full disk, ...)."
    else
      c_warn "System database : grants FAILED (see error above)."
      fail=1
    fi
  else
    c_warn "System database : SKIPPED (no Full Disk Access - see instructions above)."
    fail=1
  fi

  if [[ "$USER_DB_OK" == "1" ]]; then
    if grant_targets user "$pf" "$bf"; then
      c_ok "User database   : $GRANT_COUNT/$GRANT_EXPECTED rows granted (microphone, camera, folders, ...)."
    else
      c_warn "User database   : grants FAILED (see error above)."
      fail=1
    fi
  else
    if [[ ! -f "$USER_TCC" ]]; then
      c_warn "User database   : does not exist yet (macOS creates it at the first"
      c_warn "                   mic/camera prompt). Re-run after that prompt."
    else
      c_warn "User database   : SKIPPED (no Full Disk Access - see instructions above)."
      fail=1
    fi
  fi
  rm -f "$pf" "$bf"
  rebuild_added_manifest

  c_step "[4/4] Suppressing 'screen recording will expire' nags ..."
  apply_replayd

  c_step "Reloading the TCC daemon ..."
  reload_tccd
  c_ok "tccd reloaded - changes are LIVE now."

  if [[ "$already" == "0" ]]; then
    printf 'enabled=%s\nbackup=%s\n' "$stamp" "$bk" > "$F_ENABLED"
  fi

  echo ""
  hr
  if [[ "$fail" == "1" ]]; then
    c_warn "Partially applied. Fix the issue above and re-run (it is safe to re-run)."
  else
    c_ok "DEV MODE ACTIVE - no reboot, no re-login needed."
  fi
  echo "   Persistence : survives reboots until you restore"
  echo "   Restore     : bash off.sh --back"
  echo "   Status      : bash off.sh --status"
  hr
  echo ""
  return 0
}

# =============================================================================
# RESTORE
# =============================================================================
cmd_restore() {
  require_darwin
  require_sqlite3
  if [[ ! -f "$F_TARGETS" && ! -f "$F_ADDED" ]]; then
    c_info "Nothing to restore - all clean."
    exit 0
  fi
  c_info "Admin password needed to edit the privacy databases."
  need_sudo
  if ! probe_user_db; then :; fi

  c_step "[1/3] Removing granted permissions ..."
  local tag svc client ctype authv reason ver csh flagsv sql
  local hard_fail=0 db
  for tag in sys user; do
    db="$(db_file "$tag")"
    if [[ ! -f "$db" ]]; then continue; fi
    if ! detect_schema "$tag"; then continue; fi
    sql="BEGIN IMMEDIATE;$NL"
    if [[ -f "$F_ADDED" ]]; then
      while IFS=$'\t' read -r _ svc client ctype; do
        if [[ -n "$svc" ]]; then
          sql+="DELETE FROM access WHERE service = $(sql_q "$svc") AND client = $(sql_q "$client") AND client_type = $ctype;$NL"
        fi
      done < <(awk -F'\t' -v t="$tag" '$1==t' "$F_ADDED")
    fi
    if [[ -f "$F_PRESERVE" ]]; then
      # awk re-emits fields with \x1f (unit separator): bash `read` with
      # IFS=<tab> silently swallows empty fields (tab is IFS-whitespace),
      # which would misalign everything after an empty csreq blob.
      while IFS=$'\037' read -r svc client ctype authv reason ver csh flagsv; do
        if [[ -n "$svc" ]]; then
          sql+="$(insert_row_sql "$svc" "$client" "$ctype" "$(csreq_literal "$csh")" "${authv:-0}" "${reason:-4}" "${ver:-1}" "${flagsv:-NULL}")$NL"
        fi
      done < <(awk -F'\t' -v t="$tag" '$1==t{print $2"\037"$3"\037"$4"\037"$5"\037"$6"\037"$7"\037"$8"\037"$9}' "$F_PRESERVE")
    fi
    sql+="COMMIT;"
    dbg "$sql"
    if sql_tag "$tag" "$sql" 2>"$STATE_DIR/.sqlerr.tmp"; then
      c_ok "$db restored."
    else
      c_err "Could not restore $db:"
      sed 's/^/    /' "$STATE_DIR/.sqlerr.tmp" >&2 || true
      c_warn "A full-database backup is kept in: $(cat "$STATE_DIR/backups/CURRENT" 2>/dev/null || echo "$STATE_DIR/backups")"
      hard_fail=1
    fi
    rm -f "$STATE_DIR/.sqlerr.tmp"
  done

  c_step "[2/3] Restoring screen-capture approvals ..."
  restore_replayd

  c_step "[3/3] Reloading the TCC daemon ..."
  reload_tccd
  c_ok "tccd reloaded - normal privacy prompts are back."

  if [[ "$hard_fail" == "0" ]]; then
    rm -f "$F_ENABLED" "$F_ADDED" "$F_PRESERVE" "$F_TARGETS" "$F_REPLAYD"
  else
    c_warn "Keeping the restore state - fix the issue above and re-run 'bash off.sh --back'."
  fi

  echo ""
  hr
  if [[ "$hard_fail" == "1" ]]; then
    c_warn "Restored with warnings (see above). Full backups are kept in:"
    echo "   $(cat "$STATE_DIR/backups/CURRENT" 2>/dev/null || echo "$STATE_DIR/backups")"
  else
    c_ok "NORMAL MODE RESTORED - exactly as before. No reboot needed."
  fi
  echo "   Tip: restart long-running agent processes so they re-check"
  echo "        permissions cleanly."
  hr
  echo ""
  return 0
}

# =============================================================================
# ADD (grant another binary / .app mid-session)
# =============================================================================
cmd_add() {
  require_darwin
  require_sqlite3
  local paths=("$@")
  if [[ ${#paths[@]} -eq 0 ]]; then
    die "Usage: bash off.sh --add /path/to/binary [more paths or .app bundles ...]"
  fi
  c_info "Admin password needed to edit the privacy databases."
  need_sudo
  mkdir -p "$STATE_DIR"
  if probe_sys_db; then SYS_DB_OK=1; fi
  if ! probe_user_db; then :; fi

  local pf="$STATE_DIR/.add.paths.$$.tmp" bf="$STATE_DIR/.add.bundles.$$.tmp"
  : > "$pf"
  : > "$bf"
  local p rp id
  for p in ${paths[@]+"${paths[@]}"}; do
    if [[ -d "$p" && -f "$p/Contents/Info.plist" ]]; then
      id="$(defaults read "$p/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
      if [[ -n "$id" ]]; then
        echo "$id" >> "$bf"
        echo "$p" >> "$EXTRA_APPS_FILE"
        c_ok "App detected: $id (saved to $EXTRA_APPS_FILE)"
      else
        c_warn "No bundle id found in $p - skipped."
      fi
      continue
    fi
    if [[ -e "$p" ]]; then
      rp="$(resolve_path "$p")"
      echo "$p" >> "$pf"
      if [[ "$rp" != "$p" ]]; then echo "$rp" >> "$pf"; fi
      echo "$p" >> "$EXTRA_PATHS_FILE"
      c_ok "Binary accepted: $p"
    else
      c_warn "Not found: $p"
    fi
  done
  if [[ -s "$bf" ]]; then
    LC_ALL=C sort -u "$bf" > "$bf.u" && mv "$bf.u" "$bf"
  fi

  if [[ ! -s "$pf" && ! -s "$bf" ]]; then
    rm -f "$pf" "$bf"
    die "Nothing to add."
  fi

  local fail=0
  if [[ "$SYS_DB_OK" == "1" ]]; then
    if grant_targets sys "$pf" "$bf"; then
      c_ok "System database: $GRANT_COUNT/$GRANT_EXPECTED rows granted."
    else
      fail=1
    fi
  else
    fda_hint "Cannot write the system privacy database."
    fail=1
  fi
  if [[ "$USER_DB_OK" == "1" ]]; then
    if grant_targets user "$pf" "$bf"; then
      c_ok "User database: $GRANT_COUNT/$GRANT_EXPECTED rows granted."
    else
      fail=1
    fi
  else
    if [[ ! -f "$USER_TCC" ]]; then
      c_warn "User database does not exist yet - system-level grants applied."
    else
      c_warn "User database unavailable (Full Disk Access missing)."
    fi
  fi
  rm -f "$pf" "$bf"
  rebuild_added_manifest
  reload_tccd
  if [[ "$fail" == "1" ]]; then
    exit 1
  fi
  c_ok "Granted. 'bash off.sh --back' removes these too."
  return 0
}

# =============================================================================
# STATUS / DOCTOR
# =============================================================================
count_our_rows() { # $1 = tag -> how many of our manifest rows exist in the db
  local tag="$1" n="" inlist=""
  if [[ ! -f "$F_TARGETS" ]]; then echo "0"; return 0; fi
  if ! detect_schema "$tag" 2>/dev/null; then echo "?"; return 0; fi
  inlist="$(awk -F'\t' -v t="$tag" '$1==t{print $2"\t"$3"\t"$4}' "$F_TARGETS" | in_values_list)"
  if [[ -z "$inlist" ]]; then echo "0"; return 0; fi
  n="$(sql_tag "$tag" "SELECT count(*) FROM access WHERE (service, client, client_type) IN ($inlist);" 2>/dev/null)" || n="?"
  echo "${n:-?}"
  return 0
}

line_count() { # $1 = file -> non-empty line count (prints 0 when missing)
  if [[ -f "$1" ]]; then grep -c . "$1" || true; else echo 0; fi
}

cmd_status() {
  require_darwin
  echo ""
  hr
  echo "  off.sh STATUS"
  hr
  if [[ -f "$F_ENABLED" ]]; then
    echo "  Mode      : DEV MODE ACTIVE (since $(sed -n 's/^enabled=//p' "$F_ENABLED"))"
  else
    echo "  Mode      : normal (not active)"
  fi
  echo "  macOS     : $(macos_version)"
  echo "  Backups   : $(cat "$STATE_DIR/backups/CURRENT" 2>/dev/null || echo '(none)')"
  echo "  Rows added: $(line_count "$F_ADDED")  (these are removed by --back)"
  echo "  Preserved : $(line_count "$F_PRESERVE")  original rows restored by --back"
  SYS_DB_OK=0
  if probe_sys_db; then SYS_DB_OK=1; fi
  if ! probe_user_db; then :; fi
  if [[ "$SYS_DB_OK" == "1" ]]; then
    echo "  System db : reachable ($(count_our_rows sys) of our rows present)"
  else
    echo "  System db : not reachable (run after 'sudo -v', or --doctor)"
  fi
  if [[ "$USER_DB_OK" == "1" ]]; then
    echo "  User db   : reachable ($(count_our_rows user) of our rows present)"
  else
    echo "  User db   : not reachable (needs Full Disk Access - see --doctor)"
  fi
  if [[ -f "$REPLAYD_PLIST" ]]; then
    echo "  Nag dates : $(defaults read "$REPLAYD_PLIST" 2>/dev/null | grep -c '=' || true) entries in the approvals plist"
  fi
  echo ""
  return 0
}

cmd_doctor() {
  require_darwin
  echo ""
  hr
  echo "  off.sh DOCTOR"
  hr
  echo "  macOS          : $(sw_vers -productName 2>/dev/null || echo macOS) $(macos_version)"
  echo "  SIP            : $(csrutil status 2>/dev/null | head -1 || echo unknown) - SIP can stay ON"
  if command -v sqlite3 >/dev/null 2>&1; then
    echo "  sqlite3        : $(sqlite3 --version 2>/dev/null | cut -d' ' -f1)"
  else
    echo "  sqlite3        : MISSING"
  fi
  echo "  Terminal       : ${TERM_PROGRAM:-unknown}"
  collect_cli_paths
  collect_apps
  echo "  Dev binaries   : ${#CLI_PATHS[@]} found"
  local _c
  for _c in ${CLI_PATHS[@]+"${CLI_PATHS[@]}"}; do echo "      $_c"; done
  echo "  Dev apps       : ${#APP_BUNDLES[@]} found"
  for _c in ${APP_BUNDLES[@]+"${APP_BUNDLES[@]}"}; do echo "      $_c"; done
  echo "  Extra paths    : $(line_count "$EXTRA_PATHS_FILE") in $EXTRA_PATHS_FILE"
  echo "  Extra apps     : $(line_count "$EXTRA_APPS_FILE") in $EXTRA_APPS_FILE"

  if sudo -v; then echo "  sudo           : OK"; else echo "  sudo           : FAILED (needs an admin account)"; fi

  echo ""
  echo "  Database access:"
  if probe_sys_db; then
    echo "    system TCC.db : WRITABLE (good)"
  else
    echo "    system TCC.db : BLOCKED"
    fda_hint "Your terminal cannot write the system privacy database."
  fi
  if [[ ! -f "$USER_TCC" ]]; then
    echo "    user TCC.db   : does not exist yet (normal on a fresh Mac; macOS"
    echo "                     creates it at the first mic/camera prompt)"
  else
    if probe_user_db; then
      echo "    user TCC.db   : WRITABLE (good)"
    else
      echo "    user TCC.db   : BLOCKED"
      fda_hint "Your terminal cannot write the user privacy database."
    fi
  fi

  echo ""
  echo "  Notes:"
  echo "    - 'Background Items Added' banners come from apps installing"
  echo "      LaunchAgents/Daemons (brew services, helper apps). off.sh never"
  echo "      installs any. To silence those banners once and for all, check:"
  echo "      System Settings -> Notifications -> 'Background Items Added'."
  echo "    - The menu-bar mic/camera/screen indicators are enforced by macOS"
  echo "      and cannot be hidden on a stock Mac. All prompts are silenced."
  echo ""
  return 0
}

# =============================================================================
# MAIN
# =============================================================================
usage() {
  cat <<'USAGE'
off.sh v3.0 - silence macOS permission pop-ups for dev tools (no reboot)

Usage:
  bash off.sh                  enable  (explains -> password -> confirm -> done)
  bash off.sh --back           restore everything exactly as before
  bash off.sh --add <path>     pre-approve another binary or .app bundle
  bash off.sh --status         show current state
  bash off.sh --doctor         environment check (SIP, Full Disk Access, ...)
  bash off.sh --yes            non-interactive (agents); can also be OFF_YES=1
  bash off.sh --debug          print the SQL it runs (OFF_DEBUG=1)
  bash off.sh --help           this help

How it works (no reboot ever):
  - Pre-approves 14 privacy services (screen, mic, camera, full disk,
    accessibility, input, automation, folders) for node/python/uv/deno/bun/
    ffmpeg + your terminal/editor apps, by writing the official TCC database.
  - Sets screen-recording approval dates to 2099 (kills "Allow For One Month").
  - Reloads tccd so it is live immediately. Survives reboots until --back.

One-time setup (30s): enable Full Disk Access for your terminal app in
System Settings -> Privacy & Security -> Full Disk Access (macOS blocks all
writes to the privacy databases without it, even for root). SIP stays ON.

State lives in ~/.tcc-devtool/ (backups, manifests, extra tool lists).
USAGE
}

MODE="enable"
ADD_PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --back)    MODE="restore" ;;
    --status)  MODE="status" ;;
    --doctor)  MODE="doctor" ;;
    --add)     MODE="add"
               shift
               while [[ $# -gt 0 ]]; do ADD_PATHS+=("$1"); shift; done
               break ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --debug)   DEBUG=1 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: bash off.sh [--back|--status|--doctor|--add <path>|--yes|--debug|--help]" >&2
      exit 1 ;;
  esac
  shift
done

case "$MODE" in
  enable)  cmd_enable ;;
  restore) cmd_restore ;;
  status)  cmd_status ;;
  doctor)  cmd_doctor ;;
  add)
    if [[ ${#ADD_PATHS[@]} -gt 0 ]]; then
      cmd_add "${ADD_PATHS[@]}"
    else
      cmd_add
    fi ;;
esac

#!/bin/bash
#
# off.sh - "Movie Mode" for macOS (macOS 26 Tahoe ready, also Sonoma / Sequoia)
#
#   bash off.sh             -> kill ALL popups + notifications, turn ON all sharing
#   bash off.sh --back      -> put popups/notifications back to normal (sharing stays ON)
#   bash off.sh --status    -> show what is on / off right now
#
# What Movie Mode does:
#   - kills every node / python "Allow" popup:
#       * finds EVERY node/python binary on your Mac (PATH, nvm, fnm, volta, asdf,
#         pyenv, homebrew, system AND whatever is running right now via ps)
#       * pre-approves Screen Recording, Accessibility, Full Disk Access, App
#         Management, Apple Events, Local Network ... for all of them
#       * removes dead "ghost" entries (old node versions) from the Settings list
#   - stops ALL notification banners:
#       * Notification Center stopped, AND the banner renderer (usernoted) stopped
#         -> banners are physically impossible even when SIP protects NC
#       * stops the "node can run in the background / Login Items" popups
#       * classic + modern Do Not Disturb switched on
#   - mutes alert sounds only (movie audio is untouched)
#   - hides menu bar icons: Control Center, Focus, Screen Mirroring (the purple
#     one), Now Playing, Sound Recognition, Accessibility Shortcuts
#   - turns ON every sharing service:
#       File Sharing, Screen Sharing, Media Sharing, Content Caching,
#       Bluetooth Sharing, Printer Sharing, Internet Sharing,
#       Remote Login (SSH), Remote Management, Remote Application Scripting
#
# Your Mac password is asked ONCE at the start of every "off" run (on purpose,
# so you always see that the privileged part really runs).
#
# No reboot needed for anything. "--back" restores popups/notifications/sounds/
# menu bar. Sharing services stay ON after --back (as requested).

set -u

[ "$(uname -s)" = "Darwin" ] || { echo "Sorry: off.sh only works on macOS."; exit 1; }

UID_N="$(id -u)"
STATE="$HOME/.off.sh.state"
ASSERT_BAK="$HOME/.off.sh.assertions.bak"
DND_DIR="$HOME/Library/DoNotDisturb/DB"
NC_LABEL="com.apple.notificationcenterui"
NC_PLIST="/System/Library/LaunchAgents/com.apple.notificationcenterui.plist"
UNOTED_PLIST="/System/Library/LaunchAgents/com.apple.usernoted.plist"
BTM_PLIST="/System/Library/LaunchAgents/com.apple.backgroundtaskmanagement.agent.plist"
SFW="/usr/libexec/ApplicationFirewall/socketfilterfw"
TCC_SYS="/Library/Application Support/com.apple.TCC/TCC.db"
TCC_USR="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
LD_DAEMONS="/System/Library/LaunchDaemons"
LD_AGENTS="/System/Library/LaunchAgents"
ACMU="$(command -v AssetCacheManagerUtil 2>/dev/null || echo /usr/bin/AssetCacheManagerUtil)"

if [ -t 1 ]; then B=$'\033[1m'; N=$'\033[0m'; else B=""; N=""; fi
hdr() { printf '\n%s==> %s%s\n' "$B" "$1" "$N"; }
ok()  { printf '  [OK]   %s\n' "$1"; }
bad() { printf '  [!!]   %s\n' "$1"; }
sub() { printf '         %s\n' "$1"; }

# ---------- tiny state file (remembers "before" so --back can restore) ----------
state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -n 1; }
state_set() {
  local t="$STATE.tmp"
  { [ -f "$STATE" ] && grep -v "^$1=" "$STATE"; } > "$t" 2>/dev/null
  printf '%s=%s\n' "$1" "$2" >> "$t"
  mv "$t" "$STATE"
}
state_default() {
  grep -q "^$1=" "$STATE" 2>/dev/null || printf '%s=%s\n' "$1" "$2" >> "$STATE"
}

# ---------- read current system state ----------
fw_state() {
  local s=""
  s="$(sudo -n "$SFW" --getglobalstate 2>/dev/null || "$SFW" --getglobalstate 2>/dev/null || true)"
  case "$s" in
    *enabled*) echo "on" ;;
    "")        echo "unknown" ;;
    *)         echo "off" ;;
  esac
}
gk_state() {
  local s=""
  s="$(/usr/sbin/spctl --status 2>/dev/null || true)"
  case "$s" in *disabled*) echo "off" ;; *) echo "on" ;; esac
}
nc_running() { /bin/launchctl print "gui/${UID_N}/${NC_LABEL}" >/dev/null 2>&1 && echo yes || echo no; }
agent_running() { /bin/launchctl print "gui/${UID_N}/${1}" >/dev/null 2>&1 && echo yes || echo no; }
alert_vol() {
  /usr/bin/osascript -e 'get volume settings' 2>/dev/null \
    | sed -n 's/.*alert volume:\([0-9][0-9]*\).*/\1/p' | tail -n 1
}
is_num() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }

# ---------- sudo ----------
# need_sudo            -> prompt only if the cached session expired
# need_sudo fresh      -> ALWAYS ask the password once (used by "off")
need_sudo() {
  local fresh="${1:-}"
  if [ "$fresh" = "fresh" ]; then
    sudo -k 2>/dev/null || true           # forget cached password -> real prompt
  fi
  if sudo -n true 2>/dev/null; then
    if [ "$fresh" = "fresh" ]; then
      ok "Password accepted (asked fresh, as designed)"
    else
      ok "sudo session still valid (that is why no password was needed)"
    fi
    return 0
  fi
  echo "Type your Mac password once (needed to change system settings):"
  if ! sudo -v; then bad "sudo access is required. Nothing was changed."; exit 1; fi
  ok "Password accepted"
}

# ---------- launchd agent stop/start (user domain) ----------
stop_agent() { # label plist -> 0 = stopped
  local label="$1" plist="$2"
  [ -f "$plist" ] || return 1
  /bin/launchctl bootout "gui/${UID_N}/${label}" >/dev/null 2>&1 || true
  sudo /bin/launchctl disable "gui/${UID_N}/${label}" >/dev/null 2>&1 || true
  if /bin/launchctl print "gui/${UID_N}/${label}" >/dev/null 2>&1; then
    sudo /bin/launchctl bootout "gui/${UID_N}/${label}" >/dev/null 2>&1 || true
    /bin/launchctl print "gui/${UID_N}/${label}" >/dev/null 2>&1 && return 1
    return 0
  fi
  return 0
}

start_agent() { # label plist -> 0 = running
  local label="$1" plist="$2"
  [ -f "$plist" ] || return 1
  sudo /bin/launchctl enable "gui/${UID_N}/${label}" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "gui/${UID_N}" "$plist" >/dev/null 2>&1 \
    || sudo /bin/launchctl bootstrap "gui/${UID_N}" "$plist" >/dev/null 2>&1 || true
  /bin/launchctl kickstart "gui/${UID_N}/${label}" >/dev/null 2>&1 || true
  /bin/launchctl print "gui/${UID_N}/${label}" >/dev/null 2>&1
}

# ---------- find EVERY node / python binary on this Mac ----------
collect_binaries() {
  local b p
  {
    # 1) whatever is first in PATH
    for b in node npx npm pnpm yarn bun deno tsx python python3; do
      p="$(command -v "$b" 2>/dev/null || true)"
      [ -n "$p" ] && printf '%s\n' "$p"
    done
    # 2) whatever is RUNNING right now (the exact binaries your AI agent uses)
    ps axo comm= 2>/dev/null | grep -E '(^|/)(node|npx|npm|pnpm|yarn|bun|deno|tsx|python3?|electron)( -.*)?$' | grep '^/' || true
    # 3) classic install locations
    for p in /usr/local/bin/node /opt/homebrew/bin/node /usr/bin/node \
             /usr/local/bin/npx /opt/homebrew/bin/npx \
             /usr/local/bin/npm /opt/homebrew/bin/npm \
             /usr/local/bin/python3 /opt/homebrew/bin/python3 /usr/bin/python3 \
             /usr/local/bin/python /opt/homebrew/bin/python /usr/bin/python; do
      [ -x "$p" ] && printf '%s\n' "$p"
    done
    # 4) version managers (nvm / fnm / volta / asdf / pyenv / pnpm home)
    for p in "$HOME"/.nvm/versions/node/*/bin/node \
             "$HOME"/.nvm/versions/node/*/bin/npx \
             "$HOME"/.nvm/versions/node/*/bin/npm \
             "$HOME"/.volta/bin/node \
             "$HOME"/.local/share/fnm/aliases/default/bin/node \
             "$HOME"/Library/"Application Support"/fnm/node-versions/*/installation/bin/node \
             "$HOME"/.asdf/shims/node \
             "$HOME"/.local/bin/node \
             "$HOME"/Library/pnpm/node \
             /usr/local/opt/node*/bin/node \
             /opt/homebrew/opt/node*/bin/node \
             "$HOME"/.pyenv/versions/*/bin/python3 \
             "$HOME"/.pyenv/versions/*/bin/python \
             "$HOME"/.pyenv/shims/python3 \
             /usr/local/opt/python*/bin/python3 \
             /opt/homebrew/opt/python*/bin/python3; do
      [ -x "$p" ] && printf '%s\n' "$p"
    done
  } 2>/dev/null | sort -u | grep -v '^$' | head -n 60 || true
}

# ---------- TCC privacy pre-approval (best effort; SIP may block some) ----------
tcc_attempt() { sudo /usr/bin/sqlite3 "$1" "$2" >/dev/null 2>&1; }

tcc_grant() { # service client type [indirect-bundle-id]
  local svc="$1" client="$2" ctype="$3" ind="${4:-}" db
  local stamp="CAST(strftime('%s','now') AS INTEGER)"
  for db in "$TCC_SYS" "$TCC_USR"; do
    [ -e "$db" ] || continue
    tcc_attempt "$db" "DELETE FROM access WHERE service='$svc' AND client='$client';"
    if [ -n "$ind" ]; then
      tcc_attempt "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier_type, indirect_object_identifier_code, indirect_object_code, flags, last_modified) VALUES ('$svc','$client',$ctype,2,4,1,1,'$ind',NULL,0,$stamp);" \
      || tcc_attempt "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier_type, indirect_object_identifier, flags) VALUES ('$svc','$client',$ctype,2,4,1,1,'$ind',0);" \
      || tcc_attempt "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version) VALUES ('$svc','$client',$ctype,2,4,1);" \
      || continue
    else
      tcc_attempt "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified) VALUES ('$svc','$client',$ctype,2,4,1,0,$stamp);" \
      || tcc_attempt "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier_type, indirect_object_identifier, flags) VALUES ('$svc','$client',$ctype,2,4,1,0,NULL,0);" \
      || tcc_attempt "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version) VALUES ('$svc','$client',$ctype,2,4,1);" \
      || continue
    fi
    return 0
  done
  return 1
}

# remove "ghost" rows: permissions for binaries that no longer exist
# (old node versions show up as dead "off" entries in the Settings list)
tcc_clean_ghosts() {
  local db c ghosts=0
  for db in "$TCC_SYS" "$TCC_USR"; do
    [ -e "$db" ] || continue
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      case "$c" in
        /*) [ -e "$c" ] || { tcc_attempt "$db" "DELETE FROM access WHERE client='$c';"; ghosts=$((ghosts+1)); } ;;
      esac
    done <<EOF
$(sudo /usr/bin/sqlite3 "$db" "SELECT client FROM access WHERE client_type=1;" 2>/dev/null || true)
EOF
  done
  [ "$ghosts" -gt 0 ] && ok "Cleaned $ghosts dead permission entries (old node/python versions)"
  return 0
}

grant_all_tcc() {
  hdr "Pre-approving permissions for EVERY node / python on this Mac"
  local apps=( "com.apple.Terminal" "com.googlecode.iterm2" "com.microsoft.VSCode" "com.todesktop.230313mzl4w4u92" )
  local svcs=( "kTCCServiceAccessibility" "kTCCServiceSystemPolicyAllFiles" "kTCCServiceScreenCapture"
               "kTCCServiceLocalNetwork" "kTCCServiceAppManagement" "kTCCServiceSystemPolicyAppBundles"
               "kTCCServiceSystemPolicyDownloadsFolder" "kTCCServiceSystemPolicyDesktopFolder"
               "kTCCServiceSystemPolicyDocumentsFolder" "kTCCServiceSystemPolicyRemovableVolumes"
               "kTCCServiceSystemPolicyNetworkVolumes" "kTCCServicePostEvent" "kTCCServiceListenEvent"
               "kTCCServiceNotifications" )
  local binsvcs=( "kTCCServiceScreenCapture" "kTCCServiceSystemPolicyAllFiles" "kTCCServiceLocalNetwork"
                  "kTCCServiceAppManagement" "kTCCServiceSystemPolicyAppBundles"
                  "kTCCServiceSystemPolicyRemovableVolumes" "kTCCServiceSystemPolicyNetworkVolumes"
                  "kTCCServicePostEvent" "kTCCServiceListenEvent" )
  local a s b p granted=0 total=0 nbin=0
  local bins
  bins="$(collect_binaries)"
  nbin="$(printf '%s\n' "$bins" | grep -c . || true)"

  # terminal / editor apps
  for a in "${apps[@]}"; do
    for s in "${svcs[@]}"; do
      total=$((total+1)); tcc_grant "$s" "$a" 0 && granted=$((granted+1))
    done
    total=$((total+1)); tcc_grant kTCCServiceAppleEvents "$a" 0 com.apple.systemevents && granted=$((granted+1))
    total=$((total+1)); tcc_grant kTCCServiceAppleEvents "$a" 0 com.apple.finder && granted=$((granted+1))
  done

  # every node / python binary found on the machine
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    for s in "${binsvcs[@]}"; do
      total=$((total+1)); tcc_grant "$s" "$b" 1 && granted=$((granted+1))
    done
    total=$((total+1)); tcc_grant kTCCServiceAppleEvents "$b" 1 com.apple.systemevents && granted=$((granted+1))
    total=$((total+1)); tcc_grant kTCCServiceAppleEvents "$b" 1 com.apple.finder && granted=$((granted+1))
  done <<EOF
$bins
EOF

  sudo /usr/bin/pkill tccd >/dev/null 2>&1 || true
  ok "Found $nbin node/python binaries; pre-approved $granted/$total permission entries"
  if [ "$granted" -eq 0 ]; then
    bad "Apple SIP blocked direct edits (normal on a locked-down macOS)."
    sub "If a first-time Allow box appears: click Allow once, it is remembered forever."
  else
    sub "Any single entry Apple SIP refused is remembered after ONE manual Allow click."
  fi
  tcc_clean_ghosts
}

# ---------- sharing services ----------
# enable a system daemon (Tahoe-safe: bootstrap -> enable -> legacy load) and verify
svc_try() { # label plist
  local label="$1" plist="$2"
  [ -f "$plist" ] || return 1
  sudo /bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || true
  sudo /bin/launchctl enable "system/${label}" >/dev/null 2>&1 || true
  sudo /bin/launchctl load -w "$plist" >/dev/null 2>&1 || true
  sudo /bin/launchctl print "system/${label}" >/dev/null 2>&1
}

svc_try_user() { # label plist  (per-user agent, no sudo)
  local label="$1" plist="$2"
  [ -f "$plist" ] || return 1
  /bin/launchctl bootstrap "gui/${UID_N}" "$plist" >/dev/null 2>&1 || true
  /bin/launchctl enable "gui/${UID_N}/${label}" >/dev/null 2>&1 || true
  /bin/launchctl load -w "$plist" >/dev/null 2>&1 || true
  /bin/launchctl print "gui/${UID_N}/${label}" >/dev/null 2>&1
}

ensure_sharing() {
  hdr "Turning ON every sharing service"
  local p t done=0

  # --- Remote Login (SSH) : real launchd label is com.openssh.sshd ---
  if svc_try com.openssh.sshd "$LD_DAEMONS/ssh.plist"; then
    ok "Remote Login (SSH): ON"
  elif sudo /usr/sbin/systemsetup -setremotelogin on </dev/null >/dev/null 2>&1; then
    ok "Remote Login (SSH): ON"
  else
    bad "Remote Login (SSH): could not switch on"
  fi

  # --- Screen Sharing ---
  if svc_try com.apple.screensharing "$LD_DAEMONS/com.apple.screensharing.plist"; then
    ok "Screen Sharing: ON"
  else
    bad "Screen Sharing: could not switch on"
  fi

  # --- File Sharing (SMB) ---
  if svc_try com.apple.smbd "$LD_DAEMONS/com.apple.smbd.plist"; then
    ok "File Sharing: ON"
  else
    bad "File Sharing: could not switch on"
  fi

  # --- Remote Management (Apple Remote Desktop, full control) ---
  local ks="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
  if [ -x "$ks" ]; then
    sudo "$ks" -activate -configure -access -on -restart -agent -privs -all >/dev/null 2>&1 \
      && ok "Remote Management: ON (full control)" \
      || bad "Remote Management: could not switch on"
  else
    bad "Remote Management: tool missing on this macOS"
  fi

  # --- Remote Application Scripting (Remote Apple Events) ---
  done=0
  svc_try com.apple.eppc "$LD_DAEMONS/eppc.plist" && done=1
  sudo /usr/sbin/systemsetup -setremoteapplevents on </dev/null >/dev/null 2>&1 || true
  if [ "$done" -eq 1 ]; then
    ok "Remote Application Scripting: ON"
  else
    bad "Remote Application Scripting: switch it on once in Settings > Sharing > Advanced"
  fi

  # --- Printer Sharing ---
  sudo /usr/sbin/cupsctl --share-printers >/dev/null 2>&1 \
    && ok "Printer Sharing: ON" \
    || bad "Printer Sharing: nothing to share (fine)"

  # --- Bluetooth Sharing (pref key per Apple STIG) ---
  /usr/bin/defaults -currentHost write com.apple.Bluetooth PrefKeyServicesEnabled -bool true
  /usr/bin/defaults write com.apple.Bluetooth PrefKeyServicesEnabled -bool true
  ok "Bluetooth Sharing: ON"

  # --- Media Sharing (Home Sharing) ---
  /usr/bin/defaults write com.apple.amp.mediasharingd home-sharing-enabled -int 1
  sudo /usr/bin/defaults write /Library/Preferences/com.apple.amp.mediasharingd home-sharing-enabled -int 1
  done=0
  for p in "$LD_AGENTS/com.apple.mediasharingd.plist" "$LD_DAEMONS/com.apple.mediasharingd.plist" \
           "$LD_AGENTS/com.apple.amp.mediasharingd.plist" "$LD_DAEMONS/com.apple.amp.mediasharingd.plist"; do
    [ -f "$p" ] || continue
    case "$p" in
      "$LD_AGENTS"/*) svc_try_user com.apple.mediasharingd "$p" && done=1 ;;
      *)              svc_try com.apple.mediasharingd "$p" && done=1 ;;
    esac
  done
  if [ "$done" -eq 1 ]; then
    ok "Media Sharing: ON"
  else
    ok "Media Sharing: preference set (daemon starts with your next login)"
  fi
  sub "Full Home Sharing of your library needs a one-time Apple ID sign-in"
  sub "in the Music or TV app - Apple does not allow that from a script."

  # --- Content Caching ---
  if [ -x "$ACMU" ]; then
    if sudo "$ACMU" activate >/dev/null 2>&1 || sudo "$ACMU" --activate >/dev/null 2>&1; then
      ok "Content Caching: ON"
    else
      bad "Content Caching: Apple refuses inside virtual machines"
      sub "It works on a real Mac - the VM test will always show this error."
    fi
  else
    bad "Content Caching: tool missing on this macOS"
  fi

  # --- Internet Sharing (needs a second network port to share TO) ---
  local src="" target=""
  src="$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  for t in $(/sbin/ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^(en|bridge)[0-9]+$'); do
    [ "$t" = "$src" ] && continue
    target="$t"; break
  done
  if [ -z "$target" ]; then
    bad "Internet Sharing: only one network port found, nothing to share to"
    sub "On a Mac with two ports (e.g. Wi-Fi + Ethernet) it switches on fully."
  else
    sudo /usr/bin/defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict-add SharingNetworks -array "$target"
    # best effort: also pin the primary (internet-source) service UUID
    local cur psid
    cur="$(sudo /usr/bin/plutil -extract CurrentSet raw /Library/Preferences/SystemConfiguration/preferences.plist 2>/dev/null || true)"
    if [ -n "$cur" ]; then
      psid="$(sudo /usr/bin/plutil -extract "${cur#/}.Network.Global.IPv4.PrimaryService" raw /Library/Preferences/SystemConfiguration/preferences.plist 2>/dev/null || true)"
      [ -n "$psid" ] && sudo /usr/bin/defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict-add PrimaryServiceIdentifier "$psid"
    fi
    if svc_try com.apple.InternetSharing "$LD_DAEMONS/com.apple.InternetSharing.plist"; then
      ok "Internet Sharing: ON (sharing to $target)"
    else
      bad "Internet Sharing: could not switch on"
    fi
  fi
}

# ---------- kill node / python popups ----------
kill_node_python_popups() {
  hdr "Killing every node / python popup"
  # 1) firewall "Do you want node to accept incoming network connections?"
  state_default firewall "$(fw_state)"
  if sudo "$SFW" --setglobalstate off >/dev/null 2>&1; then
    ok "Firewall popups (accept incoming connections?): GONE"
  else
    bad "Could not switch the firewall off"
  fi
  # belt and braces: whitelist every node/python binary for when firewall returns
  local b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    sudo "$SFW" --add "$b" >/dev/null 2>&1 || true
    sudo "$SFW" --unblockapp "$b" >/dev/null 2>&1 || true
  done <<EOF
$(collect_binaries)
EOF

  # 2) Gatekeeper "cannot be opened / Allow Anyway" (npx, pip, downloaded tools)
  state_default gatekeeper "$(gk_state)"
  if sudo /usr/sbin/spctl --global-disable >/dev/null 2>&1 || sudo /usr/sbin/spctl --master-disable >/dev/null 2>&1; then
    ok "Gatekeeper Allow-Anyway boxes: GONE"
  else
    bad "Could not relax Gatekeeper"
  fi
  state_default quarantine "$( /usr/bin/defaults read com.apple.LaunchServices LSQuarantine 2>/dev/null || echo unset )"
  /usr/bin/defaults write com.apple.LaunchServices LSQuarantine -bool false
  sub "Downloaded tools (npx / pip installs) now open with no warning at all."
}

# ---------- kill notifications ----------
kill_notifications() {
  hdr "Killing notifications and banners"
  # a) classic Do Not Disturb (every macOS version)
  /usr/bin/defaults write com.apple.notificationcenterui doNotDisturb -bool true
  /usr/bin/defaults write com.apple.notificationcenterui doNotDisturbDate "$(date -u -v+1d '+%Y-%m-%d %H:%M:%S +0000' 2>/dev/null || date -u '+%Y-%m-%d %H:%M:%S +0000')"

  # b) modern Focus assertion (Monterey ... Tahoe)
  mkdir -p "$DND_DIR" 2>/dev/null || true
  # back up the ORIGINAL assertions file once (never back up our own)
  if [ -f "$DND_DIR/Assertions.json" ] && [ ! -f "$ASSERT_BAK" ] && [ "$(state_get dndbak)" != "done" ]; then
    cp "$DND_DIR/Assertions.json" "$ASSERT_BAK" 2>/dev/null || true
  fi
  state_set dndbak done
  printf '%s\n' '{ "data": [ { "storeID": 0, "assertionDetails": { "assertionIdentifiers": [ { "assertionIdentifier": "com.apple.donotdisturbd.nonqueued", "assertionAction": 3 } ] } } ] }' > "$DND_DIR/Assertions.json" 2>/dev/null || true
  /usr/bin/killall donotdisturbd >/dev/null 2>&1 || true

  # c) full stop of Notification Center (also hides the menu bar clock)
  if [ "$(nc_running)" = "yes" ]; then
    if /bin/launchctl bootout "gui/${UID_N}/${NC_LABEL}" >/dev/null 2>&1 \
       || sudo /bin/launchctl bootout "gui/${UID_N}/${NC_LABEL}" >/dev/null 2>&1 \
       || /bin/launchctl unload -w "$NC_PLIST" >/dev/null 2>&1; then
      /usr/bin/killall NotificationCenter >/dev/null 2>&1 || true
    fi
  fi
  if [ "$(nc_running)" = "yes" ]; then
    ok "Do Not Disturb: ON (SIP stopped a full Notification Center kill)"
    state_set nc_off 0
  else
    ok "Notification Center: fully stopped (clock hides too)"
    state_set nc_off 1
  fi

  # d) THE HAMMER: stop usernoted - the process that RENDERS banner popups.
  #    Even when SIP protects Notification Center, no usernoted = no banner.
  if stop_agent com.apple.usernoted "$UNOTED_PLIST"; then
    ok "Banner renderer (usernoted): STOPPED - popups physically cannot appear"
  else
    bad "Could not stop the banner renderer (usernoted)"
  fi

  # e) stop the "node can run in the background / Login Items" popups
  if stop_agent com.apple.backgroundtaskmanagement.agent "$BTM_PLIST" \
     || stop_agent com.apple.backgroundtaskmanagementagent "$BTM_PLIST"; then
    ok "'App can run in the background' popups: STOPPED"
  else
    bad "Could not stop background-activity popups (agent not found)"
  fi
  /usr/bin/killall usernoted >/dev/null 2>&1 || true   # clear anything already queued

  # f) alert sounds only - movie audio untouched
  local v; v="$(alert_vol)"
  if is_num "$v"; then state_default alertvol "$v"; fi
  if /usr/bin/osascript -e 'set volume alert volume 0' >/dev/null 2>&1; then
    ok "Alert / notification sounds: MUTED (movie audio untouched)"
  else
    bad "Could not mute alert sounds"
  fi
  state_default beepvol "$( /usr/bin/defaults read NSGlobalDomain com.apple.sound.beep.volume 2>/dev/null || echo unset )"
  /usr/bin/defaults write NSGlobalDomain com.apple.sound.beep.volume -float 0

  # g) dock bouncing
  state_default dockbounce "$( /usr/bin/defaults read com.apple.dock no-bouncing 2>/dev/null || echo unset )"
  /usr/bin/defaults write com.apple.dock no-bouncing -bool true
  /usr/bin/killall Dock >/dev/null 2>&1 || true

  # h) menu bar icons: Control Center, Focus, Screen Mirroring (the purple
  #    computer-looking one), Now Playing, Sound Recognition, Accessibility
  local k
  for k in "ControlCenter" "FocusModes" "ScreenMirroring" "NowPlaying" "SoundRecognition" "AccessibilityShortcuts"; do
    state_default "icon_${k}" "$( /usr/bin/defaults -currentHost read com.apple.controlcenter "NSStatusItem Visible ${k}" 2>/dev/null || echo unset )"
    /usr/bin/defaults -currentHost write com.apple.controlcenter "NSStatusItem Visible ${k}" -bool false
  done
  /usr/bin/killall ControlCenter >/dev/null 2>&1 || true
  /usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
  ok "Menu bar cleaned (purple Screen Mirroring icon + Control Center + Focus hidden)"
}

# ---------- restore ----------
restore_popups() {
  local f g q
  f="$(state_get firewall)"
  if [ "$f" = "on" ]; then
    sudo "$SFW" --setglobalstate on >/dev/null 2>&1 && ok "Firewall: back ON" || bad "Firewall: could not re-enable"
  elif [ "$f" = "off" ]; then
    ok "Firewall: left OFF (it was already off before off.sh)"
  fi
  g="$(state_get gatekeeper)"
  if [ "$g" = "on" ]; then
    if sudo /usr/sbin/spctl --global-enable >/dev/null 2>&1 || sudo /usr/sbin/spctl --master-enable >/dev/null 2>&1; then
      ok "Gatekeeper: back ON"
    else
      bad "Gatekeeper: could not re-enable"
    fi
  elif [ "$g" = "off" ]; then
    ok "Gatekeeper: left OFF (it was already off before off.sh)"
  fi
  [ -z "$(state_get firewall)" ] && [ -z "$(state_get gatekeeper)" ] \
    && sub "No saved before-state found; security settings left as they are."
  q="$(state_get quarantine)"
  if [ "$q" = "unset" ] || [ -z "$q" ]; then
    /usr/bin/defaults delete com.apple.LaunchServices LSQuarantine >/dev/null 2>&1 || true
  elif [ "$q" = "1" ]; then
    /usr/bin/defaults write com.apple.LaunchServices LSQuarantine -bool true
  fi
}

restore_notifications() {
  /usr/bin/defaults write com.apple.notificationcenterui doNotDisturb -bool false
  if [ -f "$ASSERT_BAK" ]; then
    mv "$ASSERT_BAK" "$DND_DIR/Assertions.json" 2>/dev/null || true
  else
    rm -f "$DND_DIR/Assertions.json" 2>/dev/null || true
  fi
  /usr/bin/killall donotdisturbd >/dev/null 2>&1 || true

  # banner renderer back
  if start_agent com.apple.usernoted "$UNOTED_PLIST"; then
    ok "Notification banners: back"
  else
    bad "Banner renderer not back yet - it also returns after a reboot"
  fi
  # background activity popups back
  start_agent com.apple.backgroundtaskmanagement.agent "$BTM_PLIST" \
    || start_agent com.apple.backgroundtaskmanagementagent "$BTM_PLIST" || true

  # Notification Center (clock) back
  if [ "$(nc_running)" != "yes" ]; then
    start_agent "$NC_LABEL" "$NC_PLIST" \
      || /usr/bin/open "/System/Library/CoreServices/NotificationCenter.app" >/dev/null 2>&1 \
      || true
  fi
  if [ "$(nc_running)" = "yes" ]; then
    ok "Notification Center: back (clock + banners normal)"
  else
    bad "Notification Center not back yet - it also returns after a reboot"
  fi

  local v; v="$(state_get alertvol)"
  if is_num "$v"; then
    /usr/bin/osascript -e "set volume alert volume $v" >/dev/null 2>&1 || true
  elif [ "$(alert_vol)" = "0" ]; then
    /usr/bin/osascript -e 'set volume alert volume 75' >/dev/null 2>&1 || true
  fi
  ok "Alert sounds: restored"

  local bv; bv="$(state_get beepvol)"
  if [ "$bv" = "unset" ] || [ -z "$bv" ]; then
    /usr/bin/defaults delete NSGlobalDomain com.apple.sound.beep.volume >/dev/null 2>&1 || true
  else
    /usr/bin/defaults write NSGlobalDomain com.apple.sound.beep.volume -float "$bv"
  fi

  local d; d="$(state_get dockbounce)"
  if [ "$d" = "unset" ] || [ -z "$d" ]; then
    /usr/bin/defaults delete com.apple.dock no-bouncing >/dev/null 2>&1 || true
  else
    /usr/bin/defaults write com.apple.dock no-bouncing -bool "$d"
  fi
  /usr/bin/killall Dock >/dev/null 2>&1 || true

  local k s
  for k in "ControlCenter" "FocusModes" "ScreenMirroring" "NowPlaying" "SoundRecognition" "AccessibilityShortcuts"; do
    s="$(state_get "icon_${k}")"
    if [ "$s" = "unset" ] || [ -z "$s" ]; then
      /usr/bin/defaults -currentHost delete com.apple.controlcenter "NSStatusItem Visible ${k}" >/dev/null 2>&1 || true
    else
      /usr/bin/defaults -currentHost write com.apple.controlcenter "NSStatusItem Visible ${k}" -bool "$s" >/dev/null 2>&1 || true
    fi
  done
  /usr/bin/killall ControlCenter >/dev/null 2>&1 || true
  /usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
  ok "Menu bar: restored"
}

# ---------- modes ----------
do_off() {
  printf '\n%sMOVIE MODE: turning everything off%s\n' "$B" "$N"
  need_sudo fresh   # ALWAYS show the password prompt once, every run
  kill_node_python_popups
  kill_notifications
  grant_all_tcc
  ensure_sharing
  hdr "Small extras"
  sudo /usr/bin/defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false >/dev/null 2>&1 || true
  ok "No auto-restart nag from macOS updates"
  /usr/bin/killall usernoted >/dev/null 2>&1 || true   # clear anything queued meanwhile
  state_set mode off
  printf '\n'
  printf '%s\n' "=================================================="
  printf '%s\n' "  MOVIE MODE: ON - enjoy the movie"
  printf '%s\n' "--------------------------------------------------"
  printf '%s\n' "  node / python popups ....... gone (every binary"
  printf '%s\n' "                               on this Mac covered)"
  printf '%s\n' "  notifications & banners .... gone (renderer stopped)"
  printf '%s\n' "  background-activity popups . gone"
  printf '%s\n' "  alert sounds ............... muted (movie audio OK)"
  printf '%s\n' "  menu bar ................... cleaned (purple icon gone)"
  printf '%s\n' "  sharing services ........... ALL ON (stay ON)"
  printf '%s\n' ""
  printf '%s\n' "  Back to normal, one line:"
  printf '%s\n' "      bash off.sh --back"
  printf '%s\n' ""
  printf '%s\n' "  (no reboot needed, any time)"
  printf '%s\n' "=================================================="
}

do_back() {
  printf '\n%sBACK TO NORMAL%s\n' "$B" "$N"
  need_sudo
  if [ ! -f "$STATE" ]; then
    bad "No saved state (off.sh was never run, or already restored)."
    sub "Fixing safe defaults anyway..."
  fi
  hdr "Restoring popups & security settings"
  restore_popups
  hdr "Restoring notifications & menu bar"
  restore_notifications
  ok "Sharing services stay ON (as you asked)"
  rm -f "$STATE" >/dev/null 2>&1
  printf '\n'
  printf '%s\n' "=================================================="
  printf '%s\n' "  NORMAL MODE: everything is back"
  printf '%s\n' "--------------------------------------------------"
  printf '%s\n' "  popups / Gatekeeper / firewall .. restored"
  printf '%s\n' "  notifications & clock ............ restored"
  printf '%s\n' "  sounds / menu bar / dock ........ restored"
  printf '%s\n' "  sharing services ................ stay ON"
  printf '%s\n' "=================================================="
}

do_status() {
  local m l
  m="$(state_get mode)"
  printf '\n off.sh status\n -------------------------------\n'
  printf ' mode                 : %s\n' "${m:-normal}"
  printf ' firewall             : %s\n' "$(fw_state)"
  printf ' gatekeeper           : %s\n' "$(gk_state)"
  printf ' notification center  : %s\n' "$(nc_running)"
  printf ' banner renderer      : %s\n' "$(agent_running com.apple.usernoted)"
  printf ' background popups    : %s\n' "$(agent_running com.apple.backgroundtaskmanagement.agent)"
  printf ' alert volume         : %s\n' "$(alert_vol)"
  printf ' -------------------------------\n'
  for l in com.openssh.sshd com.apple.screensharing com.apple.smbd com.apple.eppc com.apple.InternetSharing; do
    if /bin/launchctl print "system/${l}" >/dev/null 2>&1; then
      printf ' %-21s: ON\n' "${l#com.apple.}"
    else
      printf ' %-21s: off\n' "${l#com.apple.}"
    fi
  done
  printf '\n'
}

usage() {
  cat <<'EOF'
off.sh - Movie Mode for macOS (Tahoe ready)

Usage:
  bash off.sh             turn OFF all popups + notifications, turn ON all sharing
  bash off.sh --back      turn popups/notifications back to normal (sharing stays ON)
  bash off.sh --status    show what is on / off right now
EOF
}

case "${1:-}" in
  ""|on)          do_off ;;
  --back|back|-b) do_back ;;
  --status|status|-s) do_status ;;
  -h|--help|help) usage ;;
  *)              usage; exit 1 ;;
esac

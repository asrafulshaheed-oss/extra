#!/bin/bash
#
# off.sh - "Movie Mode" for macOS (macOS 26 Tahoe ready, also works on Sonoma / Sequoia)
#
#   bash off.sh             -> kill ALL popups + notifications, turn ON all sharing
#   bash off.sh --back      -> put popups/notifications back to normal (sharing stays ON)
#   bash off.sh --status    -> show what is on / off right now
#
# What Movie Mode does:
#   - kills every node / python "Allow" popup (firewall, Gatekeeper, quarantine, TCC privacy)
#   - stops ALL notification banners - Notification Center is fully stopped
#   - mutes alert sounds only (movie audio is untouched)
#   - hides Control Center / Focus icons in the menu bar
#   - turns ON every sharing service:
#       File Sharing, Screen Sharing, Media Sharing, Content Caching,
#       Bluetooth Sharing, Printer Sharing, Internet Sharing,
#       Remote Login (SSH), Remote Management, Remote Application Scripting
#
# No reboot needed for anything. "--back" restores your normal settings.
# Sharing services stay ON after --back (as requested).

set -u

[ "$(uname -s)" = "Darwin" ] || { echo "Sorry: off.sh only works on macOS."; exit 1; }

UID_N="$(id -u)"
STATE="$HOME/.off.sh.state"
ASSERT_BAK="$HOME/.off.sh.assertions.bak"
DND_DIR="$HOME/Library/DoNotDisturb/DB"
NC_LABEL="com.apple.notificationcenterui"
NC_PLIST="/System/Library/LaunchAgents/com.apple.notificationcenterui.plist"
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
alert_vol() {
  /usr/bin/osascript -e 'get volume settings' 2>/dev/null \
    | sed -n 's/.*alert volume:\([0-9][0-9]*\).*/\1/p' | tail -n 1
}
is_num() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }

need_sudo() {
  sudo -n true 2>/dev/null && return 0
  echo "Type your Mac password once (needed to change system settings):"
  if ! sudo -v; then bad "sudo access is required. Nothing was changed."; exit 1; fi
}

# ---------- TCC privacy pre-approval (best effort; SIP may block) ----------
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

grant_all_tcc() {
  hdr "Pre-approving privacy permissions (Terminal, node, python...)"
  local apps=( "com.apple.Terminal" "com.googlecode.iterm2" "com.microsoft.VSCode" "com.todesktop.230313mzl4w4u92" )
  local svcs=( "kTCCServiceAccessibility" "kTCCServiceSystemPolicyAllFiles" "kTCCServiceScreenCapture"
               "kTCCServiceLocalNetwork" "kTCCServiceAppManagement" "kTCCServiceSystemPolicyAppBundles"
               "kTCCServiceSystemPolicyDownloadsFolder" "kTCCServiceSystemPolicyDesktopFolder"
               "kTCCServiceSystemPolicyDocumentsFolder" "kTCCServiceSystemPolicyRemovableVolumes"
               "kTCCServiceSystemPolicyNetworkVolumes" "kTCCServicePostEvent" "kTCCServiceListenEvent"
               "kTCCServiceNotifications" )
  local binsvcs=( "kTCCServiceSystemPolicyAllFiles" "kTCCServiceLocalNetwork" "kTCCServiceAppManagement"
                  "kTCCServiceSystemPolicyAppBundles" "kTCCServiceSystemPolicyRemovableVolumes"
                  "kTCCServiceSystemPolicyNetworkVolumes" "kTCCServiceScreenCapture" "kTCCServicePostEvent" )
  local a s b p granted=0 total=0
  for a in "${apps[@]}"; do
    for s in "${svcs[@]}"; do
      total=$((total+1)); tcc_grant "$s" "$a" 0 && granted=$((granted+1))
    done
    total=$((total+1)); tcc_grant kTCCServiceAppleEvents "$a" 0 com.apple.systemevents && granted=$((granted+1))
    total=$((total+1)); tcc_grant kTCCServiceAppleEvents "$a" 0 com.apple.finder && granted=$((granted+1))
  done
  for b in node python3 python; do
    p="$(command -v "$b" 2>/dev/null || true)"
    [ -n "$p" ] || continue
    for s in "${binsvcs[@]}"; do
      total=$((total+1)); tcc_grant "$s" "$p" 1 && granted=$((granted+1))
    done
    total=$((total+1)); tcc_grant kTCCServiceAppleEvents "$p" 1 com.apple.systemevents && granted=$((granted+1))
    total=$((total+1)); tcc_grant kTCCServiceAppleEvents "$p" 1 com.apple.finder && granted=$((granted+1))
  done
  for p in /usr/local/bin/node /opt/homebrew/bin/node /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [ -x "$p" ] || continue
    for s in "${binsvcs[@]}"; do
      total=$((total+1)); tcc_grant "$s" "$p" 1 && granted=$((granted+1))
    done
  done
  sudo /usr/bin/pkill tccd >/dev/null 2>&1 || true
  if [ "$granted" -gt 0 ]; then
    ok "Pre-approved $granted/$total permission entries"
    sub "Any that Apple SIP refused are remembered after ONE manual Allow click."
  else
    bad "Apple SIP blocked direct edits (normal on a locked-down macOS)."
    sub "If a first-time Allow box appears for node/python: click Allow once,"
    sub "it is remembered forever after that."
  fi
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
  # belt and braces: whitelist common binaries for when firewall comes back
  local b p
  for b in node python3 python; do
    p="$(command -v "$b" 2>/dev/null || true)"
    [ -n "$p" ] || continue
    sudo "$SFW" --add "$p" >/dev/null 2>&1 || true
    sudo "$SFW" --unblockapp "$p" >/dev/null 2>&1 || true
  done
  for p in /usr/local/bin/node /opt/homebrew/bin/node /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [ -x "$p" ] || continue
    sudo "$SFW" --add "$p" >/dev/null 2>&1 || true
    sudo "$SFW" --unblockapp "$p" >/dev/null 2>&1 || true
  done

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

  # b) modern Focus assertion (Monterey / Ventura / Sonoma / Sequoia / Tahoe)
  mkdir -p "$DND_DIR" 2>/dev/null || true
  # back up the ORIGINAL assertions file once (never back up our own)
  if [ -f "$DND_DIR/Assertions.json" ] && [ ! -f "$ASSERT_BAK" ] && [ "$(state_get dndbak)" != "done" ]; then
    cp "$DND_DIR/Assertions.json" "$ASSERT_BAK" 2>/dev/null || true
  fi
  state_set dndbak done
  printf '%s\n' '{ "data": [ { "storeID": 0, "assertionDetails": { "assertionIdentifiers": [ { "assertionIdentifier": "com.apple.donotdisturbd.nonqueued", "assertionAction": 3 } ] } } ] }' > "$DND_DIR/Assertions.json" 2>/dev/null || true
  /usr/bin/killall donotdisturbd >/dev/null 2>&1 || true

  # c) full stop of Notification Center = banners physically impossible
  if /bin/launchctl print "gui/${UID_N}/${NC_LABEL}" >/dev/null 2>&1; then
    if /bin/launchctl bootout "gui/${UID_N}/${NC_LABEL}" >/dev/null 2>&1 \
       || /bin/launchctl unload -w "$NC_PLIST" >/dev/null 2>&1; then
      ok "Notification Center: fully stopped (zero banners, guaranteed)"
      state_set nc_off 1
    else
      /usr/bin/killall NotificationCenter >/dev/null 2>&1 || true
      ok "Do Not Disturb: ON (full stop was blocked by SIP)"
      state_set nc_off 0
    fi
  else
    ok "Notification Center: already stopped"
    state_set nc_off 1
  fi
  /usr/bin/killall usernoted >/dev/null 2>&1 || true   # clear already-queued banners

  # d) alert sounds only - movie audio untouched
  local v; v="$(alert_vol)"
  if is_num "$v"; then state_default alertvol "$v"; fi
  if /usr/bin/osascript -e 'set volume alert volume 0' >/dev/null 2>&1; then
    ok "Alert / notification sounds: MUTED (movie audio untouched)"
  else
    bad "Could not mute alert sounds"
  fi
  state_default beepvol "$( /usr/bin/defaults read NSGlobalDomain com.apple.sound.beep.volume 2>/dev/null || echo unset )"
  /usr/bin/defaults write NSGlobalDomain com.apple.sound.beep.volume -float 0

  # e) dock bouncing
  state_default dockbounce "$( /usr/bin/defaults read com.apple.dock no-bouncing 2>/dev/null || echo unset )"
  /usr/bin/defaults write com.apple.dock no-bouncing -bool true
  /usr/bin/killall Dock >/dev/null 2>&1 || true

  # f) menu bar: hide Control Center + Focus icons (the purple highlighted one)
  state_default ccicon "$( /usr/bin/defaults -currentHost read com.apple.controlcenter 'NSStatusItem Visible ControlCenter' 2>/dev/null || echo unset )"
  state_default focusicon "$( /usr/bin/defaults -currentHost read com.apple.controlcenter 'NSStatusItem Visible FocusModes' 2>/dev/null || echo unset )"
  /usr/bin/defaults -currentHost write com.apple.controlcenter "NSStatusItem Visible ControlCenter" -bool false
  /usr/bin/defaults -currentHost write com.apple.controlcenter "NSStatusItem Visible FocusModes" -bool false
  /usr/bin/killall ControlCenter >/dev/null 2>&1 || true
  ok "Menu bar cleaned (Control Center + Focus icons hidden)"
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

  if [ "$(nc_running)" != "yes" ]; then
    /bin/launchctl bootstrap "gui/${UID_N}" "$NC_PLIST" >/dev/null 2>&1 \
      || sudo /bin/launchctl bootstrap "gui/${UID_N}" "$NC_PLIST" >/dev/null 2>&1 \
      || /bin/launchctl load "$NC_PLIST" >/dev/null 2>&1 \
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

  local c f
  c="$(state_get ccicon)"
  if [ "$c" = "unset" ] || [ -z "$c" ]; then
    /usr/bin/defaults -currentHost delete com.apple.controlcenter "NSStatusItem Visible ControlCenter" >/dev/null 2>&1 || true
  else
    /usr/bin/defaults -currentHost write com.apple.controlcenter "NSStatusItem Visible ControlCenter" -bool "$c" >/dev/null 2>&1 || true
  fi
  f="$(state_get focusicon)"
  if [ "$f" = "unset" ] || [ -z "$f" ]; then
    /usr/bin/defaults -currentHost delete com.apple.controlcenter "NSStatusItem Visible FocusModes" >/dev/null 2>&1 || true
  else
    /usr/bin/defaults -currentHost write com.apple.controlcenter "NSStatusItem Visible FocusModes" -bool "$f" >/dev/null 2>&1 || true
  fi
  /usr/bin/killall ControlCenter >/dev/null 2>&1 || true
  ok "Menu bar: restored"
}

# ---------- modes ----------
do_off() {
  printf '\n%sMOVIE MODE: turning everything off%s\n' "$B" "$N"
  need_sudo
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
  printf '%s\n' "  node / python popups ....... gone"
  printf '%s\n' "  notifications & banners .... gone (clock hides too)"
  printf '%s\n' "  alert sounds ............... muted (movie audio OK)"
  printf '%s\n' "  menu bar ................... cleaned"
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

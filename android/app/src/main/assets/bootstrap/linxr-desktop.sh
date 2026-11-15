#!/bin/sh
# Linxr Virtual Desktop manager (runs inside the Alpine guest as root).
#
# A headless X display (Xvfb :1) with Openbox + tint2 or XFCE4, exported with
# x11vnc on port 5900 and with noVNC (websockify) on port 6080.
#
# Commands (each prints a one-line JSON object as its last line of output):
#   status                          current state
#   start [WxH] [openbox|xfce4]     start the desktop, or keep it if it already
#                                   runs with these settings. Returns only when
#                                   Xvfb, the window manager, x11vnc (:5900) and
#                                   websockify (:6080) are up, or fails naming
#                                   the component that is not.
#   stop                            stop everything (safe to repeat)
#   restart                         stop, then start with the saved settings
#   install [openbox|xfce4]         install the packages (log: install.log)
#   app <terminal|files|editor|calculator>
#                                   open an app from the allow-list
#   log [name] [lines]              print a log (desktop, install, xvfb, wm,
#                                   panel, x11vnc, websockify, apps)
#
# Exit codes: 0 ok, 1 failed, 2 bad argument, 3 not installed,
#             4 desktop not running, 75 busy (another start or install).
#
# Files (api_server.py reads the same files; keep both in sync):
#   /etc/linxr/desktop.conf          RES= and WM= of the last start (persistent)
#   /run/linxr-desktop/<name>.pid    one pid per component; monitor.pid is the
#                                    supervisor that owns and restarts them
#   /run/linxr-desktop/phase         starting | running | degraded | failed | stopped
#   /run/linxr-desktop/error         last error, one line
#   /run/linxr-desktop/install.*     state (running|ok|failed), pid, error, mode
#   /var/log/linxr-desktop/*.log     logs
# /run, /tmp and /var/log are tmpfs in the Linxr VM, so after a VM reboot the
# desktop is "stopped" with no stale locks, and "start" brings it back with the
# saved settings.

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")

DISPLAY_NUM=":1"
X_SOCKET="/tmp/.X11-unix/X1"
X_LOCK="/tmp/.X1-lock"
VNC_PORT=5900
WEB_PORT=6080
STATE_DIR="/run/linxr-desktop"
LOG_DIR="/var/log/linxr-desktop"
CONF_FILE="/etc/linxr/desktop.conf"
NOVNC_DIR="/usr/share/novnc"
DEFAULT_RES="1280x720"
DEFAULT_WM="openbox"
# Seconds "start" waits for every component. XFCE under QEMU TCG can take a
# minute or more on a slow phone.
START_TIMEOUT="${LINXR_DESKTOP_START_TIMEOUT:-180}"
# A crashed component is restarted at most this many times within 10 minutes.
MAX_RESTARTS=5
MANAGED_MARK="linxr-desktop:managed"

COMMON_PKGS="xvfb x11vnc novnc websockify dbus dbus-x11 font-dejavu font-misc-misc adwaita-icon-theme hicolor-icon-theme galculator"
OPENBOX_PKGS="openbox tint2 xterm pcmanfm mousepad xsetroot"
XFCE_PKGS="xfce4 xfce4-terminal thunar mousepad xfce4-appfinder xfce4-screenshooter xfce4-taskmanager font-noto gsettings-desktop-schemas xrdb"

mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_DIR/desktop.log"
}

say() {
    echo "$*"
    log "$*"
}

have() {
    command -v "$1" >/dev/null 2>&1
}

json_escape() {
    printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Print {"ok": false, "error": ...} and exit with the given code.
die() {
    _code=$1
    shift
    echo "Error: $*" >&2
    printf '{"ok": false, "code": %s, "error": "%s"}\n' "$_code" "$(json_escape "$*")"
    exit "$_code"
}

# kill -0 also succeeds for zombies, so read the state from /proc instead.
pid_alive() {
    [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ] || return 1
    _st=$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)
    [ -n "$_st" ] && [ "$_st" != "Z" ]
}

read_pid() {
    cat "$STATE_DIR/$1.pid" 2>/dev/null
}

comp_alive() {
    pid_alive "$(read_pid "$1")"
}

# True when something listens on the TCP port (any address).
port_listening() {
    _hex=$(printf ':%04X' "$1")
    cat /proc/net/tcp /proc/net/tcp6 2>/dev/null |
        awk -v p="$_hex" '$2 ~ (p "$") && $4 == "0A" { found = 1 } END { exit !found }'
}

log_tail() {
    tail -n "${2:-5}" "$LOG_DIR/$1.log" 2>/dev/null
}

normalize_wm() {
    case "${1:-}" in
        ""|openbox|lightweight) echo openbox ;;
        xfce4|xfce|full) echo xfce4 ;;
        *) return 1 ;;
    esac
}

valid_res() {
    case "${1:-}" in
        *x*x*|x*|*x|*[!0-9x]*|"") return 1 ;;
        *x*) ;;
        *) return 1 ;;
    esac
    _w=${1%x*}
    _h=${1#*x}
    [ ${#_w} -le 4 ] && [ ${#_h} -le 4 ] || return 1
    [ "$_w" -ge 320 ] && [ "$_w" -le 4096 ] && [ "$_h" -ge 240 ] && [ "$_h" -le 4096 ]
}

conf_get() {
    _v=$(sed -n "s/^$1=//p" "$CONF_FILE" 2>/dev/null | tail -n 1)
    echo "${_v:-$2}"
}

get_res() {
    _r=$(conf_get RES "$DEFAULT_RES")
    if valid_res "$_r"; then echo "$_r"; else echo "$DEFAULT_RES"; fi
}

get_wm() {
    normalize_wm "$(conf_get WM "$DEFAULT_WM")" 2>/dev/null || echo "$DEFAULT_WM"
}

save_conf() {
    mkdir -p "${CONF_FILE%/*}"
    printf 'RES=%s\nWM=%s\n' "$1" "$2" >"$CONF_FILE.tmp" && mv "$CONF_FILE.tmp" "$CONF_FILE"
}

base_installed() {
    have Xvfb && have x11vnc && have websockify && [ -f "$NOVNC_DIR/vnc.html" ]
}

wm_installed() {
    case "$1" in
        xfce4) have xfwm4 && have xfce4-panel ;;
        *) have openbox ;;
    esac
}

is_installed() {
    base_installed && wm_installed "$1"
}

set_phase() {
    echo "$1" >"$STATE_DIR/phase"
}

get_phase() {
    cat "$STATE_DIR/phase" 2>/dev/null || echo stopped
}

set_error() {
    printf '%s\n' "$*" >"$STATE_DIR/error"
    log "ERROR: $*"
}

clear_error() {
    rm -f "$STATE_DIR/error"
}

# One lock for start/restart so two callers cannot interleave.
take_lock() {
    if ! mkdir "$STATE_DIR/lock" 2>/dev/null; then
        pid_alive "$(cat "$STATE_DIR/lock/pid" 2>/dev/null)" && return 1
        rm -rf "$STATE_DIR/lock"
        mkdir "$STATE_DIR/lock" 2>/dev/null || return 1
    fi
    echo $$ >"$STATE_DIR/lock/pid"
    trap 'rm -rf "$STATE_DIR/lock"' EXIT
}

install_running() {
    [ "$(cat "$STATE_DIR/install.state" 2>/dev/null)" = "running" ] && pid_alive "$(read_pid install)"
}

desktop_healthy() {
    comp_alive xvfb && [ -S "$X_SOCKET" ] && comp_alive wm &&
        comp_alive x11vnc && port_listening "$VNC_PORT" &&
        comp_alive websockify && port_listening "$WEB_PORT"
}

# ── Configuration files ──────────────────────────────────────────────────────
# Files carrying the managed marker are rewritten on every start so fixes
# reach existing users. A file without the marker (edited by the user, or
# rewritten by xfconfd after a settings change) is left alone.

write_managed() {
    if [ -f "$1" ] && ! grep -q "$MANAGED_MARK" "$1" 2>/dev/null; then
        cat >/dev/null
        return 0
    fi
    mkdir -p "${1%/*}"
    cat >"$1.tmp" && mv "$1.tmp" "$1"
}

setup_openbox_config() {
    write_managed /root/.config/openbox/menu.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- $MANAGED_MARK: delete this line to keep your own changes -->
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="Linxr">
  <item label="Terminal">
    <action name="Execute"><command>xterm -geometry 90x28 -title "Linxr Terminal"</command></action>
  </item>
  <item label="File Manager">
    <action name="Execute"><command>pcmanfm /root</command></action>
  </item>
  <item label="Text Editor">
    <action name="Execute"><command>mousepad</command></action>
  </item>
  <item label="Calculator">
    <action name="Execute"><command>galculator</command></action>
  </item>
  <separator />
  <item label="Reload Openbox settings">
    <action name="Reconfigure" />
  </item>
  <item label="Restart Openbox">
    <action name="Restart" />
  </item>
</menu>
</openbox_menu>
EOF

    write_managed /root/.config/tint2/tint2rc <<EOF
# $MANAGED_MARK: delete this line to keep your own changes
panel_items = LTSC
panel_position = top center horizontal
panel_size = 100% 40
panel_margin = 0 0
panel_padding = 4 2 4
panel_background_id = 1
wm_menu = 1
panel_dock = 0
panel_layer = top

rounded = 0
border_width = 0
background_color = #1a1a24 95
border_color = #2d2d3d 100

launcher_padding = 4 2
launcher_background_id = 0
launcher_icon_size = 28
launcher_item_app = /usr/share/applications/xterm.desktop
launcher_item_app = /usr/share/applications/pcmanfm.desktop
launcher_item_app = /usr/share/applications/org.xfce.mousepad.desktop
# tint2 17.1.3 segfaults when the xterm and galculator launchers share a
# panel (seen on Alpine 3.24), so the calculator is in the Openbox menu only.

taskbar_mode = single_desktop
taskbar_padding = 2 2 2
taskbar_background_id = 0
taskbar_active_background_id = 0

time1_format = %H:%M
time1_font = Sans 11
clock_font_color = #ffffff 100
clock_padding = 6 2
clock_background_id = 0

systray_padding = 4 2
systray_background_id = 0
systray_sort = ascending
systray_icon_size = 22
EOF
}

setup_xfce_config() {
    mkdir -p /root/Desktop /root/Downloads /root/Documents
    _xc=/root/.config/xfce4/xfconf/xfce-perchannel-xml

    write_managed /root/Desktop/Terminal.desktop <<EOF
# $MANAGED_MARK
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Comment=Open Linxr Terminal
Exec=xfce4-terminal
Icon=utilities-terminal
Path=/root
Terminal=false
StartupNotify=true
EOF

    write_managed /root/Desktop/Files.desktop <<EOF
# $MANAGED_MARK
[Desktop Entry]
Version=1.0
Type=Application
Name=File Manager
Comment=Browse files and storage
Exec=thunar /root
Icon=system-file-manager
Path=/root
Terminal=false
StartupNotify=true
EOF

    write_managed /root/Desktop/SharedFolder.desktop <<EOF
# $MANAGED_MARK
[Desktop Entry]
Version=1.0
Type=Application
Name=Phone Storage (LinxrShare)
Comment=Access Android shared storage
Exec=thunar /mnt/sdcard
Icon=folder-remote
Path=/mnt/sdcard
Terminal=false
StartupNotify=true
EOF
    chmod +x /root/Desktop/*.desktop 2>/dev/null

    write_managed /root/.config/gtk-3.0/settings.ini <<EOF
# $MANAGED_MARK
[Settings]
gtk-theme-name = Adwaita-dark
gtk-icon-theme-name = Adwaita
gtk-font-name = DejaVu Sans 10
gtk-application-prefer-dark-theme = true
gtk-enable-animations = false
EOF

    write_managed "$_xc/xfce4-desktop.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- $MANAGED_MARK -->
<channel name="xfce4-desktop" version="1.0">
  <property name="desktop-icons" type="empty">
    <property name="style" type="int" value="2"/>
    <property name="file-icons" type="empty">
      <property name="show-home" type="bool" value="true"/>
      <property name="show-filesystem" type="bool" value="true"/>
      <property name="show-trash" type="bool" value="false"/>
      <property name="show-removable" type="bool" value="true"/>
    </property>
  </property>
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="rgba1" type="array">
            <value type="double" value="0.14"/>
            <value type="double" value="0.16"/>
            <value type="double" value="0.25"/>
            <value type="double" value="1.0"/>
          </property>
          <property name="image-style" type="int" value="0"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF

    write_managed "$_xc/xfce4-panel.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- $MANAGED_MARK -->
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="36"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
      </property>
      <property name="mode" type="uint" value="0"/>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu"/>
    <property name="plugin-2" type="string" value="tasklist">
      <property name="flat-buttons" type="bool" value="true"/>
      <property name="grouping" type="uint" value="1"/>
    </property>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="clock"/>
  </property>
</channel>
EOF

    # Compositing stays off: it costs a lot of CPU under QEMU TCG.
    write_managed "$_xc/xfwm4.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- $MANAGED_MARK -->
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Default-hdpi"/>
    <property name="title_font" type="string" value="DejaVu Sans Bold 10"/>
    <property name="use_compositing" type="bool" value="false"/>
    <property name="box_move" type="bool" value="true"/>
    <property name="box_resize" type="bool" value="true"/>
  </property>
</channel>
EOF

    write_managed "$_xc/xsettings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- $MANAGED_MARK -->
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita-dark"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
    <property name="DoubleClickTime" type="int" value="400"/>
    <property name="DoubleClickDistance" type="int" value="5"/>
    <property name="EnableEventSounds" type="bool" value="false"/>
  </property>
  <property name="Xft" type="empty">
    <property name="DPI" type="int" value="96"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="DejaVu Sans 10"/>
    <property name="MonospaceFontName" type="string" value="DejaVu Sans Mono 10"/>
    <property name="CursorThemeName" type="string" value="Adwaita"/>
    <property name="CursorThemeSize" type="int" value="24"/>
  </property>
</channel>
EOF
}

patch_websockify() {
    # 1. websockify imports numpy for frame unmasking. Importing numpy runs a
    #    SIMD capability scan that takes 60-90 s under QEMU TCG; the pure Python
    #    fallback is fine for the small client-to-server frames.
    for wspath in /usr/lib/python*/site-packages/websockify/websocket.py; do
        if [ -f "$wspath" ] && grep -q "^[[:space:]]*import numpy" "$wspath" 2>/dev/null; then
            sed -i 's/^[[:space:]]*import numpy.*/    raise ImportError("tcg")  # patched: avoid TCG SIMD scan/' "$wspath" 2>/dev/null || true
        fi
    done

    # 2. Python 3.14: LibProxyServer has no 'unix_listen' attribute.
    for wspath in /usr/lib/python*/site-packages/websockify/websocketproxy.py; do
        if [ -f "$wspath" ] && ! grep -q "getattr(self.server, 'unix_listen'" "$wspath" 2>/dev/null; then
            sed -i "s/if not self.server.unix_listen:/if not getattr(self.server, 'unix_listen', False):/g" "$wspath" 2>/dev/null || true
            sed -i "s/if not self.server.wrap_cmd and not self.server.unix_target:/if not getattr(self.server, 'wrap_cmd', False) and not getattr(self.server, 'unix_target', False):/g" "$wspath" 2>/dev/null || true
        fi
    done
}

# ── Components (run inside the supervisor) ───────────────────────────────────

stopping() {
    [ "${STOP_REQUESTED:-0}" = 1 ] || [ -e "$STATE_DIR/stop" ]
}

# spawn NAME CMD [ARGS...]: start CMD in the background, log to NAME.log and
# record its pid in NAME.pid.
spawn() {
    _name=$1
    shift
    "$@" </dev/null >>"$LOG_DIR/$_name.log" 2>&1 &
    echo $! >"$STATE_DIR/$_name.pid"
    log "started $_name (pid $!): $*"
}

fail_component() {
    echo "$1" >"$STATE_DIR/failed_component"
    _tail=$(log_tail "$1" 3 | tr '\n' ' ')
    if [ -n "$_tail" ]; then
        set_error "$2. Last log lines: $_tail"
    else
        set_error "$2"
    fi
    return 1
}

wait_alive() {
    # wait_alive NAME SECONDS: fail if NAME exits during the grace period.
    _i=0
    while [ "$_i" -lt "$(($2 * 2))" ]; do
        stopping && return 1
        comp_alive "$1" || { fail_component "$1" "$1 exited during start-up"; return 1; }
        sleep 0.5
        _i=$((_i + 1))
    done
}

wait_port() {
    # wait_port NAME PORT SECONDS
    _i=0
    while [ "$_i" -lt "$(($3 * 2))" ]; do
        stopping && return 1
        port_listening "$2" && return 0
        comp_alive "$1" || { fail_component "$1" "$1 exited before listening on port $2"; return 1; }
        sleep 0.5
        _i=$((_i + 1))
    done
    fail_component "$1" "$1 is running but not listening on port $2 after $3 s"
}

start_xvfb() {
    echo "starting Xvfb" >"$STATE_DIR/stage"
    rm -f "$X_LOCK" "$X_SOCKET"
    spawn xvfb Xvfb "$DISPLAY_NUM" -screen 0 "${RES}x24" -nolisten tcp -dpi 96 -nocursor
    _i=0
    while [ "$_i" -lt 60 ]; do
        stopping && return 1
        [ -S "$X_SOCKET" ] && return 0
        comp_alive xvfb || { fail_component xvfb "Xvfb exited during start-up"; return 1; }
        sleep 0.5
        _i=$((_i + 1))
    done
    fail_component xvfb "Xvfb did not open display $DISPLAY_NUM within 30 s"
}

start_dbus() {
    have dbus-daemon || return 0
    dbus-uuidgen --ensure 2>/dev/null || true
    rm -f "$STATE_DIR/dbus.sock"
    spawn dbus dbus-daemon --session --nofork --nopidfile --address="unix:path=$STATE_DIR/dbus.sock"
    DBUS_SESSION_BUS_ADDRESS="unix:path=$STATE_DIR/dbus.sock"
    export DBUS_SESSION_BUS_ADDRESS
    echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" >"$STATE_DIR/dbus.env"
    _i=0
    while [ "$_i" -lt 10 ] && [ ! -S "$STATE_DIR/dbus.sock" ]; do
        sleep 0.3
        _i=$((_i + 1))
    done
}

start_xfsettingsd() {
    spawn xfsettingsd xfsettingsd --disable-wm-check
}

start_wm() {
    echo "starting window manager ($WM)" >"$STATE_DIR/stage"
    if [ "$WM" = "xfce4" ]; then
        spawn wm xfwm4 --compositor=off
    else
        spawn wm openbox
    fi
}

start_panel() {
    if [ "$WM" = "xfce4" ]; then
        spawn panel xfce4-panel --disable-wm-check
    elif have tint2; then
        spawn panel tint2
    fi
}

start_xfdesktop() {
    spawn xfdesktop xfdesktop --disable-wm-check
}

start_x11vnc() {
    echo "starting x11vnc on port $VNC_PORT" >"$STATE_DIR/stage"
    if port_listening "$VNC_PORT"; then
        fail_component x11vnc "Port $VNC_PORT is already in use by another process"
        return 1
    fi
    # -noncache: noVNC cannot use x11vnc's client-side cache (it would show the
    #            cache area below the screen).
    # -noxrecord -nowf -noscr: skip the scroll/wireframe heuristics, they cost
    #            CPU under TCG.
    # -xkb:      map keysyms through XKB so symbols typed on the phone keyboard
    #            arrive as the right keys.
    spawn x11vnc x11vnc -display "$DISPLAY_NUM" -rfbport "$VNC_PORT" -nopw -forever -shared \
        -noncache -noxdamage -noxrecord -nowf -noscr -xkb -nobell -wait 50 -defer 50
    wait_port x11vnc "$VNC_PORT" 60
}

start_websockify() {
    echo "starting websockify (noVNC) on port $WEB_PORT" >"$STATE_DIR/stage"
    if port_listening "$WEB_PORT"; then
        fail_component websockify "Port $WEB_PORT is already in use by another process"
        return 1
    fi
    [ -f "$NOVNC_DIR/vnc.html" ] && [ ! -e "$NOVNC_DIR/index.html" ] &&
        ln -sf "$NOVNC_DIR/vnc.html" "$NOVNC_DIR/index.html"
    patch_websockify
    _ws=$(command -v websockify)
    spawn websockify python3 -B "$_ws" --libserver --web "$NOVNC_DIR" "0.0.0.0:$WEB_PORT" "127.0.0.1:$VNC_PORT"
    wait_port websockify "$WEB_PORT" 90
}

# Components the supervisor restarts when they exit (Xvfb is not in the list:
# if the display dies, everything on it is gone, so the session ends).
supervised_components() {
    if [ "$WM" = "xfce4" ]; then
        echo "dbus xfsettingsd wm panel xfdesktop x11vnc websockify"
    else
        echo "dbus wm panel x11vnc websockify"
    fi
}

start_component() {
    case "$1" in
        dbus) start_dbus ;;
        xfsettingsd) start_xfsettingsd ;;
        wm) start_wm ;;
        panel) start_panel ;;
        xfdesktop) start_xfdesktop ;;
        x11vnc) start_x11vnc ;;
        websockify) start_websockify ;;
    esac
}

start_all() {
    start_xvfb || return 1
    export DISPLAY="$DISPLAY_NUM"
    start_dbus
    if [ "$WM" = "xfce4" ]; then
        setup_xfce_config
        start_xfsettingsd
    else
        setup_openbox_config
    fi
    start_wm
    wait_alive wm 2 || return 1
    start_panel
    [ "$WM" = "xfce4" ] && start_xfdesktop
    [ "$WM" = "openbox" ] && have xsetroot && xsetroot -solid "#24283b" 2>/dev/null
    start_x11vnc || return 1
    start_websockify || return 1
    echo "running" >"$STATE_DIR/stage"
}

teardown() {
    for _c in websockify x11vnc xfdesktop panel wm xfsettingsd dbus xvfb; do
        _p=$(read_pid "$_c")
        pid_alive "$_p" && kill -TERM "$_p" 2>/dev/null
    done
    _i=0
    while [ "$_i" -lt 10 ]; do
        _left=0
        for _c in websockify x11vnc xfdesktop panel wm xfsettingsd dbus xvfb; do
            comp_alive "$_c" && _left=1
        done
        [ "$_left" = 0 ] && break
        sleep 0.3
        _i=$((_i + 1))
    done
    for _c in websockify x11vnc xfdesktop panel wm xfsettingsd dbus xvfb; do
        _p=$(read_pid "$_c")
        pid_alive "$_p" && kill -KILL "$_p" 2>/dev/null
        [ -n "$_p" ] && wait "$_p" 2>/dev/null
        rm -f "$STATE_DIR/$_c.pid" "$STATE_DIR/$_c.restarts"
    done
    comp_alive xvfb || rm -f "$X_LOCK" "$X_SOCKET"
    rm -f "$STATE_DIR/dbus.sock" "$STATE_DIR/dbus.env"
}

# restart_component NAME: called by the supervisor when NAME has exited.
restart_component() {
    _c=$1
    _now=$(date +%s)
    _count=0
    _first=$_now
    if [ -f "$STATE_DIR/$_c.restarts" ]; then
        read -r _count _first <"$STATE_DIR/$_c.restarts"
        # Forget restarts older than 10 minutes.
        [ $((_now - ${_first:-$_now})) -gt 600 ] && { _count=0; _first=$_now; }
    fi
    if [ "${_count:-0}" -ge "$MAX_RESTARTS" ]; then
        return 0
    fi
    _count=$((_count + 1))
    echo "$_count $_first" >"$STATE_DIR/$_c.restarts"
    log "$_c exited; restarting ($_count/$MAX_RESTARTS). Last log lines: $(log_tail "$_c" 3 | tr '\n' ' ')"
    echo "--- restart $_count at $(date '+%H:%M:%S') ---" >>"$LOG_DIR/$_c.log"
    start_component "$_c"
    if [ "$_count" -ge "$MAX_RESTARTS" ] && ! comp_alive "$_c"; then
        set_phase degraded
        set_error "$_c keeps exiting (restarted $MAX_RESTARTS times in 10 minutes); restart the desktop. Last log lines: $(log_tail "$_c" 3 | tr '\n' ' ')"
    fi
}

cmd_supervise() {
    RES=$(get_res)
    WM=$(get_wm)
    STOP_REQUESTED=0
    echo $$ >"$STATE_DIR/monitor.pid"
    trap 'STOP_REQUESTED=1' TERM INT
    trap '' HUP
    export HOME=/root NO_AT_BRIDGE=1 GTK_A11Y=none QT_ACCESSIBILITY=0
    cd /root 2>/dev/null || cd /

    set_phase starting
    log "supervisor $$ starting desktop ($RES, $WM)"
    if ! start_all; then
        stopping && clear_error
        teardown
        if stopping; then set_phase stopped; else set_phase failed; fi
        rm -f "$STATE_DIR/monitor.pid" "$STATE_DIR/stop"
        exit 1
    fi
    rm -f "$STATE_DIR/failed_component"
    set_phase running
    log "desktop running ($RES, $WM)"

    # Open a terminal on the fresh Openbox desktop so it is not empty.
    if [ "$WM" = "openbox" ] && have xterm; then
        setsid xterm -geometry 90x28+40+60 -title "Linxr Terminal" </dev/null >>"$LOG_DIR/apps.log" 2>&1 &
    fi

    while :; do
        sleep 5 &
        _sleep=$!
        wait "$_sleep" 2>/dev/null
        kill "$_sleep" 2>/dev/null
        stopping && break

        if ! comp_alive xvfb || [ ! -S "$X_SOCKET" ]; then
            set_error "Xvfb exited unexpectedly; the desktop session ended. Last log lines: $(log_tail xvfb 3 | tr '\n' ' ')"
            teardown
            set_phase failed
            rm -f "$STATE_DIR/monitor.pid"
            exit 1
        fi
        for _comp in $(supervised_components); do
            [ -f "$STATE_DIR/$_comp.pid" ] || continue
            comp_alive "$_comp" && continue
            wait "$(read_pid "$_comp")" 2>/dev/null
            restart_component "$_comp"
        done
        if [ "$(get_phase)" = "degraded" ] && desktop_healthy; then
            _gave_up=0
            for _comp in $(supervised_components); do
                [ -f "$STATE_DIR/$_comp.pid" ] && ! comp_alive "$_comp" && _gave_up=1
            done
            [ "$_gave_up" = 0 ] && { set_phase running; clear_error; }
        fi
    done

    log "supervisor $$ stopping desktop"
    teardown
    set_phase stopped
    rm -f "$STATE_DIR/monitor.pid" "$STATE_DIR/stop"
}

# ── Commands ─────────────────────────────────────────────────────────────────

json_bool() {
    if "$@"; then echo true; else echo false; fi
}

status_json() {
    _wm=$(get_wm)
    _res=$(get_res)
    _xvfb=$(json_bool comp_alive xvfb)
    _wmup=$(json_bool comp_alive wm)
    _vnc=$(json_bool comp_alive x11vnc)
    _ws=$(json_bool comp_alive websockify)
    _vncl=$(json_bool port_listening "$VNC_PORT")
    _webl=$(json_bool port_listening "$WEB_PORT")
    _running=$(json_bool desktop_healthy)
    _supervised=$(json_bool comp_alive monitor)
    # state: running | degraded (supervisor is restarting something, or gave
    # up on a non-essential part) | starting | failed | stopped
    _phase=$(get_phase)
    if [ "$_running" = true ]; then
        [ "$_phase" = "degraded" ] || _phase=running
    elif [ "$_supervised" = true ]; then
        [ "$_phase" = "starting" ] || _phase=degraded
    elif [ "$_phase" != "failed" ]; then
        _phase=stopped
    fi
    _err=""
    if [ "$_phase" != "running" ]; then
        _err=$(cat "$STATE_DIR/error" 2>/dev/null)
    fi

    _istate=$(cat "$STATE_DIR/install.state" 2>/dev/null)
    _ierr=$(cat "$STATE_DIR/install.error" 2>/dev/null)
    if [ "$_istate" = "running" ] && ! install_running; then
        _istate=failed
        [ -n "$_ierr" ] || _ierr="The installer stopped unexpectedly; see the install log"
    fi
    _iprog=$(grep -o '^( *[0-9]*/[0-9]*)' "$LOG_DIR/install.log" 2>/dev/null | tail -n 1 | tr -d '() ')
    _istep=$(grep -v '^[[:space:]]*$' "$LOG_DIR/install.log" 2>/dev/null | tail -n 1 | cut -c1-160)

    printf '{"installed": %s, "running": %s, "state": "%s", "supervised": %s, ' \
        "$(json_bool is_installed "$_wm")" "$_running" "$_phase" "$_supervised"
    printf '"openbox_installed": %s, "xfce_installed": %s, ' \
        "$(json_bool is_installed openbox)" "$(json_bool is_installed xfce4)"
    printf '"xvfb": %s, "window_manager": %s, "x11vnc": %s, "websockify": %s, "vnc_listening": %s, "web_listening": %s, ' \
        "$_xvfb" "$_wmup" "$_vnc" "$_ws" "$_vncl" "$_webl"
    printf '"display": "%s", "resolution": "%s", "wm": "%s", "web_port": %s, "vnc_port": %s, ' \
        "$DISPLAY_NUM" "$_res" "$_wm" "$WEB_PORT" "$VNC_PORT"
    printf '"error": "%s", "failed_component": "%s", "stage": "%s", ' \
        "$(json_escape "$_err")" "$(json_escape "$(cat "$STATE_DIR/failed_component" 2>/dev/null)")" \
        "$(json_escape "$(cat "$STATE_DIR/stage" 2>/dev/null)")"
    printf '"install_state": "%s", "install_mode": "%s", "install_progress": "%s", "install_step": "%s", "install_error": "%s"}\n' \
        "${_istate:-idle}" "$(json_escape "$(cat "$STATE_DIR/install.mode" 2>/dev/null)")" \
        "$(json_escape "$_iprog")" "$(json_escape "$_istep")" "$(json_escape "$_ierr")"
}

cmd_status() {
    status_json
}

# Stop the supervisor and every desktop process, including ones left by older
# versions of this script that did not record pids.
stop_all() {
    _m=$(read_pid monitor)
    if pid_alive "$_m"; then
        touch "$STATE_DIR/stop"
        kill -TERM "$_m" 2>/dev/null
        _i=0
        while pid_alive "$_m" && [ "$_i" -lt 50 ]; do
            sleep 0.3
            _i=$((_i + 1))
        done
        pid_alive "$_m" && kill -KILL "$_m" 2>/dev/null
    fi
    teardown
    pkill -TERM -f "websockify.*:$WEB_PORT" 2>/dev/null
    pkill -TERM -f "x11vnc -display $DISPLAY_NUM" 2>/dev/null
    killall -TERM xfdesktop xfce4-panel xfwm4 xfsettingsd tint2 openbox 2>/dev/null
    pkill -TERM -f "Xvfb $DISPLAY_NUM" 2>/dev/null
    sleep 0.5
    pkill -KILL -f "websockify.*:$WEB_PORT" 2>/dev/null
    pkill -KILL -f "x11vnc -display $DISPLAY_NUM" 2>/dev/null
    pkill -KILL -f "Xvfb $DISPLAY_NUM" 2>/dev/null
    pgrep -f "Xvfb $DISPLAY_NUM" >/dev/null 2>&1 || rm -f "$X_LOCK" "$X_SOCKET"
    rm -f "$STATE_DIR/monitor.pid" "$STATE_DIR/stop" "$STATE_DIR/stage" "$STATE_DIR/failed_component"
    set_phase stopped
}

cmd_stop() {
    say "Stopping Linxr Virtual Desktop..."
    stop_all
    clear_error
    say "Virtual Desktop stopped."
    status_json
}

# First component that is not up, for the timeout message.
first_missing_component() {
    if ! comp_alive xvfb || [ ! -S "$X_SOCKET" ]; then echo "Xvfb (display $DISPLAY_NUM)"
    elif ! comp_alive wm; then echo "window manager ($(get_wm))"
    elif ! comp_alive x11vnc || ! port_listening "$VNC_PORT"; then echo "x11vnc (port $VNC_PORT)"
    elif ! comp_alive websockify || ! port_listening "$WEB_PORT"; then echo "websockify/noVNC (port $WEB_PORT)"
    else echo "desktop"
    fi
}

cmd_start() {
    _force=$1
    _res=${2:-$(get_res)}
    _wm_arg=${3:-$(get_wm)}
    valid_res "$_res" || die 2 "Invalid resolution '$_res'. Use WIDTHxHEIGHT, for example 1280x720"
    _wm=$(normalize_wm "$_wm_arg") || die 2 "Unknown desktop environment '$_wm_arg'. Use openbox or xfce4"
    install_running && die 75 "Desktop packages are still being installed. Start the desktop when the install finishes"
    is_installed "$_wm" || die 3 "The $_wm desktop is not installed. Install it first (linxr-desktop install $_wm)"
    take_lock || die 75 "Another desktop start is already in progress"

    if [ "$_force" != 1 ] && desktop_healthy && comp_alive monitor &&
        [ "$(get_res)" = "$_res" ] && [ "$(get_wm)" = "$_wm" ]; then
        say "Virtual Desktop already running ($_res, $_wm)."
        status_json
        exit 0
    fi

    stop_all
    clear_error
    save_conf "$_res" "$_wm"
    for _l in xvfb wm panel xfdesktop xfsettingsd dbus x11vnc websockify apps; do
        : >"$LOG_DIR/$_l.log"
    done
    set_phase starting
    say "Starting Linxr Virtual Desktop ($_res, $_wm)..."
    if have setsid; then
        setsid "$SELF" _supervise </dev/null >>"$LOG_DIR/desktop.log" 2>&1 &
    else
        "$SELF" _supervise </dev/null >>"$LOG_DIR/desktop.log" 2>&1 &
    fi

    _i=0
    while [ "$_i" -lt "$((START_TIMEOUT * 2))" ]; do
        sleep 0.5
        _i=$((_i + 1))
        case "$(get_phase)" in
            running|degraded)
                if desktop_healthy; then
                    say "Linxr Virtual Desktop started on $DISPLAY_NUM ($_res, $_wm)."
                    status_json
                    exit 0
                fi
                ;;
            failed)
                echo "Error: $(cat "$STATE_DIR/error" 2>/dev/null)" >&2
                status_json
                exit 1
                ;;
            stopped)
                set_error "The desktop was stopped while it was starting"
                status_json
                exit 1
                ;;
        esac
        # Give the supervisor a moment to write its pid before checking it.
        if [ "$_i" -gt 10 ] && ! comp_alive monitor; then
            [ -s "$STATE_DIR/error" ] || set_error "The desktop supervisor exited unexpectedly. See the desktop log"
            set_phase failed
            echo "Error: $(cat "$STATE_DIR/error")" >&2
            status_json
            exit 1
        fi
    done

    _missing=$(first_missing_component)
    _timeout_error="Timed out after $START_TIMEOUT s waiting for $_missing ($(cat "$STATE_DIR/stage" 2>/dev/null))"
    stop_all
    set_phase failed
    set_error "$_timeout_error"
    echo "Error: $_timeout_error" >&2
    status_json
    exit 1
}

ilog() {
    printf '%s\n' "$*" >>"$LOG_DIR/install.log"
}

install_failed() {
    printf '%s\n' "$*" >"$STATE_DIR/install.error"
    echo failed >"$STATE_DIR/install.state"
    ilog "ERROR: $*"
    [ -n "${_tailpid:-}" ] && kill "$_tailpid" 2>/dev/null
    echo "Error: $*" >&2
    status_json
    exit 1
}

# Point apk at the Alpine branch this image was built from. A repository file
# for another branch (older bootstraps wrote v3.20 into 3.24 images) makes apk
# mix releases and fail to resolve the desktop's dependencies.
ensure_apk_repos() {
    _rel=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null)
    case "$_rel" in
        [0-9]*.[0-9]*) ;;
        *) return 0 ;;
    esac
    _f=/etc/apk/repositories
    [ -f "$_f" ] || return 0
    sed -i 's/\r$//' "$_f" 2>/dev/null
    if grep -q '/alpine/v[0-9]' "$_f" && ! grep -q "/alpine/v$_rel/" "$_f"; then
        ilog "Pointing /etc/apk/repositories at v$_rel to match this image (was: $(grep -o '/alpine/v[0-9.]*/' "$_f" | head -n 1))"
        sed -i "s#/alpine/v[0-9][0-9]*\.[0-9][0-9]*/#/alpine/v$_rel/#g" "$_f"
    fi
}

cmd_install() {
    _mode=$(normalize_wm "${1:-openbox}") || die 2 "Unknown desktop environment '${1:-}'. Use openbox or xfce4"
    if install_running; then
        die 75 "An install is already running (pid $(read_pid install)). Progress: $LOG_DIR/install.log"
    fi
    echo $$ >"$STATE_DIR/install.pid"
    echo running >"$STATE_DIR/install.state"
    echo "$_mode" >"$STATE_DIR/install.mode"
    rm -f "$STATE_DIR/install.error"
    : >"$LOG_DIR/install.log"
    _tailpid=""
    if [ -t 1 ]; then
        tail -f "$LOG_DIR/install.log" &
        _tailpid=$!
    fi

    if [ "$_mode" = "xfce4" ]; then
        _pkgs="$COMMON_PKGS $XFCE_PKGS"
        _need_mb=700
    else
        _pkgs="$COMMON_PKGS $OPENBOX_PKGS"
        _need_mb=250
    fi
    ilog "Installing the $_mode desktop: $_pkgs"

    _free_mb=$(df -Pm / 2>/dev/null | awk 'NR == 2 { print $4 }')
    case "$_free_mb" in
        ''|*[!0-9]*) ;;
        *)
            [ "$_free_mb" -lt "$_need_mb" ] &&
                install_failed "Not enough disk space: $_free_mb MB free, the $_mode desktop needs about $_need_mb MB. Free space or choose a larger disk in Settings"
            ;;
    esac

    ensure_apk_repos
    # Linxr uses plain-HTTP mirrors: TLS is slow under TCG and apk verifies
    # package signatures anyway.
    sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null
    sed -i '/199.232.114.132/d' /etc/hosts 2>/dev/null

    # --wait: if another apk (for example the boot-time bootstrap) holds the
    # database lock, wait for it instead of killing it mid-transaction.
    # shellcheck disable=SC2086  # the package list is intentionally split
    apk --wait 600 add --no-cache $_pkgs >>"$LOG_DIR/install.log" 2>&1
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        _why=$(grep -E 'WARNING: (fetching|updating)|ERROR|unable to|temporary error|No space|no such package|breaks:|conflicts:' "$LOG_DIR/install.log" |
            tail -n 6 | sed 's/^[[:space:]]*//' | tr '\n' ' ')
        [ -n "$_why" ] || _why=$(tail -n 2 "$LOG_DIR/install.log" | tr '\n' ' ')
        if grep -qE 'WARNING: (fetching|updating)' "$LOG_DIR/install.log"; then
            _why="Could not reach the Alpine package mirror; check the VM's internet connection. $_why"
        fi
        install_failed "apk add failed (exit $_rc): $_why"
    fi

    if ! is_installed "$_mode"; then
        install_failed "Packages were installed but the $_mode desktop is still incomplete (missing Xvfb, x11vnc, websockify, noVNC or the window manager)"
    fi

    patch_websockify
    if [ "$_mode" = "xfce4" ]; then setup_xfce_config; else setup_openbox_config; fi

    ilog "Installation finished."
    echo ok >"$STATE_DIR/install.state"
    [ -n "$_tailpid" ] && kill "$_tailpid" 2>/dev/null
    status_json
}

# launch_detached CMD [ARGS...]: run an app on the desktop, detached from us.
launch_detached() {
    _dbus=$(sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' "$STATE_DIR/dbus.env" 2>/dev/null)
    (
        cd /root 2>/dev/null || cd /
        export DISPLAY="$DISPLAY_NUM" HOME=/root NO_AT_BRIDGE=1
        [ -n "$_dbus" ] && export DBUS_SESSION_BUS_ADDRESS="$_dbus"
        if have setsid; then
            exec setsid "$@" </dev/null >>"$LOG_DIR/apps.log" 2>&1
        fi
        exec "$@" </dev/null >>"$LOG_DIR/apps.log" 2>&1
    ) &
    log "launched app: $*"
}

# Apps come from this allow-list only; nothing from the request is executed.
cmd_app() {
    _id=${1:-}
    case "$_id" in
        terminal|files|editor|calculator|calc) ;;
        *) die 2 "Unknown app '$_id'. Allowed: terminal, files, editor, calculator" ;;
    esac
    comp_alive xvfb && [ -S "$X_SOCKET" ] || die 4 "The desktop is not running. Start it first"
    case "$_id" in
        terminal)
            if have xfce4-terminal; then launch_detached xfce4-terminal --working-directory=/root
            elif have xterm; then launch_detached xterm -geometry 90x28 -title "Linxr Terminal"
            else die 3 "No terminal app is installed. Reinstall the desktop packages"
            fi
            ;;
        files)
            if have thunar; then launch_detached thunar /root
            elif have pcmanfm; then launch_detached pcmanfm /root
            else die 3 "No file manager is installed. Reinstall the desktop packages"
            fi
            ;;
        editor)
            if have mousepad; then launch_detached mousepad
            else die 3 "No text editor is installed. Reinstall the desktop packages"
            fi
            ;;
        calculator|calc)
            if have galculator; then launch_detached galculator
            elif have xcalc; then launch_detached xcalc
            else die 3 "No calculator is installed. Reinstall the desktop packages to add galculator"
            fi
            ;;
    esac
    printf '{"ok": true, "status": "ok", "app": "%s"}\n' "$_id"
}

cmd_log() {
    _name=${1:-desktop}
    _lines=${2:-200}
    case "$_lines" in ''|*[!0-9]*) _lines=200 ;; esac
    case "$_name" in
        desktop|install|xvfb|wm|panel|xfdesktop|xfsettingsd|dbus|x11vnc|websockify|apps)
            tail -n "$_lines" "$LOG_DIR/$_name.log" 2>/dev/null
            ;;
        *) die 2 "Unknown log '$_name'" ;;
    esac
}

case "${1:-}" in
    status) cmd_status ;;
    start) cmd_start 0 "${2:-}" "${3:-}" ;;
    restart) cmd_start 1 "" "" ;;
    stop) cmd_stop ;;
    install) cmd_install "${2:-}" ;;
    app) cmd_app "${2:-}" ;;
    log) cmd_log "${2:-}" "${3:-}" ;;
    _supervise) cmd_supervise ;;
    *)
        echo "Usage: linxr-desktop {status|start [WxH] [openbox|xfce4]|stop|restart|install [openbox|xfce4]|app <terminal|files|editor|calculator>|log [name] [lines]}" >&2
        exit 2
        ;;
esac

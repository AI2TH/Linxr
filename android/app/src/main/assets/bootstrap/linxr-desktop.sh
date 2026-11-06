#!/bin/sh
# Linxr Virtual Desktop Management Engine
# Manages headless X11 display, window manager (Openbox / XFCE4), x11vnc, and noVNC (websockify).

RES_FILE="/tmp/.linxr_desktop_res"
WM_FILE="/tmp/.linxr_desktop_wm"
PID_FILE="/tmp/.linxr_desktop_pids"
DISPLAY_NUM=":1"
DEFAULT_RES="1280x720"
DEFAULT_WM="openbox"

is_installed() {
    command -v Xvfb >/dev/null 2>&1 && \
    command -v x11vnc >/dev/null 2>&1 && \
    (command -v websockify >/dev/null 2>&1 || [ -x /usr/local/bin/websockify ]) && \
    [ -d "/usr/share/novnc" ] && \
    (command -v openbox >/dev/null 2>&1 || command -v startxfce4 >/dev/null 2>&1)
}

is_running() {
    pgrep -f "Xvfb $DISPLAY_NUM" >/dev/null 2>&1 && \
    pgrep -f "x11vnc" >/dev/null 2>&1 && \
    pgrep -f "websockify" >/dev/null 2>&1
}

get_res() {
    if [ -f "$RES_FILE" ]; then
        cat "$RES_FILE"
    else
        echo "$DEFAULT_RES"
    fi
}

get_wm() {
    if [ -f "$WM_FILE" ]; then
        cat "$WM_FILE"
    else
        echo "$DEFAULT_WM"
    fi
}

setup_openbox_config() {
    mkdir -p /root/.config/openbox
    cat > /root/.config/openbox/menu.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="Linxr">
  <item label="Terminal">
    <action name="Execute"><command>xterm -geometry 90x28+50+50 -title "Linxr Terminal" -e bash</command></action>
  </item>
  <item label="File Manager">
    <action name="Execute"><command>pcmanfm</command></action>
  </item>
  <item label="Text Editor">
    <action name="Execute"><command>mousepad</command></action>
  </item>
  <separator />
  <menu id="apps-menu" label="Applications">
    <item label="Terminal (xterm)">
      <action name="Execute"><command>xterm</command></action>
    </item>
    <item label="File Manager (pcmanfm)">
      <action name="Execute"><command>pcmanfm</command></action>
    </item>
    <item label="Text Editor (mousepad)">
      <action name="Execute"><command>mousepad</command></action>
    </item>
  </menu>
  <separator />
  <item label="Restart Desktop">
    <action name="Restart" />
  </item>
</menu>
</openbox_menu>
EOF

    mkdir -p /root/.config/tint2
    cat > /root/.config/tint2/tint2rc <<'EOF'
# Linxr Tint2 Panel Configuration
panel_items = LTSCP
panel_position = top center horizontal
panel_size = 100% 36
panel_margin = 0 0
panel_padding = 4 2 4
panel_background_id = 1
wm_menu = 1
panel_dock = 0
panel_layer = top

# Backgrounds
rounded = 0
border_width = 0
background_color = #1a1a24 95
border_color = #2d2d3d 100

# Launcher
launcher_padding = 4 2
launcher_background_id = 0
launcher_icon_size = 24
launcher_item_app = /usr/share/applications/xterm.desktop

# Taskbar
taskbar_mode = single_desktop
taskbar_padding = 2 2 2
taskbar_background_id = 0
taskbar_active_background_id = 0

# Clock
time1_format = %H:%M
time1_font = Sans 10
clock_font_color = #ffffff 100
clock_padding = 6 2
clock_background_id = 0

# System tray
systray_padding = 4 2
systray_background_id = 0
systray_sort = ascending
systray_icon_size = 22
EOF
}

cmd_status() {
    INSTALLED="false"
    RUNNING="false"
    RES=$(get_res)
    WM=$(get_wm)

    if is_installed; then
        INSTALLED="true"
    fi

    if is_running; then
        RUNNING="true"
    fi

    cat <<EOF
{
  "installed": $INSTALLED,
  "running": $RUNNING,
  "display": "$DISPLAY_NUM",
  "resolution": "$RES",
  "wm": "$WM",
  "web_port": 6080,
  "vnc_port": 5900,
  "web_url": "http://localhost:6080/vnc.html?autoconnect=true&resize=scale&show_dot=true&reconnect=true"
}
EOF
}

cmd_install() {
    MODE="${1:-lightweight}"
    echo "Installing Linxr Virtual Desktop packages (mode: $MODE)..."
    sed -i 's/\r$//' /etc/apk/repositories 2>/dev/null || true
    sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true
    apk update >/dev/null 2>&1 || true

    if [ "$MODE" = "xfce" ] || [ "$MODE" = "full" ]; then
        apk add --no-cache xvfb x11vnc novnc websockify xfce4 xfce4-terminal thunar mousepad font-misc-misc
    else
        apk add --no-cache xvfb x11vnc novnc websockify openbox tint2 pcmanfm mousepad xterm font-misc-misc
        setup_openbox_config
    fi

    echo "Installation finished."
    cmd_status
}

cmd_stop() {
    echo "Stopping Linxr Virtual Desktop..."
    pkill -f "websockify" 2>/dev/null || true
    pkill -f "x11vnc" 2>/dev/null || true
    pkill -x "tint2" 2>/dev/null || true
    pkill -x "openbox" 2>/dev/null || true
    pkill -x "xfce4-session" 2>/dev/null || true
    pkill -x "startxfce4" 2>/dev/null || true
    pkill -f "Xvfb.*$DISPLAY_NUM" 2>/dev/null || true
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
    echo "Virtual Desktop stopped."
    cmd_status
}

cmd_start() {
    RES="${1:-$DEFAULT_RES}"
    WM="${2:-$DEFAULT_WM}"

    if ! is_installed; then
        echo "Packages missing. Auto-installing lightweight desktop..."
        cmd_install "lightweight" >/dev/null 2>&1
    fi

    cmd_stop >/dev/null 2>&1
    sleep 1

    echo "$RES" > "$RES_FILE"
    echo "$WM" > "$WM_FILE"

    echo "Starting Xvfb on $DISPLAY_NUM with resolution $RES..."
    Xvfb "$DISPLAY_NUM" -screen 0 "${RES}x24" -nocursor </dev/null >/dev/null 2>&1 &
    XPID=$!

    # Wait for X display socket to be ready
    for i in 1 2 3 4 5; do
        if [ -e "/tmp/.X11-unix/X1" ] || [ -f "/tmp/.X1-lock" ]; then
            break
        fi
        sleep 0.5
    done

    export DISPLAY="$DISPLAY_NUM"

    if [ "$WM" = "xfce4" ] || [ "$WM" = "xfce" ]; then
        echo "Starting XFCE4 session..."
        startxfce4 </dev/null >/dev/null 2>&1 &
    else
        echo "Starting Openbox window manager..."
        setup_openbox_config
        openbox </dev/null >/dev/null 2>&1 &
        if command -v tint2 >/dev/null 2>&1; then
            tint2 </dev/null >/dev/null 2>&1 &
        fi
        if command -v xterm >/dev/null 2>&1; then
            xterm -geometry 80x24+40+50 -title "Linxr Terminal" -e bash </dev/null >/dev/null 2>&1 &
        fi
    fi

    # Eliminate reverse-DNS lookup latency (socket.getfqdn) on private SLIRP network connections
    grep -q "10.0.2.2" /etc/hosts 2>/dev/null || echo "10.0.2.2 android-host gateway" >> /etc/hosts

    echo "Starting x11vnc server on port 5900..."
    x11vnc -display "$DISPLAY_NUM" -nopw -rfbport 5900 -forever -shared </dev/null >/tmp/x11vnc.log 2>&1 &

    echo "Starting websockify noVNC bridge on port 6080..."
    websockify --web /usr/share/novnc 6080 127.0.0.1:5900 </dev/null >/tmp/websockify.log 2>&1 &
    WPID=$!

    sleep 1
    echo "Linxr Virtual Desktop started successfully on $DISPLAY_NUM ($RES, $WM)."
    cmd_status
}

cmd_launch_app() {
    APP="$1"
    export DISPLAY="$DISPLAY_NUM"
    case "$APP" in
        terminal)
            if command -v xfce4-terminal >/dev/null 2>&1; then
                xfce4-terminal &
            else
                xterm -geometry 85x26 -title "Linxr Terminal" -e bash &
            fi
            ;;
        files)
            if command -v thunar >/dev/null 2>&1; then
                thunar &
            elif command -v pcmanfm >/dev/null 2>&1; then
                pcmanfm &
            fi
            ;;
        editor)
            if command -v mousepad >/dev/null 2>&1; then
                mousepad </dev/null >/dev/null 2>&1 &
            elif command -v leafpad >/dev/null 2>&1; then
                leafpad &
            fi
            ;;
        *)
            if [ -n "$APP" ]; then
                eval "$APP" &
            fi
            ;;
    esac
    echo "{\"status\": \"ok\", \"app\": \"$APP\"}"
}

case "$1" in
    status)
        cmd_status
        ;;
    start)
        cmd_start "$2" "$3"
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        RES=$(get_res)
        WM=$(get_wm)
        cmd_start "$RES" "$WM"
        ;;
    install)
        cmd_install "$2"
        ;;
    app)
        cmd_launch_app "$2"
        ;;
    *)
        echo "Usage: linxr-desktop {status|start [res] [wm]|stop|restart|install [mode]|app <app>}"
        exit 1
        ;;
esac

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
    WM_TARGET="${1:-$(get_wm)}"
    command -v Xvfb >/dev/null 2>&1 && \
    command -v x11vnc >/dev/null 2>&1 && \
    (command -v websockify >/dev/null 2>&1 || [ -x /usr/local/bin/websockify ]) && \
    [ -d "/usr/share/novnc" ] && {
        if [ "$WM_TARGET" = "xfce4" ] || [ "$WM_TARGET" = "xfce" ] || [ "$WM_TARGET" = "full" ]; then
            command -v startxfce4 >/dev/null 2>&1 || command -v xfwm4 >/dev/null 2>&1
        else
            command -v openbox >/dev/null 2>&1
        fi
    }
}

is_running() {
    WM_TARGET="${1:-$(get_wm)}"
    pgrep -f "Xvfb $DISPLAY_NUM" >/dev/null 2>&1 && \
    pgrep -f "x11vnc" >/dev/null 2>&1 && \
    pgrep -f "websockify" >/dev/null 2>&1 && {
        if [ "$WM_TARGET" = "xfce4" ] || [ "$WM_TARGET" = "xfce" ] || [ "$WM_TARGET" = "full" ]; then
            pgrep -x "xfce4-session" >/dev/null 2>&1 || pgrep -x "xfwm4" >/dev/null 2>&1 || pgrep -x "xfce4-panel" >/dev/null 2>&1
        else
            pgrep -x "openbox" >/dev/null 2>&1
        fi
    }
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

setup_xfce_config() {
    mkdir -p /root/Desktop /root/Downloads /root/Documents

    cat > /root/Desktop/Terminal.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Comment=Open Linxr Terminal
Exec=xfce4-terminal
Icon=utilities-terminal
Path=
Terminal=false
StartupNotify=true
EOF
    chmod +x /root/Desktop/Terminal.desktop

    cat > /root/Desktop/Files.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=File Manager
Comment=Browse files and storage
Exec=thunar /root
Icon=system-file-manager
Path=
Terminal=false
StartupNotify=true
EOF
    chmod +x /root/Desktop/Files.desktop

    cat > /root/Desktop/SharedFolder.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Phone Storage (LinxrShare)
Comment=Access Android shared storage
Exec=thunar /mnt/sdcard
Icon=folder-remote
Path=
Terminal=false
StartupNotify=true
EOF
    chmod +x /root/Desktop/SharedFolder.desktop

    mkdir -p /root/.config/gtk-3.0
    cat > /root/.config/gtk-3.0/settings.ini <<'EOF'
[Settings]
gtk-theme-name = Adwaita-dark
gtk-icon-theme-name = Adwaita
gtk-font-name = DejaVu Sans 10
gtk-application-prefer-dark-theme = true
EOF
}

cmd_status() {
    WM_REQ="${1:-$(get_wm)}"
    INSTALLED="false"
    RUNNING="false"
    RES=$(get_res)
    WM=$(get_wm)

    OPENBOX_INSTALLED="false"
    XFCE_INSTALLED="false"

    command -v openbox >/dev/null 2>&1 && OPENBOX_INSTALLED="true"
    (command -v startxfce4 >/dev/null 2>&1 || command -v xfwm4 >/dev/null 2>&1) && XFCE_INSTALLED="true"

    if is_installed "$WM_REQ"; then
        INSTALLED="true"
    fi

    if is_running "$WM"; then
        RUNNING="true"
    fi

    cat <<EOF
{
  "installed": $INSTALLED,
  "running": $RUNNING,
  "openbox_installed": $OPENBOX_INSTALLED,
  "xfce_installed": $XFCE_INSTALLED,
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
    killall -9 apk 2>/dev/null || true
    rm -f /lib/apk/db/lock 2>/dev/null || true
    grep -q "dl-cdn.alpinelinux.org" /etc/hosts 2>/dev/null || echo "199.232.114.132 dl-cdn.alpinelinux.org" >> /etc/hosts
    sed -i 's/\r$//' /etc/apk/repositories 2>/dev/null || true
    sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true
    apk update >/dev/null 2>&1 || true

    if [ "$MODE" = "xfce" ] || [ "$MODE" = "xfce4" ] || [ "$MODE" = "full" ]; then
        if ! apk add --no-cache xvfb x11vnc novnc websockify \
            xfce4 xfce4-terminal thunar mousepad xfce4-appfinder \
            dbus dbus-x11 \
            font-dejavu font-noto font-misc-misc \
            adwaita-icon-theme hicolor-icon-theme; then
            echo "Error: Failed to install XFCE4 desktop packages." >&2
            exit 1
        fi
        setup_xfce_config
    else
        if ! apk add --no-cache xvfb x11vnc novnc websockify \
            openbox tint2 pcmanfm mousepad xterm \
            font-dejavu font-misc-misc \
            adwaita-icon-theme hicolor-icon-theme; then
            echo "Error: Failed to install Openbox desktop packages." >&2
            exit 1
        fi
        setup_openbox_config
    fi

    echo "Installation finished."
    cmd_status "$MODE"
}

cmd_stop() {
    echo "Stopping Linxr Virtual Desktop..."
    pkill -f "websockify" 2>/dev/null || true
    pkill -f "x11vnc" 2>/dev/null || true
    pkill -x "tint2" 2>/dev/null || true
    pkill -x "openbox" 2>/dev/null || true
    pkill -f "dbus-daemon.*session" 2>/dev/null || true
    pkill -f "xfce4-session" 2>/dev/null || true
    pkill -x "xfwm4" 2>/dev/null || true
    pkill -x "xfce4-panel" 2>/dev/null || true
    pkill -x "xfdesktop" 2>/dev/null || true
    pkill -x "xfsettingsd" 2>/dev/null || true
    pkill -x "startxfce4" 2>/dev/null || true
    pkill -f "Xvfb.*$DISPLAY_NUM" 2>/dev/null || true
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
    echo "Virtual Desktop stopped."
    cmd_status
}

cmd_start() {
    RES="${1:-$DEFAULT_RES}"
    WM="${2:-$DEFAULT_WM}"

    if ! is_installed "$WM"; then
        echo "Packages missing for $WM. Auto-installing..."
        if ! cmd_install "$WM"; then
            echo "Error: Auto-install failed for $WM." >&2
            exit 1
        fi
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

    if [ "$WM" = "xfce4" ] || [ "$WM" = "xfce" ] || [ "$WM" = "full" ]; then
        echo "Starting XFCE4 session..."
        setup_xfce_config
        mkdir -p /var/run/dbus 2>/dev/null || true
        dbus-uuidgen --ensure 2>/dev/null || true

        if command -v dbus-run-session >/dev/null 2>&1; then
            dbus-run-session startxfce4 </dev/null >/tmp/xfce4-session.log 2>&1 &
        elif command -v dbus-launch >/dev/null 2>&1; then
            dbus-launch --exit-with-session startxfce4 </dev/null >/tmp/xfce4-session.log 2>&1 &
        else
            startxfce4 </dev/null >/tmp/xfce4-session.log 2>&1 &
        fi
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

    sleep 2
    if ! is_running "$WM"; then
        echo "Error: Virtual Desktop failed to start ($WM)" >&2
        cmd_status "$WM"
        exit 1
    fi

    echo "Linxr Virtual Desktop started successfully on $DISPLAY_NUM ($RES, $WM)."
    cmd_status "$WM"
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

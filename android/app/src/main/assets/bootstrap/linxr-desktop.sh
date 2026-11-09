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
    ([ -x /usr/bin/Xvfb ] || [ -x /usr/local/bin/Xvfb ]) && \
    ([ -x /usr/bin/x11vnc ] || [ -x /usr/local/bin/x11vnc ]) && \
    ([ -x /usr/bin/websockify ] || [ -x /usr/local/bin/websockify ]) && \
    [ -d "/usr/share/novnc" ] && {
        if [ "$WM_TARGET" = "xfce4" ] || [ "$WM_TARGET" = "xfce" ] || [ "$WM_TARGET" = "full" ]; then
            [ -x /usr/bin/startxfce4 ] || [ -x /usr/bin/xfwm4 ] || [ -x /usr/local/bin/xfwm4 ]
        else
            [ -x /usr/bin/openbox ] || [ -x /usr/local/bin/openbox ]
        fi
    }
}

is_running() {
    WM_TARGET="${1:-$(get_wm)}"
    [ -e "/tmp/.X11-unix/X1" ] || [ -f "/tmp/.X1-lock" ] || return 1

    if [ -f "$PID_FILE" ]; then
        for pid in $(cat "$PID_FILE" 2>/dev/null); do
            kill -0 "$pid" 2>/dev/null && return 0
        done
        return 1
    fi

    if [ "$WM_TARGET" = "xfce4" ] || [ "$WM_TARGET" = "xfce" ] || [ "$WM_TARGET" = "full" ]; then
        grep -qsE "^(xfwm4|xfce4-panel|xfdesktop|xfce4-session|Xvfb)\$" /proc/[0-9]*/comm 2>/dev/null
    else
        grep -qsE "^(openbox|Xvfb)\$" /proc/[0-9]*/comm 2>/dev/null
    fi
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
Path=/root
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
Path=/root
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
Path=/mnt/sdcard
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

    mkdir -p /root/.config/xfce4/xfconf/xfce-perchannel-xml
    cat > /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
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

    cat > /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="32"/>
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

    cat > /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Default-hdpi"/>
    <property name="title_font" type="string" value="DejaVu Sans Bold 10"/>
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF

    cat > /root/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita-dark"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
    <property name="DoubleClickHandlerTime" type="int" value="400"/>
    <property name="DoubleClickHandlerDistance" type="int" value="5"/>
    <property name="Dpi" type="int" value="96"/>
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

cmd_status() {
    WM_REQ="${1:-$(get_wm)}"
    INSTALLED="false"
    RUNNING="false"
    CURR_RES=$(get_res)
    CURR_WM=$(get_wm)

    OPENBOX_INSTALLED="false"
    XFCE_INSTALLED="false"

    ([ -x /usr/bin/openbox ] || [ -x /usr/local/bin/openbox ]) && OPENBOX_INSTALLED="true"
    ([ -x /usr/bin/startxfce4 ] || [ -x /usr/bin/xfwm4 ] || [ -x /usr/local/bin/xfwm4 ]) && XFCE_INSTALLED="true"

    if is_installed "$WM_REQ"; then
        INSTALLED="true"
    fi

    if is_running "$CURR_WM"; then
        RUNNING="true"
    fi

    cat <<EOF
{
  "installed": $INSTALLED,
  "running": $RUNNING,
  "openbox_installed": $OPENBOX_INSTALLED,
  "xfce_installed": $XFCE_INSTALLED,
  "display": "$DISPLAY_NUM",
  "resolution": "$CURR_RES",
  "wm": "$CURR_WM",
  "web_port": 6080,
  "vnc_port": 5900,
  "web_url": "http://localhost:6080/vnc.html?autoconnect=true&resize=scale&show_dot=true&reconnect=true&path=websockify"
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
            adwaita-icon-theme hicolor-icon-theme \
            gsettings-desktop-schemas xrdb; then
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
    if [ -f "$PID_FILE" ]; then
        for pid in $(cat "$PID_FILE" 2>/dev/null); do
            kill -9 "$pid" 2>/dev/null || true
        done
        rm -f "$PID_FILE"
    fi
    if [ -f "/tmp/.linxr_websockify.pid" ]; then
        kill -9 $(cat /tmp/.linxr_websockify.pid 2>/dev/null) 2>/dev/null || true
        rm -f /tmp/.linxr_websockify.pid
    fi

    # Single-pass cleanup for any remaining desktop processes
    pkill -9 -f websockify 2>/dev/null || true
    killall -9 xfce4-session xfwm4 xfce4-panel xfdesktop xfsettingsd xfce4-power-manager startxfce4 openbox tint2 xterm pcmanfm mousepad websockify x11vnc Xvfb 2>/dev/null || true

    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 "$PID_FILE" 2>/dev/null || true
    echo "Virtual Desktop stopped."
    cmd_status
}

cmd_start() {
    TARGET_RES="${1:-$DEFAULT_RES}"
    TARGET_WM="${2:-$DEFAULT_WM}"

    if ! is_installed "$TARGET_WM"; then
        echo "Packages missing for $TARGET_WM. Auto-installing..."
        if ! cmd_install "$TARGET_WM"; then
            echo "Error: Auto-install failed for $TARGET_WM." >&2
            exit 1
        fi
    fi

    cmd_stop >/dev/null 2>&1
    sleep 1

    echo "$TARGET_RES" > "$RES_FILE"
    echo "$TARGET_WM" > "$WM_FILE"

    echo "Starting Xvfb on $DISPLAY_NUM with resolution $TARGET_RES..."
    Xvfb "$DISPLAY_NUM" -screen 0 "${TARGET_RES}x24" -nocursor </dev/null >/dev/null 2>&1 &
    XPID=$!

    # Wait for X display socket to be ready
    for i in 1 2 3 4 5; do
        if [ -e "/tmp/.X11-unix/X1" ] || [ -f "/tmp/.X1-lock" ]; then
            break
        fi
        sleep 0.5
    done

    export DISPLAY="$DISPLAY_NUM"
    export NO_AT_BRIDGE=1
    export GTK_A11Y=none
    export QT_ACCESSIBILITY=0

    if [ "$TARGET_WM" = "xfce4" ] || [ "$TARGET_WM" = "xfce" ] || [ "$TARGET_WM" = "full" ]; then
        echo "Starting XFCE4 desktop..."
        setup_xfce_config
        mkdir -p /var/run/dbus 2>/dev/null || true
        dbus-uuidgen --ensure 2>/dev/null || true

        if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
            eval $(dbus-launch --sh-syntax 2>/dev/null)
            export DBUS_SESSION_BUS_ADDRESS
        fi

        xfsettingsd </dev/null >/tmp/xfsettingsd.log 2>&1 &
        xfwm4 </dev/null >/tmp/xfwm4.log 2>&1 &
        WMPID=$!
        sleep 1

        xfce4-panel --disable-wm-check </dev/null >/tmp/xfce4-panel.log 2>&1 &
        PANELPID=$!
        xfdesktop --disable-wm-check </dev/null >/tmp/xfdesktop.log 2>&1 &
        DESKTOPPID=$!
    else
        echo "Starting Openbox window manager..."
        setup_openbox_config
        openbox </dev/null >/dev/null 2>&1 &
        WMPID=$!
        if command -v tint2 >/dev/null 2>&1; then
            tint2 </dev/null >/dev/null 2>&1 &
            PANELPID=$!
        fi
        if command -v xterm >/dev/null 2>&1; then
            xterm -geometry 80x24+40+50 -title "Linxr Terminal" -e bash </dev/null >/dev/null 2>&1 &
        fi
    fi

    # Eliminate reverse-DNS lookup latency (socket.getfqdn) on private SLIRP network connections
    grep -q "10.0.2.2" /etc/hosts 2>/dev/null || echo "10.0.2.2 android-host gateway" >> /etc/hosts

    # Ensure noVNC index.html symlink exists
    [ -f /usr/share/novnc/vnc.html ] && [ ! -f /usr/share/novnc/index.html ] && ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

    # Patch /usr/local/bin/websockify to force fork start method under Python 3.14
    if [ -f "/usr/local/bin/websockify" ] && ! grep -q "set_start_method('fork'" /usr/local/bin/websockify 2>/dev/null; then
        sed -i 's/from websockify/import multiprocessing\ntry:\n    multiprocessing.set_start_method("fork", force=True)\nexcept Exception:\n    pass\nfrom websockify/' /usr/local/bin/websockify 2>/dev/null || true
    fi

    echo "Starting x11vnc server on port 5900..."
    x11vnc -display "$DISPLAY_NUM" -nopw -rfbport 5900 -forever -shared -wait 80 -defer 80 </dev/null >/tmp/x11vnc.log 2>&1 &
    VNCPID=$!

    echo "Starting websockify noVNC bridge on port 6080..."
    pkill -9 -f websockify 2>/dev/null || true
    /usr/local/bin/websockify --web /usr/share/novnc 0.0.0.0:6080 127.0.0.1:5900 </dev/null >/tmp/websockify.log 2>&1 &
    WPID=$!
    echo "$WPID" > /tmp/.linxr_websockify.pid
    echo "$XPID $WMPID $PANELPID $DESKTOPPID $VNCPID $WPID" > "$PID_FILE"

    # Wait for desktop session and window manager to be up
    STARTED=0
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if is_running "$TARGET_WM"; then
            STARTED=1
            break
        fi
        sleep 1
    done

    if [ "$STARTED" -ne 1 ]; then
        echo "Error: Virtual Desktop failed to start ($TARGET_WM)" >&2
        cmd_status "$TARGET_WM"
        exit 1
    fi

    echo "Linxr Virtual Desktop started successfully on $DISPLAY_NUM ($TARGET_RES, $TARGET_WM)."
    cmd_status "$TARGET_WM"
}

cmd_launch_app() {
    APP="$1"
    export DISPLAY="$DISPLAY_NUM"
    case "$APP" in
        terminal)
            if command -v xfce4-terminal >/dev/null 2>&1; then
                xfce4-terminal </dev/null >/dev/null 2>&1 &
            else
                xterm -geometry 85x26 -title "Linxr Terminal" -e bash </dev/null >/dev/null 2>&1 &
            fi
            ;;
        files)
            if command -v thunar >/dev/null 2>&1; then
                thunar /root </dev/null >/dev/null 2>&1 &
            elif command -v pcmanfm >/dev/null 2>&1; then
                pcmanfm /root </dev/null >/dev/null 2>&1 &
            fi
            ;;
        editor)
            if command -v mousepad >/dev/null 2>&1; then
                mousepad </dev/null >/dev/null 2>&1 &
            elif command -v leafpad >/dev/null 2>&1; then
                leafpad </dev/null >/dev/null 2>&1 &
            fi
            ;;
        calculator)
            if command -v gnome-calculator >/dev/null 2>&1; then
                gnome-calculator </dev/null >/dev/null 2>&1 &
            elif command -v galculator >/dev/null 2>&1; then
                galculator </dev/null >/dev/null 2>&1 &
            elif command -v xcalc >/dev/null 2>&1; then
                xcalc </dev/null >/dev/null 2>&1 &
            fi
            ;;
        *)
            if [ -n "$APP" ]; then
                eval "$APP" </dev/null >/dev/null 2>&1 &
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

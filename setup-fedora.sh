#!/usr/bin/env bash
#
# setup-fedora.sh — Reconstruye MI sistema sobre un Fedora MÍNIMO.
# ---------------------------------------------------------------------------
# Hermano de setup.sh (Debian). Misma filosofía: en vez de "capturar" el estado,
# APLICA el estado que quiero partiendo de un Fedora recién instalado con el
# entorno "Fedora Custom Operating System" + grupo "Standard" (sin escritorio).
#
# DIFERENCIA CLAVE con setup.sh: acá el escritorio se instala LIMPIO y se
# configura a mano después. NO restaura configuración de escritorio, porque la
# de KDE (kwinrc, kglobalshortcutsrc, appletsrc…) no aplica a GNOME. Solo
# restaura lo que es realmente mío e independiente del entorno.
#
# USO:
#   bash setup-fedora.sh                  → setup completo con GNOME (default)
#   bash setup-fedora.sh kde              → idem pero con KDE Plasma pelado
#   bash setup-fedora.sh --no-flatpak     → sin Flatpaks (iteración rápida en VM)
#   bash setup-fedora.sh quarks [ruta]    → SOLO restaura los secretos de Quarks
#
# IDEMPOTENTE: corrélo cuantas veces quieras. Al final imprime un RESUMEN con
# todo lo que haya fallado.
#
# Corré como TU usuario (NO root); pedirá sudo cuando haga falta.
# ---------------------------------------------------------------------------
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Parseo de argumentos ────────────────────────────────────────────────────
DESKTOP="gnome"      # gnome | kde
MODE="all"           # all | quarks
SKIP_FLATPAK=0
QUARKS_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    gnome|kde)     DESKTOP="$1" ;;
    quarks)        MODE="quarks" ;;
    --no-flatpak)  SKIP_FLATPAK=1 ;;
    -h|--help)     sed -n '3,26p' "$0"; exit 0 ;;
    *)             [ "$MODE" = "quarks" ] && QUARKS_PATH="$1" || { echo "✗ Argumento desconocido: $1"; exit 1; } ;;
  esac
  shift
done

if [ "$(id -u)" -eq 0 ]; then
  echo "✗ No lo corras como root. Corrélo como tu usuario; pedirá sudo solo."
  exit 1
fi

WARNINGS=()
warn() { echo "⚠ $*"; WARNINGS+=("$*"); }

# ═══════════════════════════════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════════════════════════════

# Instala paquetes con dnf de forma RESILIENTE. dnf5 tiene --skip-unavailable,
# que instala lo que encuentra en vez de abortar la transacción entera si un
# nombre está mal (el equivalente al reintento uno-por-uno de apt_install).
# Después VERIFICA con rpm y avisa de los que no quedaron, usando
# --whatprovides para que los nombres virtuales (ej. 'npm') no den falso
# negativo.
dnf_install() {
  local p missing=()
  sudo dnf install -y --skip-unavailable "$@" \
    || warn "La transacción de dnf terminó con errores; verifico paquete por paquete…"
  for p in "$@"; do
    case "$p" in @*) continue ;; esac   # los grupos no se verifican con rpm
    rpm -q --whatprovides "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "No se instalaron: ${missing[*]}"
  fi
}

# Instala Flatpaks de Flathub. No frena si uno falla.
flatpak_install() {
  [ "$SKIP_FLATPAK" -eq 1 ] && { echo "==> (--no-flatpak: salteo los Flatpaks.)"; return 0; }
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  local app
  for app in "$@"; do
    sudo flatpak install -y flathub "$app" || warn "Flatpak $app no se instaló; reintentá luego."
  done
}

# ═══════════════════════════════════════════════════════════════════════════
#  REPOS — Fedora viene sin códecs ni software propietario. Esto va PRIMERO.
# ═══════════════════════════════════════════════════════════════════════════
enable_repos() {
  echo "==> Habilitando repos de terceros…"
  local fv; fv="$(rpm -E %fedora)"

  # RPM Fusion (free + nonfree): códecs, gstreamer1-libav, ffmpeg completo.
  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    sudo dnf install -y \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$fv.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$fv.noarch.rpm" \
      || warn "No pude habilitar RPM Fusion (sin él faltan códecs)."
  else
    echo "    RPM Fusion ya está habilitado."
  fi

  # Terra (Fyra Labs): única fuente empaquetada de Helium para Fedora. imput
  # publica repo .deb oficial pero NO repo RPM, así que acá dependemos de Terra.
  if ! rpm -q terra-release >/dev/null 2>&1; then
    sudo dnf install -y --nogpgcheck \
      --repofrompath "terra,https://repos.fyralabs.com/terra$fv" \
      terra-release \
      || warn "No pude habilitar Terra (sin él no hay Helium empaquetado)."
  else
    echo "    Terra ya está habilitado."
  fi

  # VS Code: repo oficial de Microsoft.
  if [ ! -f /etc/yum.repos.d/vscode.repo ]; then
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc \
      || warn "No pude importar la key de Microsoft."
    printf '%s\n' \
      '[code]' \
      'name=Visual Studio Code' \
      'baseurl=https://packages.microsoft.com/yumrepos/vscode' \
      'enabled=1' \
      'autorefresh=1' \
      'gpgcheck=1' \
      'gpgkey=https://packages.microsoft.com/keys/microsoft.asc' \
      | sudo tee /etc/yum.repos.d/vscode.repo > /dev/null
  else
    echo "    Repo de VS Code ya está configurado."
  fi

  sudo dnf makecache || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  ESCRITORIO — pelado. La config va a mano después (ver cabecera).
# ═══════════════════════════════════════════════════════════════════════════
install_desktop() {
  local dm
  if [ "$DESKTOP" = "gnome" ]; then
    echo "==> Instalando GNOME (pelado) + GDM…"
    dnf_install @base-x gnome-shell gdm gnome-control-center gnome-tweaks \
                xdg-desktop-portal-gnome gnome-backgrounds \
                nautilus gnome-console gnome-text-editor file-roller \
                loupe papers gnome-calculator gnome-disk-utility gnome-software
    # GNOME no tiene bandeja del sistema por diseño. Sin esta extensión, el
    # icono de Discord (y cualquier otro AppIndicator) simplemente no aparece.
    dnf_install gnome-shell-extension-appindicator
    dm=gdm
  else
    echo "==> Instalando KDE Plasma (pelado) + SDDM…"
    dnf_install @base-x plasma-desktop plasma-workspace sddm \
                konsole dolphin kate ark gwenview okular spectacle kcalc \
                kde-partitionmanager kde-gtk-config kdegraphics-thumbnailers \
                plasma-discover plasma-discover-flatpak
    dm=sddm
  fi

  # Una instalación mínima arranca en modo texto: hay que pedirle gráfico.
  sudo systemctl enable "$dm" || warn "No pude habilitar $dm."
  sudo systemctl set-default graphical.target || warn "No pude fijar graphical.target."
}

# ═══════════════════════════════════════════════════════════════════════════
#  APPS comunes a los dos escritorios
# ═══════════════════════════════════════════════════════════════════════════
install_apps() {
  echo "==> Apps (dnf)…"
  dnf_install \
    `# utilidades` \
    input-remapper git rsync flatpak xdg-utils curl gnupg2 \
    `# multimedia (gstreamer1-libav viene de RPM Fusion)` \
    vlc yt-dlp ffmpegthumbnailer gstreamer1-plugins-good gstreamer1-libav \
    pipewire-alsa \
    `# oficina` \
    libreoffice \
    `# gaming` \
    gamemode mangohud winetricks \
    `# desarrollo — OJO: Fedora 44 SOLO tiene Java 25 en repos (no 17 ni 21),` \
    `# y npm viene atado a una versión concreta de nodejs.` \
    java-25-openjdk-devel python3-pip nodejs24 nodejs24-npm

  echo "==> Flatpaks…"
  flatpak_install \
    com.interversehq.qView \
    com.bitwarden.desktop \
    net.lutris.Lutris \
    com.discordapp.Discord \
    com.valvesoftware.Steam \
    com.obsproject.Studio \
    com.pokemmo.PokeMMO \
    org.prismlauncher.PrismLauncher \
    io.mgba.mGBA \
    network.loki.Session
    # -- Descomentar si lo querés de nuevo: --
    # com.google.AndroidStudio
}

# ═══════════════════════════════════════════════════════════════════════════
#  Software por su método oficial
# ═══════════════════════════════════════════════════════════════════════════
install_helium() {
  echo "==> Helium browser (repo Terra)…"
  if rpm -q helium-browser-bin >/dev/null 2>&1; then
    echo "    Helium ya está instalado."
  else
    dnf_install helium-browser-bin
  fi
}

install_claude() {
  echo "==> Claude Code (instalador nativo)…"
  if command -v claude >/dev/null 2>&1; then
    echo "    Claude Code ya está instalado."
  else
    curl -fsSL https://claude.ai/install.sh | bash \
      || warn "Claude Code no se instaló; reintentá: curl -fsSL https://claude.ai/install.sh | bash"
  fi
}

install_vscode() {
  echo "==> VS Code…"
  rpm -q code >/dev/null 2>&1 && { echo "    VS Code ya está instalado."; return 0; }
  dnf_install code
}

# GitHub Desktop (fork shiftkey/desktop) como .rpm NATIVO. La versión Flatpak
# falla en Wayland (la ventana no mapea: sandbox + wrapper zypak).
install_github_desktop() {
  echo "==> GitHub Desktop (.rpm nativo, shiftkey/desktop)…"
  if command -v github-desktop >/dev/null 2>&1; then
    echo "    GitHub Desktop ya está instalado."
    return 0
  fi
  local url tmp
  url="$(curl -fsSL https://api.github.com/repos/shiftkey/desktop/releases/latest 2>/dev/null \
        | grep -oE '"browser_download_url": "[^"]+x86_64[^"]*\.rpm"' | head -1 | cut -d'"' -f4)"
  if [ -z "$url" ]; then warn "No pude resolver la URL del .rpm de GitHub Desktop."; return 0; fi
  tmp="$(mktemp --suffix=.rpm)"
  if curl -fsSL "$url" -o "$tmp"; then
    sudo dnf install -y "$tmp" || warn "No se instaló GitHub Desktop (.rpm)."
  else
    warn "No pude descargar GitHub Desktop desde $url"
  fi
  rm -f "$tmp"
}

# Temas de iconos desde su fuente. Guard idempotente.
install_icons() {
  echo "==> Temas de iconos…"
  local tmp
  if [ ! -d "$HOME/.local/share/icons/Win11-dark" ]; then
    tmp="$(mktemp -d)"
    git clone --depth 1 https://github.com/yeyushengfan258/Win11-icon-theme "$tmp/w" \
      && bash "$tmp/w/install.sh"; rm -rf "$tmp"
  else
    echo "    Win11 ya está instalado."
  fi
  if [ ! -d "$HOME/.local/share/icons/Colloid" ]; then
    tmp="$(mktemp -d)"
    git clone --depth 1 https://github.com/vinceliuice/Colloid-icon-theme "$tmp/c" \
      && bash "$tmp/c/install.sh"; rm -rf "$tmp"
  else
    echo "    Colloid ya está instalado."
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  RESTORE — Helium (perfiles + lanzadores) y Quarks (secretos), desde el drive
# ═══════════════════════════════════════════════════════════════════════════
_helium_has_data() {
  local d="$1" h
  [ -f "$d/Default/Bookmarks" ] && return 0
  h="$d/Default/History"
  [ -f "$h" ] && [ "$(stat -c%s "$h" 2>/dev/null || echo 0)" -gt 1048576 ] && return 0
  return 1
}

# Usa rsync (NUNCA cp -a: si el destino existe, cp copia ADENTRO y anida el
# perfil). Respeta un perfil con datos; reemplaza uno vacío.
restore_helium() {
  local src="/mnt/Other/Backup/Helium/profiles"
  if [ ! -d "$src" ]; then
    echo "==> (Sin backup de Helium en $src; salteo el restore.)"
    return 0
  fi
  command -v rsync >/dev/null 2>&1 || dnf_install rsync
  echo "==> Restaurando perfiles de Helium desde $src…"
  local p name dst
  for p in "$src"/*; do
    [ -d "$p" ] || continue
    name="$(basename "$p")"
    dst="$HOME/.config/$name"
    if [ -d "$dst" ] && _helium_has_data "$dst"; then
      echo "    · $name ya tiene datos locales; no lo piso."
      continue
    fi
    if [ -d "$dst" ]; then
      echo "    · $name local está vacío; lo aparto (.vacio-*) y restauro del backup."
      mv "$dst" "$dst.vacio-$(date +%s)" || warn "No pude apartar el perfil vacío: $name"
    else
      echo "    · restaurando $name"
    fi
    mkdir -p "$dst"
    rsync -rlt --no-perms --no-owner --no-group --delete "$p/" "$dst/" \
      || warn "No pude restaurar el perfil de Helium: $name"
  done
}

# Lanzadores .desktop + iconos + script helium-profile de los perfiles AISLADOS.
# El nombre del binario cambia según la distro (Arch: helium-browser, Debian:
# helium, Fedora/Terra: a confirmar), así que lo DETECTAMOS y reescribimos solo
# el primer token del Exec — nunca el --class ni el Icon, que llevan el slug del
# perfil y romperían si les tocáramos el "helium-".
restore_helium_launchers() {
  local meta="/mnt/Other/Backup/Helium/launchers"
  if [ ! -d "$meta" ]; then
    echo "==> (Sin lanzadores de Helium en $meta; salteo.)"
    return 0
  fi
  echo "==> Restaurando lanzadores/iconos/script de perfiles aislados…"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons"

  # El nombre del ejecutable cambia según de dónde venga el paquete:
  #   Arch (AUR)      → helium-browser
  #   Debian (imput)  → helium
  #   Fedora (Terra)  → helium-browser-bin
  local bin
  bin="$(command -v helium-browser-bin || command -v helium-browser || command -v helium || true)"
  if [ -z "$bin" ]; then
    warn "No encuentro el binario de Helium; dejo los .desktop con el Exec original."
    bin="helium"
  else
    bin="$(basename "$bin")"
    echo "    binario detectado: $bin"
  fi

  if [ -f "$meta/bin/helium-profile" ]; then
    install -m 0755 "$meta/bin/helium-profile" "$HOME/.local/bin/helium-profile"
    # helium-profile trae su propia detección de binario, pero solo contempla
    # los nombres de Arch y Debian. Sin este parche, los perfiles aislados que
    # crees NUEVOS en Fedora apuntarían a un ejecutable inexistente.
    sed -i "s#^HELIUM_BIN=.*#HELIUM_BIN=\"\$(command -v helium-browser-bin || command -v helium-browser || command -v helium || echo helium)\"#" \
      "$HOME/.local/bin/helium-profile"
  fi
  [ -d "$meta/icons" ] && cp -a "$meta/icons/." "$HOME/.local/share/icons/" 2>/dev/null || true
  if [ -d "$meta/applications" ]; then
    local f
    for f in "$meta"/applications/helium-*.desktop; do
      [ -f "$f" ] || continue
      sed -E "s|^Exec=[^ ]+|Exec=$bin|" "$f" > "$HOME/.local/share/applications/$(basename "$f")"
    done
  fi
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
}

restore_quarks() {
  local src="/mnt/Other/Backup/Quarks"
  local proj="${QUARKS_PATH:-$HOME/Proyects/Quarks}"

  if [ ! -d "$src" ]; then
    echo "==> (Sin backup de Quarks en $src; nada que restaurar.)"
    return 0
  fi
  echo "==> Restaurando secretos de Quarks desde $src…"

  if [ -f "$src/tauri/quarks.key" ]; then
    install -D -m 600 "$src/tauri/quarks.key" "$HOME/.tauri/quarks.key" \
      || warn "No pude restaurar ~/.tauri/quarks.key"
    [ -f "$src/tauri/quarks.key.pub" ] \
      && install -D -m 644 "$src/tauri/quarks.key.pub" "$HOME/.tauri/quarks.key.pub"
    chmod 700 "$HOME/.tauri" 2>/dev/null || true
    echo "    ✓ clave de firma -> ~/.tauri/"
  else
    warn "No hay clave de firma en el backup ($src/tauri/quarks.key)."
  fi

  if [ -f "$src/config/com.quarks.app/quarks.env" ]; then
    install -D -m 600 "$src/config/com.quarks.app/quarks.env" \
      "$HOME/.config/com.quarks.app/quarks.env" || warn "No pude restaurar el .env de firma."
    chmod 700 "$HOME/.config/com.quarks.app" 2>/dev/null || true
    echo "    ✓ .env de firma -> ~/.config/com.quarks.app/"
  else
    warn "No hay .env de firma en el backup."
  fi

  if [ -f "$src/project/core/.env" ]; then
    if [ -d "$proj/core" ]; then
      install -D -m 600 "$src/project/core/.env" "$proj/core/.env" \
        || warn "No pude restaurar core/.env en $proj."
      echo "    ✓ core/.env -> $proj/core/.env"
    else
      warn "No encuentro el repo de Quarks en '$proj'. Cloná el repo y corré: bash setup-fedora.sh quarks /ruta/al/repo"
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  CONFIGS — SOLO lo agnóstico del escritorio (ver cabecera)
# ═══════════════════════════════════════════════════════════════════════════
restore_home_agnostic() {
  [ -d "$DIR/home" ] || return 0
  echo "==> Restaurando configs independientes del escritorio…"

  # input-remapper (a nivel de dispositivo) y el layout xkb propio.
  #
  # .config/autostart QUEDÓ AFUERA a propósito: de las dos entradas que había,
  # Quarks.desktop apuntaba a un AppImage que ya no existe (fallaba en silencio
  # en cada login) y la de Bitwarden la regenera sola el portal XDG cuando le
  # activás el inicio automático desde la app. No hay nada que restaurar ahí.
  local rel
  for rel in ".config/input-remapper-2" ".config/xkb"; do
    if [ -d "$DIR/home/$rel" ]; then
      mkdir -p "$HOME/$(dirname "$rel")"
      cp -a "$DIR/home/$rel" "$HOME/$(dirname "$rel")/"
      echo "    ✓ $rel"
    fi
  done

  # .bash_aliases: en Debian lo carga el .bashrc del skel, pero el de FEDORA NO.
  # Fedora usa ~/.bashrc.d/*, así que dejamos el shim ahí en vez de parchear el
  # .bashrc (que se sobrescribe al actualizar el paquete).
  if [ -f "$DIR/home/.bash_aliases" ]; then
    cp -a "$DIR/home/.bash_aliases" "$HOME/.bash_aliases"
    mkdir -p "$HOME/.bashrc.d"
    printf '%s\n' \
      '# Cargado por el .bashrc de Fedora, que (a diferencia del de Debian)' \
      '# no lee ~/.bash_aliases por su cuenta.' \
      '[ -f "$HOME/.bash_aliases" ] && . "$HOME/.bash_aliases"' \
      > "$HOME/.bashrc.d/aliases.sh"
    echo "    ✓ .bash_aliases (+ shim en ~/.bashrc.d/)"
  fi

  # NO se restaura nada de KDE (kwinrc, kdeglobals, kglobalshortcutsrc,
  # appletsrc, aurorae, color-schemes…) ni los GTK generados por kde-gtk-config:
  # bajo GNOME no aplican y los GTK pelearían con Adwaita. Siguen en el repo
  # intactos por si volvés a Plasma.
}

# ═══════════════════════════════════════════════════════════════════════════
#  SISTEMA — system/ -> / + servicios. OJO con SELinux.
# ═══════════════════════════════════════════════════════════════════════════
install_system() {
  if [ -d "$DIR/system" ]; then
    echo "==> Fixes de sistema (system/ -> /): joystick + uinput + teclado SONiX…"

    # NUNCA 'cp -a system/. /' — ese es el bug que tiene setup.sh en Debian.
    # cp -a preserva dueño y permisos del ORIGEN, y al recorrer directorios que
    # YA EXISTEN en el destino les aplica los del repo. Como el repo es tuyo
    # (michisama:michisama 775), el resultado es /etc, /etc/systemd/system,
    # /etc/modprobe.d y /usr/local/bin pasando a ser propiedad de tu usuario y
    # escribibles por él → escalada a root trivial. En Fedora además rompe sudo
    # y sshd en el acto.
    #
    # 'install -D' crea los directorios padre que falten pero NO toca los que ya
    # existen, y fija dueño/permisos de cada archivo de forma explícita.
    local f rel mode
    while IFS= read -r -d '' f; do
      rel="${f#"$DIR/system/"}"
      case "$rel" in
        usr/local/bin/*) mode=755 ;;   # scripts ejecutables
        *)               mode=644 ;;   # units, confs
      esac
      sudo install -D -o root -g root -m "$mode" "$f" "/$rel" \
        || warn "No pude instalar /$rel"
    done < <(find "$DIR/system" -type f -print0)

    # CRÍTICO en Fedora: los archivos copiados con cp -a heredan el contexto
    # SELinux del ORIGEN (el drive), no el que les corresponde en /. Sin este
    # restorecon, systemd se niega a cargar la unit y el servicio no arranca —
    # y el error que tira no menciona SELinux, así que es dificilísimo de
    # diagnosticar. En Debian este paso no existe (no hay SELinux).
    sudo restorecon -R /etc/systemd/system /etc/modprobe.d /etc/modules-load.d /usr/local/bin 2>/dev/null \
      || warn "restorecon falló; si un servicio no arranca, es por contexto SELinux."

    sudo systemctl daemon-reload
  fi

  if systemctl list-unit-files sonix-keyboard-fix.service >/dev/null 2>&1; then
    sudo systemctl enable sonix-keyboard-fix.service 2>/dev/null \
      || echo "  (sonix-keyboard-fix: ya estaba habilitado)"
  fi
  if systemctl list-unit-files input-remapper.service >/dev/null 2>&1; then
    sudo systemctl enable --now input-remapper.service 2>/dev/null \
      || echo "  (input-remapper: ya venía habilitado)"
  fi
  # input-remapper necesita /dev/uinput. El archivo system/etc/modules-load.d/
  # uinput.conf lo carga en cada arranque; acá lo cargamos YA.
  sudo modprobe uinput 2>/dev/null \
    || echo "  (uinput: se cargará en el próximo arranque)"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Apps por defecto
# ═══════════════════════════════════════════════════════════════════════════
set_defaults() {
  echo "==> Apps por defecto…"
  local pdf img
  if [ "$DESKTOP" = "gnome" ]; then
    pdf="org.gnome.Papers.desktop"; img="org.gnome.Loupe.desktop"
  else
    pdf="org.kde.okular.desktop";   img="com.interversehq.qView.desktop"
  fi
  xdg-mime default "$pdf" application/pdf 2>/dev/null || true
  xdg-mime default vlc.desktop \
    video/mp4 video/x-matroska video/webm video/quicktime \
    video/x-msvideo video/mpeg video/x-flv video/3gpp video/ogg 2>/dev/null || true
  xdg-mime default "$img" \
    image/jpeg image/png image/gif image/webp image/bmp image/tiff image/svg+xml 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  SETUP
# ═══════════════════════════════════════════════════════════════════════════
do_setup() {
  echo "==> Actualizando el sistema…"
  sudo dnf upgrade -y || warn "El upgrade inicial falló; sigo igual."

  enable_repos
  install_desktop
  install_apps

  install_helium
  install_claude
  install_vscode
  install_github_desktop

  restore_helium
  restore_helium_launchers

  # Temas de iconos: solo en KDE. En GNOME no los uso (queda Adwaita de fábrica).
  # Va como 'if' y no como '[ ... ] && install_icons' porque con set -e un test
  # que da falso devuelve 1 y aborta el script entero.
  if [ "$DESKTOP" = "kde" ]; then
    install_icons
  else
    echo "==> (GNOME: salteo los temas de iconos.)"
  fi

  restore_home_agnostic
  set_defaults
  install_system

  # Dejar el comando 'backup' a mano.
  mkdir -p "$HOME/.local/bin"
  ln -sf "$DIR/backup.sh" "$HOME/.local/bin/backup"

  # ── Joystick Xbox (driver xone) — SOLO en la PC real, no en la VM ─────────
  # dnf_install dkms git
  # git clone https://github.com/dlundqvist/xone /tmp/xone
  # ( cd /tmp/xone && sudo ./install.sh ) && sudo xone-get-firmware.sh --skip-disclaimer
  # rm -rf /tmp/xone

  echo "== Setup listo (escritorio: $DESKTOP). =="
}

# ═══════════════════════════════════════════════════════════════════════════
#  RUN + RESUMEN
# ═══════════════════════════════════════════════════════════════════════════
case "$MODE" in
  all)    do_setup ;;
  quarks) restore_quarks ;;
esac

echo
echo "════════════════════════════ RESUMEN ════════════════════════════"
if [ "${#WARNINGS[@]}" -eq 0 ]; then
  echo "✅ ¡Listo! Sin avisos."
else
  echo "⚠ Terminó con ${#WARNINGS[@]} aviso(s) — revisá esto:"
  for w in "${WARNINGS[@]}"; do echo "   • $w"; done
fi
if [ "$MODE" = "all" ]; then
  echo
  echo "   Reiniciá para entrar al escritorio ($DESKTOP)."
  if [ "$DESKTOP" = "gnome" ]; then
    echo "   Pendiente a mano tras el primer login:"
    echo "     · activar la extensión AppIndicator (bandeja: Discord, Bitwarden)"
    echo "     · activar tu layout de teclado propio de ~/.config/xkb"
    echo "       (GNOME no lo muestra en la interfaz; va por gsettings)"
  fi
fi
echo "═════════════════════════════════════════════════════════════════"

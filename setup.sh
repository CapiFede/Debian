#!/usr/bin/env bash
#
# setup.sh — Reconstruye MI Debian, a mi gusto, desde un fresh install.
# ---------------------------------------------------------------------------
# En vez de "capturar" el estado, APLICA el estado que quiero, partiendo de un
# Debian mínimo (sin escritorio).
#
# USO:
#   bash setup.sh   → instala y configura TODO de una: escritorio KDE + mis
#                     configs + mis apps de siempre (KDE, multimedia, oficina,
#                     gaming, navegador, VS Code, GitHub Desktop, Discord,
#                     Claude Code…).
#
#   bash setup.sh quarks [ruta-al-repo]
#                 → NO instala nada: SOLO restaura los secretos de Quarks (clave
#                   de firma + los .env) desde el drive. Asumo que YA clonaste el
#                   repo de código: pasá su ruta o uso el default (~/Proyects/
#                   Quarks). Los respalda backup.sh (modo quarks).
#
# IDEMPOTENTE: se puede correr cuantas veces quieras; instala/aplica solo lo que
# falta. Al final imprime un RESUMEN con lo que haya fallado (si algo falla).
#
# Corré como TU usuario (NO root); pedirá sudo cuando haga falta.
# ---------------------------------------------------------------------------
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-all}"          # all (default: setup completo) | quarks (solo secretos)

if [ "$(id -u)" -eq 0 ]; then
  echo "✗ No lo corras como root. Corrélo como tu usuario; pedirá sudo solo."
  exit 1
fi

# Acumulador de avisos, para un RESUMEN al final (así no tenés que leer todo el
# log para saber si algo falló).
WARNINGS=()
warn() { echo "⚠ $*"; WARNINGS+=("$*"); }

# ═══════════════════════════════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════════════════════════════

# Instala paquetes apt de forma RESILIENTE: instala los que existen y avisa
# (sin abortar) de los que no encuentra. Así un nombre equivocado no frena todo.
apt_install() {
  local ok=() miss=() p cand
  for p in "$@"; do
    # ¿Tiene un candidato REALMENTE instalable? No alcanza con 'apt-cache show':
    # un paquete puede figurar en el índice pero con 'Candidate: (none)' —p. ej.
    # winetricks sin el componente 'contrib' habilitado— y eso hace fallar el
    # 'apt install' entero (transacción atómica), que con 'set -e' aborta TODO.
    cand="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')"
    if [ -n "$cand" ] && [ "$cand" != "(none)" ]; then ok+=("$p"); else miss+=("$p"); fi
  done
  if [ "${#ok[@]}" -gt 0 ]; then
    # Si el lote falla por lo que sea, reintentamos UNO POR UNO para que un
    # paquete problemático no se lleve puestos a los demás (ni aborte el script).
    if ! sudo apt install -y "${ok[@]}"; then
      warn "Falló la instalación en lote; reintento individual…"
      for p in "${ok[@]}"; do
        sudo apt install -y "$p" || warn "No se instaló: $p"
      done
    fi
  fi
  if [ "${#miss[@]}" -gt 0 ]; then
    warn "Paquetes sin candidato instalable (¿falta un componente como 'contrib'/'non-free', o el nombre está mal?): ${miss[*]}"
  fi
}

# Instala Flatpaks de Flathub (asegura el remote primero). No frena si uno falla.
flatpak_install() {
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  local app
  for app in "$@"; do
    sudo flatpak install -y flathub "$app" || warn "Flatpak $app no se instaló; reintentá luego."
  done
}

# Temas de iconos desde su fuente. Guard idempotente: si ya están, no re-descarga.
install_icons() {
  echo "==> Temas de iconos…"
  if [ ! -d "$HOME/.local/share/icons/Win11-dark" ]; then
    local tmp; tmp="$(mktemp -d)"
    git clone --depth 1 https://github.com/yeyushengfan258/Win11-icon-theme "$tmp/w"
    bash "$tmp/w/install.sh"; rm -rf "$tmp"
  else
    echo "    Win11 ya está instalado."
  fi
  if [ ! -d "$HOME/.local/share/icons/Colloid" ]; then
    local tmp; tmp="$(mktemp -d)"
    git clone --depth 1 https://github.com/vinceliuice/Colloid-icon-theme "$tmp/c"
    bash "$tmp/c/install.sh"; rm -rf "$tmp"
  else
    echo "    Colloid ya está instalado."
  fi
}

# Helium browser (repo apt oficial de imput). Idempotente: solo baja la key si
# falta; el repo se re-escribe igual; apt no re-instala si ya está.
install_helium() {
  echo "==> Helium browser (repo oficial)…"
  if [ ! -f /usr/share/keyrings/helium.gpg ]; then
    curl -fsSL https://raw.githubusercontent.com/imputnet/helium-linux/main/pubkey.asc \
      | sudo gpg --dearmor -o /usr/share/keyrings/helium.gpg
  fi
  echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/helium.gpg] https://pkg.helium.computer/deb stable main" \
    | sudo tee /etc/apt/sources.list.d/helium.list > /dev/null
  sudo apt update
  apt_install helium-bin
}

# Claude Code (instalador nativo oficial; NO necesita Node.js). Auto-actualiza.
install_claude() {
  echo "==> Claude Code (instalador nativo)…"
  if command -v claude >/dev/null 2>&1; then
    echo "    Claude Code ya está instalado."
  else
    curl -fsSL https://claude.ai/install.sh | bash \
      || warn "Claude Code no se instaló; reintentá: curl -fsSL https://claude.ai/install.sh | bash"
  fi
}

# ¿un perfil tiene datos REALES? (marcadores presentes, o historial > 1 MB).
# Sirve para NO pisar un perfil vivo, pero SÍ reemplazar uno fresco/vacío que
# Helium haya creado si lo abriste antes de restaurar (ese fue el bug que anidó
# el perfil la primera vez).
_helium_has_data() {
  local d="$1" h
  [ -f "$d/Default/Bookmarks" ] && return 0
  h="$d/Default/History"
  [ -f "$h" ] && [ "$(stat -c%s "$h" 2>/dev/null || echo 0)" -gt 1048576 ] && return 0
  return 1
}

# Restaura los perfiles de Helium desde el drive Other. Usa rsync (NUNCA cp -a:
# si el destino ya existe, cp copia ADENTRO y te anida el perfil). Respeta un
# perfil con datos; reemplaza uno vacío (lo aparta como .vacio-* por las dudas).
# Si el drive no está montado o no hay backup, no hace nada. Los genera backup.sh.
restore_helium() {
  local src="/mnt/Other/Backup/Helium/profiles"
  if [ ! -d "$src" ]; then
    echo "==> (Sin backup de Helium en $src; salteo el restore.)"
    return 0
  fi
  command -v rsync >/dev/null 2>&1 || apt_install rsync
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

# Restaura los lanzadores .desktop, los iconos y el script helium-profile de los
# perfiles AISLADOS (los respalda backup.sh). Sin esto, los perfiles se restauran
# pero SIN forma de abrirlos con su icono. Corrige el binario helium-browser
# (nombre en Arch) -> helium (Debian) por si el backup viene del sistema viejo.
restore_helium_launchers() {
  local meta="/mnt/Other/Backup/Helium/launchers"
  if [ ! -d "$meta" ]; then
    echo "==> (Sin lanzadores de Helium en $meta; salteo.)"
    return 0
  fi
  echo "==> Restaurando lanzadores/iconos/script de perfiles aislados…"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons"
  [ -f "$meta/bin/helium-profile" ] && install -m 0755 "$meta/bin/helium-profile" "$HOME/.local/bin/helium-profile"
  [ -d "$meta/icons" ] && cp -a "$meta/icons/." "$HOME/.local/share/icons/" 2>/dev/null || true
  if [ -d "$meta/applications" ]; then
    local f
    for f in "$meta"/applications/helium-*.desktop; do
      [ -f "$f" ] || continue
      sed 's/helium-browser/helium/g' "$f" > "$HOME/.local/share/applications/$(basename "$f")"
    done
  fi
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
}

# Restaura los secretos de Quarks (clave de firma + los .env) desde el drive
# Other. Los respalda backup.sh (modo quarks). NO instala nada ni pide sudo:
# usa `install` (coreutils) para copiar preservando permisos restrictivos.
#
# La clave de firma (~/.tauri) y el .env de firma (~/.config) se restauran
# siempre. El core/.env vive DENTRO del repo de código, así que ASUME que YA lo
# clonaste: la ruta llega como argumento ($1) o cae en el default ~/Proyects/
# Quarks. Si el repo no está, avisa (no rompe) y te dice dónde quedó el backup.
restore_quarks() {  # $1 = ruta al repo de Quarks ya clonado (opcional)
  local src="/mnt/Other/Backup/Quarks"
  local proj="${1:-}"
  [ -n "$proj" ] || proj="$HOME/Proyects/Quarks"

  if [ ! -d "$src" ]; then
    echo "==> (Sin backup de Quarks en $src; nada que restaurar.)"
    return 0
  fi
  echo "==> Restaurando secretos de Quarks desde $src…"

  # 1) Clave de FIRMA de releases -> ~/.tauri (privada 600, pública 644).
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

  # 2) .env de FIRMA (TAURI_SIGNING_*) -> ~/.config/com.quarks.app/ (600).
  if [ -f "$src/config/com.quarks.app/quarks.env" ]; then
    install -D -m 600 "$src/config/com.quarks.app/quarks.env" \
      "$HOME/.config/com.quarks.app/quarks.env" \
      || warn "No pude restaurar el .env de firma."
    chmod 700 "$HOME/.config/com.quarks.app" 2>/dev/null || true
    echo "    ✓ .env de firma -> ~/.config/com.quarks.app/"
  else
    warn "No hay .env de firma en el backup ($src/config/com.quarks.app/quarks.env)."
  fi

  # 3) core/.env (client IDs de Google OAuth) -> DENTRO del repo ya clonado.
  if [ -f "$src/project/core/.env" ]; then
    if [ -d "$proj/core" ]; then
      install -D -m 600 "$src/project/core/.env" "$proj/core/.env" \
        || warn "No pude restaurar core/.env en $proj."
      echo "    ✓ core/.env -> $proj/core/.env"
    else
      warn "No encuentro el repo de Quarks en '$proj' (falta $proj/core). Cloná el repo y corré: bash setup.sh quarks /ruta/al/repo — o copiá a mano $src/project/core/.env"
    fi
  fi
}

# VS Code desde el repo oficial de Microsoft (.deb nativo). Idempotente.
install_vscode() {
  echo "==> VS Code (repo de Microsoft)…"
  apt_install wget gpg
  sudo install -d -m 0755 /etc/apt/keyrings
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor | sudo tee /etc/apt/keyrings/packages.microsoft.gpg > /dev/null
  echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
  sudo apt update
  apt_install code
}

# GitHub Desktop (fork oficial shiftkey/desktop) como .deb NATIVO. La versión
# Flatpak falla en Wayland (la ventana no mapea: sandbox + wrapper zypak). El
# .deb nativo anda como por AUR en el sistema viejo. Baja el último release.
install_github_desktop() {
  echo "==> GitHub Desktop (.deb nativo, shiftkey/desktop)…"
  if command -v github-desktop >/dev/null 2>&1; then
    echo "    GitHub Desktop ya está instalado."
    return 0
  fi
  local url tmp
  url="$(curl -fsSL https://api.github.com/repos/shiftkey/desktop/releases/latest 2>/dev/null \
        | grep -oE '"browser_download_url": "[^"]+linux-amd64[^"]+\.deb"' | head -1 | cut -d'"' -f4)"
  if [ -z "$url" ]; then warn "No pude resolver la URL del .deb de GitHub Desktop."; return 0; fi
  tmp="$(mktemp --suffix=.deb)"
  if curl -fsSL "$url" -o "$tmp"; then
    sudo apt install -y "$tmp" || warn "No se instaló GitHub Desktop (.deb)."
  else
    warn "No pude descargar GitHub Desktop desde $url"
  fi
  rm -f "$tmp"
}

# Archivos de sistema (system/ -> /) + habilitar servicios.
install_system() {
  if [ -d "$DIR/system" ]; then
    echo "==> Fixes de sistema (system/ -> /): joystick + teclado SONiX…"
    sudo cp -a "$DIR/system/." /
    sudo chmod +x /usr/local/bin/sonix-keyboard-fix.sh 2>/dev/null || true
    sudo systemctl daemon-reload
  fi
  if systemctl list-unit-files sonix-keyboard-fix.service >/dev/null 2>&1; then
    sudo systemctl enable sonix-keyboard-fix.service 2>/dev/null \
      || echo "  (sonix-keyboard-fix: ya estaba habilitado)"
  fi
  # input-remapper: el paquete de Debian suele dejar el servicio ya habilitado
  # (queda como unit 'linkeada' y systemctl se niega a re-habilitarla). NO es un
  # error: igual arranca solo. Por eso no frenamos ni lo contamos como aviso.
  if systemctl list-unit-files input-remapper.service >/dev/null 2>&1; then
    sudo systemctl enable input-remapper.service 2>/dev/null \
      || echo "  (input-remapper: ya venía habilitado por el paquete)"
  fi
  # input-remapper necesita el modulo uinput (/dev/uinput). En Debian 13 limpio
  # NO se carga solo -> la inyeccion se queda colgada en "Starting injection...".
  # El archivo system/etc/modules-load.d/uinput.conf lo carga en cada arranque;
  # aca lo cargamos YA para no tener que reiniciar despues del setup.
  sudo modprobe uinput 2>/dev/null \
    || echo "  (uinput: no se pudo cargar ahora; se cargará en el próximo arranque)"
}

# ═══════════════════════════════════════════════════════════════════════════
#  SETUP — escritorio personalizado + todas mis apps, de una sola pasada
# ═══════════════════════════════════════════════════════════════════════════
do_setup() {
  echo "==> Actualizando el sistema…"
  sudo apt update
  sudo apt upgrade -y

  # KDE Plasma PELADO. Si ya está (p. ej. lo probaste con escritorio), se saltea
  # y no toca tu login actual. Si no está, lo instala pelado + SDDM.
  if dpkg -s plasma-desktop >/dev/null 2>&1; then
    echo "==> KDE Plasma ya está instalado; salteo el escritorio."
  else
    echo "==> Instalando KDE Plasma (pelado) + SDDM…"
    apt_install plasma-desktop sddm
    sudo systemctl enable sddm
  fi

  # Apps por apt.
  echo "==> Apps (apt)…"
  APPS=(
    # KDE
    konsole dolphin kate ark gwenview okular kde-spectacle kcalc partitionmanager
    kde-config-gtk-style kdegraphics-thumbnailers
    # utilidades (curl + gpg los necesitan Helium y Claude Code)
    input-remapper git rsync flatpak plasma-discover-backend-flatpak xdg-utils curl gpg
    # multimedia (pipewire-alsa = puente ALSA→PipeWire; sin él las apps ALSA
    # como OpenShot no tienen audio y tiran "no channels")
    vlc yt-dlp ffmpegthumbnailer gstreamer1.0-plugins-good gstreamer1.0-libav
    pipewire-alsa
    # oficina
    libreoffice
    # gaming
    gamemode mangohud winetricks
    # desarrollo
    openjdk-17-jdk openjdk-21-jre python3-pip npm
  )
  apt_install "${APPS[@]}"

  # Flatpaks. El primero baja el "runtime" de KDE (~cientos de MB), por única
  # vez. qView = visor de imágenes puro (no está en apt). Discord por Flatpak:
  # el .deb nativo se cuelga al llegar mensajes en este Debian (libunity9 bloquea
  # D-Bus); el Flatpak es estable (la contra: no muestra badge en el taskbar).
  echo "==> Flatpaks (qView, Bitwarden, Lutris, Discord)…"
  flatpak_install \
    com.interversehq.qView \
    com.bitwarden.desktop \
    net.lutris.Lutris \
    com.discordapp.Discord
    # -- Descomentar cuando los quiera: --
    # org.prismlauncher.PrismLauncher
    # com.heroicgameslauncher.hgl

  # Navegador Helium + Claude Code (cada uno por su método oficial).
  install_helium
  install_claude

  # VS Code (repo de Microsoft) + GitHub Desktop nativo (.deb, no Flatpak: la
  # Flatpak buggea en Wayland/zypak).
  install_vscode
  install_github_desktop

  # Restaurar mis perfiles de Helium + sus lanzadores/iconos/script desde el
  # drive Other (si está conectado). Los respalda backup.sh.
  restore_helium
  restore_helium_launchers

  # Temas de iconos (Win11 activo + Colloid).
  install_icons

  # Mis configuraciones (KDE, atajos, layout de teclado ñ, remapeos, temas…).
  if [ -d "$DIR/home" ]; then
    echo "==> Restaurando mis configuraciones (home/ -> \$HOME)…"
    cp -a "$DIR/home/." "$HOME/"
  fi

  # Apps por defecto: PDF -> Okular, video -> VLC, imágenes -> qView.
  # Redirigimos el stderr: xdg-mime tira ruido inofensivo ('qtpaths: not found')
  # en KDE, pero la asociación igual se escribe en ~/.config/mimeapps.list.
  echo "==> Apps por defecto (PDF → Okular, video → VLC, imágenes → qView)…"
  xdg-mime default org.kde.okular.desktop application/pdf 2>/dev/null || true
  xdg-mime default vlc.desktop \
    video/mp4 video/x-matroska video/webm video/quicktime \
    video/x-msvideo video/mpeg video/x-flv video/3gpp video/ogg 2>/dev/null || true
  xdg-mime default com.interversehq.qView.desktop \
    image/jpeg image/png image/gif image/webp image/bmp image/tiff image/svg+xml 2>/dev/null || true

  # Fixes de sistema + servicios (joystick, teclado, input-remapper).
  install_system

  # Dejar el comando 'backup' a mano (symlink a backup.sh de este repo): con
  # escribir 'backup' respaldás los perfiles de Helium Y capturás tus configs
  # al repo, de una.
  mkdir -p "$HOME/.local/bin"
  ln -sf "$DIR/backup.sh" "$HOME/.local/bin/backup"

  # ── Joystick Xbox (driver xone) — SOLO en tu PC real ───────────────────────
  # xone no está en Debian; se instala por DKMS desde el código fuente.
  # Descomentá cuando lo corras en la máquina real con el control:
  # apt_install dkms git curl
  # git clone https://github.com/dlundqvist/xone /tmp/xone
  # ( cd /tmp/xone && sudo ./install.sh ) && sudo xone-get-firmware.sh --skip-disclaimer
  # rm -rf /tmp/xone

  echo "== Setup listo. =="
}

# ═══════════════════════════════════════════════════════════════════════════
#  RUN + RESUMEN
# ═══════════════════════════════════════════════════════════════════════════
case "$MODE" in
  all)    do_setup ;;
  quarks) restore_quarks "${2:-}" ;;
  *)      echo "Uso: bash setup.sh [quarks [ruta-al-repo]]"; echo "     (sin argumentos: setup completo)"; exit 1 ;;
esac

echo
echo "════════════════════════════ RESUMEN ════════════════════════════"
if [ "${#WARNINGS[@]}" -eq 0 ]; then
  echo "✅ ¡Listo! Sin avisos."
else
  echo "⚠ Terminó con ${#WARNINGS[@]} aviso(s) — revisá esto:"
  for w in "${WARNINGS[@]}"; do echo "   • $w"; done
fi
[ "$MODE" = "all" ] && echo "   Cerrá sesión y volvé a entrar (o reiniciá) para ver todo aplicado."
echo "═════════════════════════════════════════════════════════════════"

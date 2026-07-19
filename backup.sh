#!/usr/bin/env bash
#
# backup.sh — TODO el sistema de backup en un solo comando.
# ---------------------------------------------------------------------------
# Hace tres cosas, las tres patas de "no perder nada al reinstalar":
#
#   1) HELIUM (datos vivos) -> drive Other
#      Copia la parte que IMPORTA de mis perfiles (marcadores, logins,
#      extensiones, preferencias, historial) a /mnt/Other/Backup/Helium,
#      descartando el caché regenerable (pesa gigas y no hace falta guardar).
#      También respalda los lanzadores .desktop, iconos y el script
#      helium-profile de los perfiles AISLADOS. Refleja altas, cambios Y BAJAS:
#      si borrás un perfil, se quita del backup; si agregás otro, lo agarra.
#
#   2) CONFIGS (KDE, mappings, aliases, fixes de system/) -> el repo (git)
#      "Captura" mis configuraciones vivas de vuelta al repo, para no tener que
#      copiar a mano cada archivo cada vez que cambio un atajo o un mapping.
#      Solo toca lo que YA trackeás: refresca los archivos y espeja mis carpetas
#      propias (input-remapper, xkb, esquemas de color…) para agarrar también
#      los archivos NUEVOS que hayas creado adentro. NO commitea solo: al final
#      muestra el 'git status' para que revises el diff y guardes vos.
#
#   3) QUARKS (secretos gitignoreados) -> drive Other
#      El código de Quarks vive en GitHub, pero hay archivos que NO se commitean
#      (son secretos) y que si se pierden al formatear son irrecuperables:
#      la clave de FIRMA de releases (~/.tauri/quarks.key) y los .env con las
#      credenciales (firma + client IDs de Google OAuth). Van al drive (NUNCA al
#      repo: este se pushea a GitHub y son secretos). Perder la clave de firma
#      significa no poder volver a firmar updates para las apps ya instaladas.
#
# El drive Other NO se formatea al reinstalar y el repo vive en él, así que lo
# copiado (perfiles + secretos de Quarks) y lo commiteado+pusheado (configs)
# sobreviven. Tras un fresh install, setup.sh restaura las tres cosas.
#
# Uso:  backup            -> todo (helium + configs + quarks)
#       backup helium     -> solo perfiles de Helium
#       backup config     -> solo capturar configs al repo
#       backup quarks     -> solo secretos de Quarks al drive
#
# Es incremental (rsync) e idempotente: la 2ª corrida en adelante es rápida.
# ---------------------------------------------------------------------------
set -uo pipefail

# El repo (con setup.sh, home/ y system/) vive en la misma carpeta que este
# script. Resolvemos el symlink 'backup' con readlink -f para llegar al repo
# real en el drive, no a ~/.local/bin.
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
MODE="${1:-all}"          # all | helium | config  (default: all)

# Globs que incluyen dotfiles y que desaparecen si no matchean nada. Clave:
# el contenido de home/ (.bash_aliases, .config, .local) es TODO oculto.
shopt -s nullglob dotglob

# ── Destinos del backup de Helium en el drive Other ────────────────────────
DEST="/mnt/Other/Backup/Helium/profiles"
# Meta de los perfiles AISLADOS: sus lanzadores .desktop, iconos y el script
# helium-profile. Va aparte de DEST para no confundirse con un perfil más.
META="/mnt/Other/Backup/Helium/launchers"

# ── Destino de los secretos de Quarks en el drive Other ────────────────────
# Espeja la estructura de origen para que el restore sea obvio. QUARKS_PROJECT
# es dónde clonás el repo de código (ajustá si lo movés).
QUARKS_PROJECT="$HOME/Proyects/Quarks"
DEST_Q="/mnt/Other/Backup/Quarks"

# rsync "completo" con barra de progreso (para los perfiles, que son grandes).
RS=(rsync -a --human-readable --delete)
[ -t 1 ] && RS+=(--info=progress2)   # barra de progreso solo en terminal real
# rsync "silencioso" para la captura de configs (muchas carpetas chicas -> sin
# barra, para no llenar la pantalla de ruido).
RSC=(rsync -a --delete)

# Caché y site-data regenerable que NO copiamos de los perfiles de Helium
# (mismos patrones probados que usaba el viejo sistema). Lo que SÍ se guarda:
# Bookmarks, Preferences, History, Login Data, Web Data, Extensions y su config.
EX=(
  --exclude='Cache/' --exclude='Code Cache/' --exclude='GPUCache/'
  --exclude='GPUPersistentCache/' --exclude='GrShaderCache/' --exclude='ShaderCache/'
  --exclude='DawnGraphiteCache/' --exclude='DawnWebGPUCache/' --exclude='GraphiteDawnCache/'
  --exclude='Service Worker/' --exclude='component_crx_cache/'
  --exclude='File System/' --exclude='IndexedDB/' --exclude='Local Storage/'
  --exclude='Session Storage/' --exclude='WebStorage/' --exclude='blob_storage/'
  --exclude='Sessions/'
  --exclude='BrowserMetrics/' --exclude='DeferredBrowserMetrics/' --exclude='Crash Reports/'
  --exclude='Crashpad/' --exclude='Variations/' --exclude='segmentation_platform/'
  --exclude='CertificateRevocation/' --exclude='WidevineCdm/' --exclude='Dictionaries/'
  --exclude='System Profile/' --exclude='Guest Profile/'
  --exclude='SingletonLock' --exclude='SingletonSocket' --exclude='SingletonCookie'
  --exclude='lockfile'
)

warn=0

# ═══════════════════════════════════════════════════════════════════════════
#  Requisito: el drive Other tiene que estar montado (ahí van los perfiles Y
#  vive el repo con las configs).
# ═══════════════════════════════════════════════════════════════════════════
require_mount() {
  if ! mountpoint -q /mnt/Other; then
    echo "✗ /mnt/Other no está montado. Conectá/montá el drive Other y reintentá."
    exit 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  1) BACKUP DE HELIUM (perfiles + lanzadores) -> drive
# ═══════════════════════════════════════════════════════════════════════════
copy_profile() {
  local src="$1" name="$2"
  [ -d "$src" ] || return 0
  echo "==> $name"
  "${RS[@]}" "${EX[@]}" "$src/" "$DEST/$name/" || warn=1
}

backup_helium() {
  mkdir -p "$DEST" || { echo "✗ No puedo escribir en $DEST"; warn=1; return 1; }
  echo "==> Perfiles de Helium -> $DEST"

  # ── Perfil normal + todos los aislados (helium-*) ────────────────────────
  copy_profile "$HOME/.config/net.imput.helium" "net.imput.helium"
  for d in "$HOME"/.config/helium-*; do
    [ -d "$d" ] || continue
    copy_profile "$d" "$(basename "$d")"
  done

  # ── Podar perfiles que ya NO existen en vivo (los borraste) ──────────────
  # Sin esto, un perfil borrado quedaría huérfano en el backup para siempre.
  # Así el backup refleja también las bajas, no solo altas/cambios.
  local b d
  declare -A KEEP
  [ -d "$HOME/.config/net.imput.helium" ] && KEEP["net.imput.helium"]=1
  for d in "$HOME"/.config/helium-*; do
    [ -d "$d" ] && KEEP["$(basename "$d")"]=1
  done
  for d in "$DEST"/*; do
    [ -d "$d" ] || continue
    b="$(basename "$d")"
    if [ -z "${KEEP[$b]:-}" ]; then
      echo "    · $b ya no está en vivo; lo quito del backup."
      rm -rf "$d" || warn=1
    fi
  done

  # ── Lanzadores, iconos y el script helium-profile de los perfiles aislados
  # El navegador normal usa el helium.desktop del paquete; los AISLADOS dependen
  # de estos .desktop + iconos + el script que los crea. Sin esto, tras un fresh
  # install los perfiles se restauran pero SIN forma de abrirlos con su icono.
  echo
  echo "==> Lanzadores/iconos/script de perfiles aislados -> $META"
  mkdir -p "$META/applications" "$META/icons" "$META/bin" || warn=1
  local desks icns
  desks=("$HOME"/.local/share/applications/helium-*.desktop)
  icns=("$HOME"/.local/share/icons/helium-*)
  if [ "${#desks[@]}" -gt 0 ]; then "${RS[@]}" "${desks[@]}" "$META/applications/" || warn=1
  else echo "    (sin .desktop helium-* que respaldar)"; fi
  if [ "${#icns[@]}" -gt 0 ]; then "${RS[@]}" "${icns[@]}" "$META/icons/" || warn=1
  else echo "    (sin iconos helium-* que respaldar)"; fi
  if [ -f "$HOME/.local/bin/helium-profile" ]; then "${RS[@]}" "$HOME/.local/bin/helium-profile" "$META/bin/" || warn=1
  else echo "    (sin script helium-profile que respaldar)"; fi

  echo
  echo "==> Tamaño del backup de Helium (sin caché):"
  du -sh "$DEST" 2>/dev/null | sed 's/^/    /'
}

# ═══════════════════════════════════════════════════════════════════════════
#  2) CAPTURA DE CONFIGS (vivo -> repo)
# ═══════════════════════════════════════════════════════════════════════════
# Refresca un archivo del repo con su versión viva (o avisa si desapareció).
refresh_file() {  # $1=archivo en repo, $2=archivo en vivo
  if [ -f "$2" ]; then rsync -a "$2" "$1" || warn=1
  else echo "    ⚠ falta en vivo: $2 (¿lo borraste? el repo lo conserva)"; warn=1; fi
}

# ── HOME (crece): carpetas XDG "contenedoras" (compartidas con el SO/otros
# programas) -> bajamos SELECTIVO solo a lo trackeado. Todo lo que trackeás
# ADENTRO de ellas (una carpeta propia como input-remapper-2) se espeja
# ENTERO desde vivo, así agarra los archivos NUEVOS (nuevos presets,
# xmodmap.json…) y borra los que sacaste.
is_container() {  # $1 = ruta relativa a home/ (ej: ".config")
  case "$1" in
    "" | ".config" | ".local" | ".local/share" | ".local/state") return 0 ;;
    *) return 1 ;;
  esac
}

capture_home() {  # $1=dir en repo, $2=dir en vivo, $3=ruta relativa a home/
  local repo="$1" live="$2" rel="$3" p base childrel
  for p in "$repo"/*; do
    base="$(basename "$p")"
    childrel="${rel:+$rel/}$base"
    if [ -d "$p" ]; then
      if is_container "$childrel"; then
        # Contenedor XDG -> recurro selectivo (no lo espejo entero: arrastraría
        # config de otros programas que no quiero trackear).
        [ -d "$live/$base" ] && capture_home "$p" "$live/$base" "$childrel"
      else
        # Carpeta MÍA -> espejo completo (agarra nuevos/borrados adentro).
        if [ -d "$live/$base" ]; then
          echo "    ↻ $childrel/  (carpeta completa)"
          "${RSC[@]}" "$live/$base/" "$p/" || warn=1
        else
          echo "    ⚠ falta en vivo: $live/$base (¿la borraste? el repo la conserva)"; warn=1
        fi
      fi
    elif [ -f "$p" ]; then
      refresh_file "$p" "$live/$base"
    fi
  done
}

# ── SYSTEM (NO crece): solo refresca los archivos que YA trackeás. Nunca
# espeja carpetas enteras de /etc — arrastraría archivos del SO/otros paquetes.
capture_system() {  # $1=dir en repo, $2=dir en vivo (arranca en /)
  local repo="$1" live="$2" p base
  for p in "$repo"/*; do
    base="$(basename "$p")"
    if [ -d "$p" ]; then
      [ -d "$live/$base" ] && capture_system "$p" "$live/$base"
    elif [ -f "$p" ]; then
      refresh_file "$p" "$live/$base"
    fi
  done
}

backup_config() {
  if [ ! -d "$DIR/home" ] && [ ! -d "$DIR/system" ]; then
    echo "==> (No encuentro home/ ni system/ en $DIR; salteo la captura de configs.)"
    return 0
  fi
  echo
  echo "==> Capturando configs vivas -> repo ($DIR)"
  [ -d "$DIR/home" ]   && { echo "  home/  (\$HOME):"; capture_home   "$DIR/home"   "$HOME" ""; }
  [ -d "$DIR/system" ] && { echo "  system/ (/):";     capture_system "$DIR/system" "";        }

  # Mostrar qué cambió en el repo y recordar commitear (NO commiteamos solos:
  # querés revisar el diff antes de guardar).
  if command -v git >/dev/null 2>&1 && git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo
    if [ -n "$(git -C "$DIR" status --porcelain -- home system 2>/dev/null)" ]; then
      echo "==> Cambios de config en el repo:"
      git -C "$DIR" status --short -- home system | sed 's/^/    /'
      echo "    Revisá:  git -C \"$DIR\" diff"
      echo "    Guardá:  git -C \"$DIR\" commit -am 'update configs' && git -C \"$DIR\" push"
    else
      echo "==> Sin cambios de config: el repo ya estaba al día."
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  3) BACKUP DE QUARKS (secretos gitignoreados) -> drive
# ═══════════════════════════════════════════════════════════════════════════
# Copia un secreto al drive preservando permisos (rsync -a; el drive es ext4).
# Avisa (sin frenar) si el archivo no está en vivo, conservando el del backup.
copy_secret() {  # $1=archivo en vivo  $2=destino en el drive
  if [ -f "$1" ]; then
    mkdir -p "$(dirname "$2")" || { warn=1; return; }
    if "${RS[@]}" "$1" "$2"; then echo "    ✓ $1"; else warn=1; fi
  else
    echo "    ⚠ no existe en vivo: $1 (¿todavía no lo restauraste? conservo el del backup)"; warn=1
  fi
}

backup_quarks() {
  echo
  echo "==> Secretos de Quarks (NO van a GitHub) -> $DEST_Q"
  mkdir -p "$DEST_Q" || { echo "✗ No puedo escribir en $DEST_Q"; warn=1; return 1; }

  # Clave de FIRMA de releases (privada + pública). La privada es la pieza
  # crítica: sin ella no podés firmar updates que las apps instaladas acepten.
  copy_secret "$HOME/.tauri/quarks.key"                 "$DEST_Q/tauri/quarks.key"
  copy_secret "$HOME/.tauri/quarks.key.pub"             "$DEST_Q/tauri/quarks.key.pub"
  # .env de firma (TAURI_SIGNING_*), en el appConfigDir del identifier de Tauri.
  copy_secret "$HOME/.config/com.quarks.app/quarks.env" "$DEST_Q/config/com.quarks.app/quarks.env"
  # .env de desarrollo (client IDs de Google OAuth), dentro del repo de código.
  copy_secret "$QUARKS_PROJECT/core/.env"               "$DEST_Q/project/core/.env"

  # Endurecemos permisos del backup: son secretos (el drive es ext4 y los
  # preserva). En un fs sin permisos unix (NTFS/exFAT) sería un no-op inofensivo.
  chmod -R go-rwx "$DEST_Q" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  DISPATCHER + RESUMEN
# ═══════════════════════════════════════════════════════════════════════════
case "$MODE" in
  helium) require_mount; backup_helium ;;
  config) require_mount; backup_config ;;
  quarks) require_mount; backup_quarks ;;
  all)    require_mount; backup_helium; backup_config; backup_quarks ;;
  *)      echo "Uso: backup [all|helium|config|quarks]"; exit 1 ;;
esac

echo
if [ "$warn" -eq 0 ]; then
  echo "✅ Backup completo (modo: $MODE)."
else
  echo "⚠ Terminó con avisos (modo: $MODE) — algún archivo no se pudo copiar o"
  echo "  desapareció en vivo; suele ser inofensivo, pero revisá arriba."
fi

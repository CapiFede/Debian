#!/usr/bin/env bash
#
# backup.sh — Respalda mis perfiles de Helium (+ lanzadores) al drive Backup.
# ---------------------------------------------------------------------------
# Los perfiles VIVOS quedan en el disco del sistema (rápido y seguro para las
# bases SQLite del navegador). Este script copia la parte que IMPORTA
# (marcadores, logins, extensiones, preferencias, historial) al drive Backup,
# descartando el caché regenerable (que pesa gigas y no hace falta guardar).
# También respalda los lanzadores .desktop, los iconos y el script
# helium-profile de los perfiles AISLADOS, para poder abrirlos tras reinstalar.
#
# El drive Backup NO se formatea al reinstalar, así que lo copiado sobrevive.
# Después de un fresh install, setup.sh restaura estos perfiles automáticamente.
#
# Uso:  bash backup.sh
#
# Es incremental (rsync) e idempotente: la 2ª corrida en adelante es rápida.
# ---------------------------------------------------------------------------
set -uo pipefail

# Destino en el drive Backup. Cambialo si tu punto de montaje es otro.
DEST="/mnt/Backup/helium"
# Meta de los perfiles AISLADOS: sus lanzadores .desktop, iconos y el script
# helium-profile. Va aparte de DEST para no confundirse con un perfil más.
META="/mnt/Backup/helium-launchers"

# rsync pensado para destino NTFS: NO preservar permisos/owner Unix (NTFS no los
# tiene), --modify-window=1 absorbe la diferencia de timestamps para que el
# incremental funcione, --delete refleja lo que borraste en el perfil.
RS=(rsync -rlt --modify-window=1 --no-perms --no-owner --no-group --human-readable --delete)
[ -t 1 ] && RS+=(--info=progress2)   # barra de progreso solo en terminal real

# Caché y site-data regenerable que NO copiamos (mismos patrones probados que
# usaba el viejo sistema). Lo que SÍ se guarda: Bookmarks, Preferences, History,
# Login Data, Web Data, Extensions y su config.
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

# ── 0. Verificar que el drive esté montado y escribible ────────────────────
if ! mountpoint -q /mnt/Backup; then
  echo "✗ /mnt/Backup no está montado. Conectá/montá el drive Backup y reintentá."
  exit 1
fi
mkdir -p "$DEST" || { echo "✗ No puedo escribir en $DEST"; exit 1; }
echo "==> Destino: $DEST"

warn=0
copy_profile() {
  local src="$1" name="$2"
  [ -d "$src" ] || return 0
  echo "==> $name"
  "${RS[@]}" "${EX[@]}" "$src/" "$DEST/$name/" || warn=1
}

# ── Perfil normal + todos los aislados (helium-*) ──────────────────────────
copy_profile "$HOME/.config/net.imput.helium" "net.imput.helium"
for d in "$HOME"/.config/helium-*; do
  [ -d "$d" ] || continue
  copy_profile "$d" "$(basename "$d")"
done

# ── Lanzadores, iconos y el script helium-profile de los perfiles aislados ──
# El navegador normal usa el helium.desktop del paquete; los AISLADOS dependen
# de estos .desktop + iconos + el script que los crea. Sin esto, tras un fresh
# install los perfiles se restauran pero SIN forma de abrirlos con su icono.
echo
echo "==> Lanzadores/iconos/script de perfiles aislados -> $META"
mkdir -p "$META/applications" "$META/icons" "$META/bin" || warn=1
shopt -s nullglob
desks=("$HOME"/.local/share/applications/helium-*.desktop)
icns=("$HOME"/.local/share/icons/helium-*)
shopt -u nullglob
if [ "${#desks[@]}" -gt 0 ]; then "${RS[@]}" "${desks[@]}" "$META/applications/" || warn=1
else echo "    (sin .desktop helium-* que respaldar)"; fi
if [ "${#icns[@]}" -gt 0 ]; then "${RS[@]}" "${icns[@]}" "$META/icons/" || warn=1
else echo "    (sin iconos helium-* que respaldar)"; fi
if [ -f "$HOME/.local/bin/helium-profile" ]; then "${RS[@]}" "$HOME/.local/bin/helium-profile" "$META/bin/" || warn=1
else echo "    (sin script helium-profile que respaldar)"; fi

echo
echo "==> Tamaño del backup de Helium (sin caché):"
du -sh "$DEST" 2>/dev/null | sed 's/^/    /'
if [ "$warn" -eq 0 ]; then
  echo "✅ Backup de Helium completo en $DEST"
else
  echo "⚠ Terminó con avisos (algún archivo no se pudo copiar; suele ser inofensivo en NTFS)."
fi

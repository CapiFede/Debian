#!/usr/bin/env bash
#
# sonix-keyboard-fix.sh
# ---------------------------------------------------------------------------
# El teclado auxiliar SONiX (USB id 0c45:8009) es lento para "despertar" al
# encender la PC en frío: su enumeracion USB inicial falla ("device descriptor
# read/64, error -32") y el kernel se rinde, dejandolo muerto hasta reconectar
# el cable. Esto resetea el hub del que cuelga (equivale a reconectarlo por
# software) para que el kernel lo vuelva a enumerar, ya despierto.
#
# Lo dispara el servicio sonix-keyboard-fix.service en cada arranque.
# Solo actua SI el teclado no esta presente (si ya lo detecto, no toca nada).
#
# OJO (hardware): HUB_IF es la ruta topologica del hub padre en ESTA PC. Si
# cambias el teclado de puerto o cambias de placa/hardware, puede variar.
# Para redescubrirla: enchufa el teclado, corre  lsusb -t  y ubica el hub del
# que cuelga el "USB KEYBOARD"; la ruta sale de  ls /sys/bus/usb/devices/.
# ---------------------------------------------------------------------------
set -uo pipefail

VID="0c45"; PID="8009"     # "DNI" del teclado SONiX (vendor:product)
HUB_IF="1-5.2:1.0"         # hub padre (interfaz) a resetear
HUB_DEV="${HUB_IF%%:*}"    # -> 1-5.2

log(){ echo "sonix-kbd-fix: $*"; }

kbd_present(){
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ -r "$d/idVendor" && -r "$d/idProduct" ]] || continue
    [[ "$(< "$d/idVendor")" == "$VID" && "$(< "$d/idProduct")" == "$PID" ]] && return 0
  done
  return 1
}

# Dar tiempo a que la enumeracion inicial del arranque termine (y falle).
sleep 4

if kbd_present; then
  log "el teclado ya esta presente; nada que hacer."
  exit 0
fi

if [[ ! -e "/sys/bus/usb/devices/$HUB_DEV" ]]; then
  log "no encuentro el hub $HUB_DEV (cambio el hardware/puerto?); no hago nada."
  exit 0
fi

log "teclado ausente; reseteando el hub $HUB_IF (unbind + rebind)..."
echo "$HUB_IF" > /sys/bus/usb/drivers/hub/unbind 2>/dev/null || { log "fallo el unbind"; exit 0; }
sleep 2
echo "$HUB_IF" > /sys/bus/usb/drivers/hub/bind   2>/dev/null || { log "fallo el bind";   exit 0; }
sleep 3

if kbd_present; then
  log "OK: el teclado quedo detectado tras el reset del hub."
else
  log "el teclado SIGUE ausente tras el reset; revisar manualmente."
fi
exit 0

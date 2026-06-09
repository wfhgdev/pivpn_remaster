#!/usr/bin/env bash
# PiVPN: Utilidades Avanzadas de Red y Cálculo de Direccionamiento IPv4
# Proporciona rutinas matemáticas de alta eficiencia para manipulación de máscaras, CIDR y subredes.

export LANG=es_ES.UTF-8
export LC_ALL=es_ES.UTF-8

# ==============================================================================
#                      NOTAS DE ARQUITECTURA Y TRAZABILIDAD
# ==============================================================================
# IMPORTANTE: Al ser funciones utilitarias cuyos retornos son capturados mediante 
# asignación (ej: var=$(decIPv4ToDot 3232235521)), cualquier salida informativa 
# decorativa DEBE ser despachada obligatoriamente hacia stderr (>&2).

# ------------------------------------------------------------------------------
# decIPv4ToDot()
# Convierte una dirección IPv4 en formato entero decimal de 32 bits a notación de puntos.
# ------------------------------------------------------------------------------
decIPv4ToDot() {
  local ip_dec="${1}"
  local a b c d

  # Validación de entrada numérica
  if [[ ! "${ip_dec}" =~ ^[0-9]+$ ]]; then
    echo "::: [ERROR - IP] Entrada decimal inválida en decIPv4ToDot: '${ip_dec}'" >&2
    return 1
  fi

  # Extracción bit a bit por octetos (mecanismo nativo de 64 bits en Bash)
  a=$(( (ip_dec & 4278190080) >> 24 ))
  b=$(( (ip_dec & 16711680) >> 16 ))
  c=$(( (ip_dec & 65280) >> 8 ))
  d=$(( ip_dec & 255 ))

  printf "%s.%s.%s.%s\n" "${a}" "${b}" "${c}" "${d}"
}

# ------------------------------------------------------------------------------
# dotIPv4ToDec()
# Convierte una dirección IPv4 en formato estándar de puntos (A.B.C.D) a entero decimal.
# ------------------------------------------------------------------------------
dotIPv4ToDec() {
  local ip_dot="${1}"
  local array_ip

  # Inyección segura de IFS local sin alterar el entorno global del script
  IFS='.' read -r -a array_ip <<< "${ip_dot}"

  # Validación estructural preventiva del direccionamiento IP ingresado
  if [[ ${#array_ip[@]} -ne 4 ]]; then
    echo "::: [ERROR - IP] Formato IPv4 malformado o incompleto en dotIPv4ToDec: '${ip_dot}'" >&2
    return 1
  fi

  # Cálculo polinómico posicional de base 256
  printf "%s\n" "$(( array_ip[0] * 16777216 + array_ip[1] * 65536 + array_ip[2] * 256 + array_ip[3] ))"
}

# ------------------------------------------------------------------------------
# dotIPv4FirstDec()
# Devuelve el primer entero decimal direccionable (ID de red) a partir de una IP y su prefijo CIDR.
# ------------------------------------------------------------------------------
dotIPv4FirstDec() {
  local ip_dot="${1}"
  local cidr="${2}"
  local decimal_ip decimal_mask

  # Asegurar límites del prefijo de red CIDR
  if (( cidr < 0 || cidr > 32 )); then
    echo "::: [ERROR - IP] Prefijo CIDR fuera de rango (0-32) en dotIPv4FirstDec: '${cidr}'" >&2
    return 1
  fi

  decimal_ip=$(dotIPv4ToDec "${ip_dot}") || return 1
  
  # Construcción matemática de la máscara de red binaria
  decimal_mask=$(( 2 ** 32 - 1 ^ (2 ** (32 - cidr) - 1) ))
  
  printf "%s\n" "$(( decimal_ip & decimal_mask ))"
}

# ------------------------------------------------------------------------------
# dotIPv4LastDec()
# Devuelve el último entero decimal direccionable (Broadcast) de una subred.
# ------------------------------------------------------------------------------
dotIPv4LastDec() {
  local ip_dot="${1}"
  local cidr="${2}"
  local decimal_ip decimal_mask_inv

  if (( cidr < 0 || cidr > 32 )); then
    echo "::: [ERROR - IP] Prefijo CIDR fuera de rango (0-32) en dotIPv4LastDec: '${cidr}'" >&2
    return 1
  fi

  decimal_ip=$(dotIPv4ToDec "${ip_dot}") || return 1
  
  # Máscara inversa (Bits de host activados)
  decimal_mask_inv=$(( 2 ** (32 - cidr) - 1 ))
  
  printf "%s\n" "$(( decimal_ip | decimal_mask_inv ))"
}

# ------------------------------------------------------------------------------
# decIPv4ToHex()
# Convierte una IP decimal a una cadena hexadecimal formateada en dos cuartetos (hhhh:hhhh).
# Útil para mapeos criptográficos, subredes IPv6 o tokens internos del servidor.
# ------------------------------------------------------------------------------
decIPv4ToHex() {
  local ip_dec="${1}"
  local hex quartet_hi quartet_lo leading_zeros_hi leading_zeros_lo

  if [[ ! "${ip_dec}" =~ ^[0-9]+$ ]]; then
    echo "::: [ERROR - IP] Entrada decimal inválida en decIPv4ToHex: '${ip_dec}'" >&2
    return 1
  fi

  # Formateo inicial forzando relleno a 8 caracteres hexadecimales minúsculos
  hex="$(printf "%08x\n" "${ip_dec}")"
  
  # Segmentación limpia de los dos bloques de 16 bits
  quartet_hi=${hex:0:4}
  quartet_lo=${hex:4:4}

  # Normalización estética: Remoción segura de ceros a la izquierda en los cuartetos
  leading_zeros_hi="${quartet_hi%%[!0]*}"
  leading_zeros_lo="${quartet_lo%%[!0]*}"
  
  printf "%s:%s\n" "${quartet_hi#"${leading_zeros_hi}"}" "${quartet_lo#"${leading_zeros_lo}"}"
}

# ------------------------------------------------------------------------------
# cidrToMask()
# Transforma un prefijo numérico CIDR (0-32) en una máscara de red estándar (A.B.C.D).
# Reemplaza algoritmos antiguos por operaciones lógicas de bits directas y legibles.
# ------------------------------------------------------------------------------
cidrToMask() {
  local cidr="${1}"
  local mask_dec

  if [[ ! "${cidr}" =~ ^[0-9]+$ ]] || (( cidr < 0 || cidr > 32 )); then
    echo "::: [ERROR - IP] Especificación de prefijo CIDR inválida en cidrToMask: '${cidr}'" >&2
    return 1
  fi

  # Caso base de exclusión total
  if (( cidr == 0 )); then
    echo "0.0.0.0"
    return 0
  fi

  # Desplazamiento de bits nativo para generar la máscara completa en entero decimal
  mask_dec=$(( 0xFFFFFFFF << (32 - cidr) ))
  
  # Conversión final delegando en la función interna optimizada
  decIPv4ToDot "${mask_dec}"
}
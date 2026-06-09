#!/usr/bin/env bash
# PiVPN: Script de Diagnóstico Autónomo y Auto-reparación (Self-Check)
# Analiza de forma exhaustiva el estado del kernel, reglas de firewall y demonios activos.

export LANG=es_ES.UTF-8
export LC_ALL=es_ES.UTF-8

# ==============================================================================
#                      VALIDACIÓN DE ENTRADAS Y ENTORNO
# ==============================================================================

# Normalización del parámetro del protocolo VPN recibido por argumento
if [[ -z "${1}" ]]; then
  echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ::: [ERROR] Debe especificar un protocolo VPN (wireguard o openvpn)." >&2
  exit 1
fi

VPN="${1,,}" # Forzar conversión a minúsculas
if [[ "${VPN}" == "wg" ]]; then VPN="wireguard"; fi
if [[ "${VPN}" == "ovpn" ]]; then VPN="openvpn"; fi

if [[ "${VPN}" != "wireguard" && "${VPN}" != "openvpn" ]]; then
  echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ::: [ERROR] Protocolo no soportado: '${1}'. Elija 'wireguard' o 'openvpn'." >&2
  exit 1
fi

# Identificación de la distribución base del sistema operativo
PLAT="$(grep -sEe '^NAME\=' /etc/os-release | sed -E -e "s/NAME\=[\'\"]?([^ ]*).*/\1/")"

setupVars="/etc/pivpn/${VPN}/setupVars.conf"
global_error_flag=0

# ------------------------------------------------------------------------------
# Función de salida para el canal de errores estándar (stderr)
# ------------------------------------------------------------------------------
err() {
  echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ::: [ERROR] $*" >&2
}

# Verificación de la presencia del archivo de configuración fundamental
if [[ ! -f "${setupVars}" ]]; then
  err "No se localizó el archivo de variables del ecosistema PiVPN en: ${setupVars}"
  exit 1
fi

# Carga controlada de variables dinámicas del servidor
# shellcheck disable=SC1090
source "${setupVars}"

# Asignación de nombres de servicios e identificadores según topología
if [[ "${VPN}" == "wireguard" ]]; then
  VPN_PRETTY_NAME="WireGuard"
  VPN_SERVICE="wg-quick@wg0"
  if [[ "${PLAT}" == 'Alpine' ]]; then
    VPN_SERVICE='wg-quick'
  fi
elif [[ "${VPN}" == "openvpn" ]]; then
  VPN_SERVICE="openvpn"
  VPN_PRETTY_NAME="OpenVPN"
fi

echo "::: [INFO] Iniciando auditoría interna del servidor PiVPN (${VPN_PRETTY_NAME})..."

# ==============================================================================
# 1. VERIFICACIÓN DEL REENVÍO DE PAQUETES DE RED (IP FORWARDING)
# ==============================================================================
if [[ "$(< /proc/sys/net/ipv4/ip_forward)" -eq 1 ]]; then
  echo "::: [OK] El reenvío de IP (IP Forwarding) está habilitado correctamente en el núcleo."
else
  global_error_flag=1
  echo -n "::: [ADVERTENCIA] El reenvío de IP está deshabilitado en el kernel. ¿Intentar solucionar ahora? [S/n]: "
  read -r REPLY

  if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
    echo "::: [CORRECCIÓN] Modificando directiva de red en /etc/sysctl.d/99-pivpn.conf..."
    sed -i '/net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.d/99-pivpn.conf
    if sysctl -p &> /dev/null; then
      echo "::: [ÉXITO] Parámetros del kernel recargados. Reenvío IP activo."
    else
      err "Fallo al aplicar sysctl. Verifique los privilegios o el estado del sistema operativo."
    fi
  fi
fi

# ==============================================================================
# 2. AUDITORÍA DE REGLAS DE FIREWALL (IPTABLES DIRECTO vs UFW)
# ==============================================================================
# shellcheck disable=SC2154
if [[ "${USING_UFW}" -eq 0 ]]; then
  echo "::: [INFO] Detectado gestor de firewall: IPTABLES nativo."

  # 2.A - Regla MASQUERADE (NAT)
  if iptables -t nat -C POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule" &> /dev/null; then
    echo "::: [OK] Regla de enmascaramiento NAT (MASQUERADE) validada en Iptables."
  else
    global_error_flag=1
    echo -n "::: [ADVERTENCIA] Falta la regla MASQUERADE en la tabla NAT. ¿Inyectar regla ahora? [S/n]: "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
      if iptables -t nat -I POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule" && \
         mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4; then
        echo "::: [ÉXITO] Regla NAT consolidada y persistida en reglas del sistema."
      else
        err "No se pudo escribir o guardar la regla NAT en Iptables."
      fi
    fi
  fi

  # 2.B - Regla INPUT (Acceso al puerto de escucha de la VPN)
  if [[ "${INPUT_CHAIN_EDITED}" -eq 1 ]]; then
    if iptables -C INPUT -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule" &> /dev/null; then
      echo "::: [OK] Regla de entrada (INPUT) para el puerto ${pivpnPORT}/${pivpnPROTO} verificada."
    else
      global_error_flag=1
      echo -n "::: [ADVERTENCIA] Falta la regla de tráfico entrante INPUT. ¿Inyectar regla ahora? [S/n]: "
      read -r REPLY

      if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
        if iptables -I INPUT 1 -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule" && \
           iptables-save > /etc/iptables/rules.v4; then
          echo "::: [ÉXITO] Acceso de entrada INPUT reestablecido de forma persistente."
        else
          err "Fallo al estructurar la regla INPUT en la cadena principal."
        fi
      fi
    fi
  fi

  # 2.C - Reglas FORWARD (Tránsito de paquetes inter-interfaz)
  if [[ "${FORWARD_CHAIN_EDITED}" -eq 1 ]]; then
    if iptables -C FORWARD -s "${pivpnNET}/${subnetClass}" -i "${pivpnDEV}" -o "${IPv4dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule" &> /dev/null; then
      echo "::: [OK] Reglas de reenvío cruzado (FORWARD) validadas de extremo a extremo."
    else
      global_error_flag=1
      echo -n "::: [ADVERTENCIA] El tráfico de salto FORWARD no está autorizado. ¿Corregir topología de red? [S/n]: "
      read -r REPLY

      if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
        iptables -I FORWARD 1 -d "${pivpnNET}/${subnetClass}" -i "${IPv4dev}" -o "${pivpnDEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${VPN}-forward-rule"
        iptables -I FORWARD 2 -s "${pivpnNET}/${subnetClass}" -i "${pivpnDEV}" -o "${IPv4dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule"
        
        if iptables-save > /etc/iptables/rules.v4; then
          echo "::: [ÉXITO] Reglas de tránsito FORWARD aplicadas con control de estado (Conntrack)."
        else
          err "Excepción al persistir la cadena FORWARD."
        fi
      fi
    fi
  fi

else
  echo "::: [INFO] Detectado gestor de firewall: Uncomplicated Firewall (UFW)."

  # Validación de activación de UFW
  if LANG="en_US.UTF-8" ufw status | grep -qw 'active'; then
    echo "::: [OK] El servicio UFW se encuentra activo y aplicando políticas globales."
  else
    global_error_flag=1
    echo -n "::: [ADVERTENCIA] El cortafuegos UFW está inactivo. ¿Habilitar protección ahora? [S/n]: "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
      ufw --force enable
    fi
  fi

  # Regla MASQUERADE en entorno UFW
  if iptables -t nat -C POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule" &> /dev/null; then
    echo "::: [OK] Regla MASQUERADE persistida en las tablas nativas de UFW."
  else
    global_error_flag=1
    echo -n "::: [ADVERTENCIA] Falta la directiva NAT en las reglas internas de UFW. ¿Corregir archivo estático? [S/n]: "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
      local sed_pattern='/delete these required/i'
      sed_pattern="${sed_pattern} *nat\n:POSTROUTING ACCEPT [0:0]\n"
      sed_pattern="${sed_pattern} -I POSTROUTING -s ${pivpnNET}/${subnetClass} -o ${IPv4dev} -j MASQUERADE -m comment --comment ${VPN}-nat-rule\n"
      sed_pattern="${sed_pattern}COMMIT\n"

      sed "${sed_pattern}" -i /etc/ufw/before.rules
      ufw reload &> /dev/null
      echo "::: [ÉXITO] Archivo /etc/ufw/before.rules modificado. Reglas NAT recargadas."
      unset sed_pattern
    fi
  fi

  # Regla de Entrada de Usuario en UFW
  if iptables -C ufw-user-input -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT &> /dev/null; then
    echo "::: [OK] Perfil de puerto de entrada abierto en políticas de usuario UFW."
  else
    global_error_flag=1
    echo -n "::: [ADVERTENCIA] Falta regla de usuario entrante en UFW. ¿Permitir puerto ${pivpnPORT}/${pivpnPROTO}? [S/n]: "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
      ufw insert 1 allow "${pivpnPORT}"/"${pivpnPROTO}"
      ufw reload &> /dev/null
      echo "::: [ÉXITO] Puerto indexado en la posición prioritaria del Firewall."
    fi
  fi

  # Regla de Reenvío de Red (Routing/Forward) en UFW
  if iptables -C ufw-user-forward -i "${pivpnDEV}" -o "${IPv4dev}" -s "${pivpnNET}/${subnetClass}" -j ACCEPT &> /dev/null; then
    echo "::: [OK] Regla de enrutamiento inter-interfaz autorizada en UFW."
  else
    global_error_flag=1
    echo -n "::: [ADVERTENCIA] Ruta de paso denegada en UFW. ¿Insertar regla de ruteo interno? [S/n]: "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
      ufw route insert 1 allow in on "${pivpnDEV}" from "${pivpnNET}/${subnetClass}" out on "${IPv4dev}" to any
      ufw reload &> /dev/null
      echo "::: [ÉXITO] Flujo de paquetes de red acoplado a las políticas de UFW."
    fi
  fi
fi

# ==============================================================================
# 3. VERIFICACIÓN DE DEMONIOS Y PROCESOS DEL SISTEMA OPERATIVO
# ==============================================================================
if [[ "${PLAT}" == 'Alpine' ]]; then
  # Gestión de estados bajo OpenRC (Alpine Linux)
  if [[ "$(rc-service "${VPN_SERVICE}" status | sed -E -e 's/.*status\: (.*)/\1/')" == 'started' ]]; then
    echo "::: [OK] El demonio central ${VPN_PRETTY_NAME} se está ejecutando en segundo plano."
  else
    global_error_flag=1
    echo -n "::: [ADVERTENCIA] El servicio ${VPN_PRETTY_NAME} está detenido. ¿Forzar arranque ahora? [S/n]: "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
      rc-service -s "${VPN_SERVICE}" restart
      rc-service -N "${VPN_SERVICE}" start
      echo "::: [CORRECCIÓN] Comando de inicialización OpenRC enviado."
    fi
  fi

  if rc-update show default | grep -sEe "\s*${VPN_SERVICE} .*" &> /dev/null; then
    echo "::: [OK] El arranque automático de ${VPN_PRETTY_NAME} está habilitado en el runlevel por defecto."
  else
    global_error_flag=1
    echo -n "::: [ADVERTENCIA] El servicio no está programado para iniciar en el arranque. ¿Habilitar? [S/n]: "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
      rc-update add "${VPN_SERVICE}" default
      echo "::: [ÉXITO] Añadido al gestor de arranque init."
    fi
  fi
else
  # Gestión de estados bajo Systemd (Debian, Ubuntu, Raspberry Pi OS)
  if systemctl is-active -q "${VPN_SERVICE}"; then
    echo "::: [OK] El demonio central Systemd de ${VPN_PRETTY_NAME} se está ejecutando."
  else
    global_error_flag=1
    echo -n "::: [ADVERTENCIA] El socket/servicio de ${VPN_PRETTY_NAME} está inactivo. ¿Levantar servicio? [S/n]: "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
      systemctl start "${VPN_SERVICE}"
      echo "::: [CORRECCIÓN] Orden de arranque despachada a Systemd."
    fi
  fi

  if systemctl is-enabled -q "${VPN_SERVICE}"; then
    echo "::: [OK] El servicio ${VPN_PRETTY_NAME} está correctamente habilitado (persistente tras reinicios)."
  else
    global_error_flag=1
    echo -n "::: [ADVERTENCIA] El servicio se encuentra deshabilitado en el arranque del sistema. ¿Corregir? [S/n]: "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
      systemctl enable "${VPN_SERVICE}"
      echo "::: [ÉXITO] Enlace simbólico de arranque instanciado por Systemd."
    fi
  fi
fi

# ==============================================================================
# 4. AUDITORÍA DE SOCKETS DE RED (PUERTOS EN ESCUCHA ACTIVA)
# ==============================================================================
# Programación defensiva: Usar 'ss' si está disponible por rendimiento, si no, degradar a 'netstat'
local port_check_success=1

if command -v ss &> /dev/null; then
  ss -antulp | grep -wqE "${pivpnPROTO}.*:${pivpnPORT}" || port_check_success=0
else
  netstat -antu | grep -wqE "${pivpnPROTO}.*${pivpnPORT}" || port_check_success=0
fi

if [[ "${port_check_success}" -eq 1 ]]; then
  echo "::: [OK] El servidor ${VPN_PRETTY_NAME} está escuchando tráfico de red en el socket asignado (${pivpnPORT}/${pivpnPROTO})."
else
  global_error_flag=1
  echo -n "::: [ADVERTENCIA] Ningún proceso está escuchando en el puerto configurado ${pivpnPORT}/${pivpnPROTO}. ¿Reiniciar instancia? [S/n]: "
  read -r REPLY

  if [[ "${REPLY}" =~ ^[SsYy]$ ]] || [[ -z "${REPLY}" ]]; then
    if [[ "${PLAT}" == 'Alpine' ]]; then
      rc-service -s "${VPN_SERVICE}" restart
      rc-service -N "${VPN_SERVICE}" start
    else
      systemctl restart "${VPN_SERVICE}"
    fi
    echo "::: [CORRECCIÓN] Instancia de red reiniciada. Compruebe la conectividad externa."
  fi
fi

# ==============================================================================
# CONCLUSIÓN Y DIAGNÓSTICO FINAL DEL ENTORNO
# ==============================================================================
echo ":::"
if [[ "${global_error_flag}" -eq 1 ]]; then
  echo -e "::: [INFO] Se detectaron y/o mitigaron inconsistencias durante la comprobación."
  echo -e "::: [INFO] Se aconseja ejecutar nuevamente \e[1mpivpn -d\e[0m para certificar la estabilidad de la red."
else
  echo "::: [ÉXITO] La auditoría de integridad ha finalizado con éxito. El servidor opera bajo parámetros nominales."
fi
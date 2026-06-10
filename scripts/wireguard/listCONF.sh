#!/usr/bin/env bash
# PiVPN: Script para la enumeración y auditoría de configuraciones de clientes
# Optimizado para consistencia lingüística, trazabilidad avanzada y soporte de interfaces TUI (Whiptail).

export LANG=es_ES.UTF-8
export LC_ALL=es_ES.UTF-8

# ==============================================================================
#                 CONFIGURACIÓN DE VARIABLES GLOBALES Y ENTORNO
# ==============================================================================
# Detección automática de la ruta real según el protocolo instalado
if   [[ -r "/etc/pivpn/wireguard/setupVars.conf" ]]; then
    setupVarsFile="/etc/pivpn/wireguard/setupVars.conf"
elif [[ -r "/etc/pivpn/openvpn/setupVars.conf" ]]; then
    setupVarsFile="/etc/pivpn/openvpn/setupVars.conf"
else
    log_err "No se ha detectado el archivo de entorno maestro."
    log_err "Rutas comprobadas:"
    log_err "  • /etc/pivpn/wireguard/setupVars.conf"
    log_err "  • /etc/pivpn/openvpn/setupVars.conf"
    log_err "La instalación de PiVPN está incompleta o el servidor no ha sido aprovisionado."
    exit 1
fi

# Dimensiones adaptativas por defecto para cuadros de diálogo de whiptail
r=22
c=75

# Inicialización de paleta de colores para salida limpia en consola interactiva
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m' # Sin Color
else
    GREEN=''
    RED=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
fi

# Funciones estandarizadas de trazabilidad y logs en consola
log_info() { printf "${GREEN}::: [INFO] %s${NC}\n" "$1"; }
log_warn() { printf "${YELLOW}::: [ADVERTENCIA] %s${NC}\n" "$1"; }
log_err()  { printf "${RED}::: [ERROR] %s${NC}\n" "$1" >&2; }

# ==============================================================================
#                               VALIDACIONES PREVIAS
# ==============================================================================

# 1. Validar privilegios de ejecución (Requerido para leer llaves/rutas restringidas de WireGuard u OpenVPN)
if [ "$EUID" -ne 0 ]; then
    log_err "Este script requiere privilegios de seguridad elevados."
    echo "::: Por favor, reintente la ejecución anteponiendo el comando 'sudo'." >&2
    
    # Disparar alerta visual interactiva si se intenta invocar mediante un menú gráfico
    if [ "$1" = "--gui" ] && command -v whiptail >/dev/null 2>&1; then
        whiptail --backtitle "Asistente de Gestión - PiVPN" \
                 --title "Error de Privilegios Administrativos" \
                 --ok-button "Entendido" \
                 --msgbox "Operación denegada. Se requieren privilegios de superusuario (root) para consultar los clientes del servidor VPN." "$r" "$c"
    fi
    exit 1
fi

# 2. Validar existencia de la base de variables maestro de PiVPN
if [ ! -f "${setupVarsFile}" ]; then
    log_err "No se ha detectado el archivo de entorno maestro en: ${setupVarsFile}"
    log_err "La instalación de PiVPN está incompleta o el servidor no ha sido aprovisionado."
    exit 1
fi

# Carga segura del mapa de variables de configuración de red
# shellcheck source=/dev/null
source "${setupVarsFile}"
log_info "Infraestructura de PiVPN validada. Analizando asignación de túneles..."

# ==============================================================================
#                          LÓGICA PRINCIPAL DE EXTRACCIÓN
# ==============================================================================

OUTPUT_BUFFER_COLOR=""
OUTPUT_BUFFER_PLAIN=""

if [ "${VPN}" = "openvpn" ]; then
    log_info "Entorno detectado: OpenVPN. Procesando registros de Easy-RSA..."
    
    INDEX="/etc/openvpn/easy-rsa/pki/index.txt"
    if [ ! -f "${INDEX}" ]; then
        log_err "No se pudo localizar el índice analítico de certificados criptográficos en: ${INDEX}"
        exit 1
    fi

    # Definición de cabeceras estructuradas
    header=$(printf "%-25s %-22s %-20s\n" "IDENTIFICADOR (CLIENTE)" "ESTADO OPERATIVO" "EXPIRACIÓN (UTC)")
    divider="------------------------------------------------------------------------"

    while read -r line || [ -n "$line" ]; do
        status=$(echo "$line" | awk '{print $1}')
        
        # Filtrar únicamente registros válidos (V) o revocados (R) de Easy-RSA
        if [ "${status}" = "V" ] || [ "${status}" = "R" ]; then
            name=$(echo "$line" | awk -F= '{print $2}')
            
            # Omitir de forma segura el certificado nativo del Servidor Central
            if [ "${name}" != "server" ] && [ -n "${name}" ]; then
                exp_date=$(echo "$line" | awk '{print $2}')
                
                # Conversión cosmética del formato de fecha ASN.1 (YYMMDDHHMMSSZ) a ISO Legible
                formatted_date="20${exp_date:0:2}-${exp_date:2:2}-${exp_date:4:2} ${exp_date:6:2}:${exp_date:8:2}"
                
                if [ "${status}" = "V" ]; then
                    state_str=$(printf "${GREEN}%-22s${NC}" "Válido / Activo")
                    state_plain=$(printf "%-22s" "Válido / Activo")
                else
                    state_str=$(printf "${RED}%-22s${NC}" "Revocado / Inactivo")
                    state_plain=$(printf "%-22s" "Revocado / Inactivo")
                fi
                
                # Compilación paralela de buffers (Consola ANSI vs Texto plano para Whiptail)
                OUTPUT_BUFFER_COLOR="${OUTPUT_BUFFER_COLOR}$(printf "%-25s %s %-20s\n" "${name}" "${state_str}" "${formatted_date}")\n"
                OUTPUT_BUFFER_PLAIN="${OUTPUT_BUFFER_PLAIN}$(printf "%-25s %s %-20s\n" "${name}" "${state_plain}" "${formatted_date}")\n"
            fi
        fi
    done < "${INDEX}"

elif [ "${VPN}" = "wireguard" ]; then
    log_info "Entorno detectado: WireGuard. Extrayendo topología de pares (Peers)..."

    WG_CONF="/etc/wireguard/wg0.conf"
    CLIENTS_TXT="/etc/wireguard/configs/clients.txt"

    # Validar existencia Y permisos de lectura (el directorio usa chmod 700 en install.sh)
    if [ ! -f "${WG_CONF}" ]; then
        log_err "No se encontró el archivo de configuración del dispositivo de red: ${WG_CONF}"
        exit 1
    fi

    if [ ! -r "${WG_CONF}" ]; then
        log_err "Sin permisos de lectura sobre: ${WG_CONF}. Verifica que el script se ejecuta como root."
        exit 1
    fi

    header=$(printf "%-28s %-20s %-18s\n" "IDENTIFICADOR (PEER)" "IP ASIGNADA" "ESTADO DEL PERFIL")
    divider="------------------------------------------------------------------------"

    # Cruce entre marcadores ### Client y su bloque [Peer] inmediato para extraer IP asignada.
    # Se usa una máquina de estados simple en lugar de múltiples greps/pipes al archivo.
    in_peer_block=false
    current_client=""
    current_ip=""

    while IFS= read -r line || [ -n "${line}" ]; do

        # Detectar marcador de comentario generado por PiVPN: "### Client NombreCliente"
        if [[ "${line}" =~ ^###[[:space:]]Client[[:space:]](.+)$ ]]; then
            # Guardar nombre: expansión de parámetros Bash pura, sin subprocesos awk/echo
            current_client="${BASH_REMATCH[1]}"
            current_ip=""
            in_peer_block=true
            continue
        fi

        # Dentro del bloque [Peer] activo, capturar la primera AllowedIPs del peer
        if [ "${in_peer_block}" = "true" ]; then
            # Detectar inicio de un nuevo bloque de sección que NO sea el peer actual
            if [[ "${line}" =~ ^\[.*\]$ && "${line}" != "[Peer]" ]]; then
                in_peer_block=false
                current_client=""
                current_ip=""
                continue
            fi

            # Extraer la IP asignada desde AllowedIPs (primer CIDR host /32 o /128)
            if [[ "${line}" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*([^,[:space:]]+) ]]; then
                current_ip="${BASH_REMATCH[1]}"
            fi
        fi

        # Línea en blanco o separador: emitir el peer acumulado si está completo
        if [ "${in_peer_block}" = "true" ] && [ -z "${line}" ] && [ -n "${current_client}" ]; then
            _emit_wg_peer "${current_client}" "${current_ip:-N/A}"
            in_peer_block=false
            current_client=""
            current_ip=""
        fi

    done < "${WG_CONF}"

    # Emitir el último peer si el archivo no termina con línea en blanco
    if [ "${in_peer_block}" = "true" ] && [ -n "${current_client}" ]; then
        _emit_wg_peer "${current_client}" "${current_ip:-N/A}"
    fi
#=====================================================================================
# Función auxiliar para formatear la salida de cada peer de WireGuard
# Función auxiliar: compone y acumula la línea formateada de un peer WireGuard
# Uso interno exclusivo del bloque WireGuard de listCONF / makeCONF
#=====================================================================================
_emit_wg_peer() {
    local peer_name="$1"
    local peer_ip="$2"

    # Verificación cruzada opcional con clients.txt para confirmar registro canónico
    local state_str state_plain
    if [ -f "${CLIENTS_TXT}" ] && grep -qF "${peer_name}" "${CLIENTS_TXT}" 2>/dev/null; then
        state_str=$(printf "${GREEN}%-20s${NC}" "Registrado")
        state_plain=$(printf "%-20s" "Registrado")
    else
        # Peer presente en wg0.conf pero ausente en el índice → posible inconsistencia
        state_str=$(printf "${YELLOW}%-20s${NC}" "Sin índice")
        state_plain=$(printf "%-20s" "Sin índice")
        log_warn "Peer '${peer_name}' encontrado en wg0.conf pero no en clients.txt"
    fi

    OUTPUT_BUFFER_COLOR="${OUTPUT_BUFFER_COLOR}$(printf "%-28s %-18s %s\n" "${peer_name}" "${peer_ip}" "${state_str}")\n"
    OUTPUT_BUFFER_PLAIN="${OUTPUT_BUFFER_PLAIN}$(printf "%-28s %-18s %s\n" "${peer_name}" "${peer_ip}" "${state_plain}")\n"
}


# ==============================================================================
#                        PRESENTACIÓN Y SALIDA DE DATOS
# ==============================================================================

# Comprobar si los buffers resultaron vacíos tras el análisis
if [ -z "${OUTPUT_BUFFER_PLAIN}" ]; then
    log_warn "La consulta finalizó con éxito, pero no se encontraron perfiles de clientes registrados."
    if [ "$1" = "--gui" ] && command -v whiptail >/dev/null 2>&1; then
        whiptail --backtitle "Asistente de Gestión - PiVPN" \
                 --title "Información de Clientes" \
                 --ok-button "Volver" \
                 --msgbox "Actualmente no existen configuraciones de clientes activas en este servidor." "$r" "$c"
    fi
    exit 0
fi

# Renderizado condicional según el parámetro de ejecución (--gui o estándar)
if [ "$1" = "--gui" ] && command -v whiptail >/dev/null 2>&1; then
    # Agrupación y despliegue dentro de un cuadro de diálogo TUI interactivo
    FINAL_GUI_OUTPUT=$(printf "${header}\n${divider}\n${OUTPUT_BUFFER_PLAIN}")
    whiptail --backtitle "Asistente de Configuración - PiVPN" \
             --title "Listado General de Clientes" \
             --ok-button "Cerrar Administrador" \
             --msgbox "${FINAL_GUI_OUTPUT}" "$r" "$c"
else
    # Impresión enriquecida con colores directamente sobre el terminal anfitrión
    printf "\n${BLUE}========================================================================${NC}\n"
    printf "                 ${CYAN}AUDITORÍA EXTERNA: CLIENTES CONFIGURADOS${NC}\n"
    printf "${BLUE}========================================================================${NC}\n"
    printf "${header}\n${divider}\n"
    printf "${OUTPUT_BUFFER_COLOR}"
    printf "${BLUE}========================================================================${NC}\n"
    log_info "Mapeo de estado y trazabilidad completados con éxito."
fi
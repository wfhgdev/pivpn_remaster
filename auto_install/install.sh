#!/usr/bin/env bash
# PiVPN: Configuración e instalación trivial de OpenVPN o WireGuard
# La configuración y gestión más sencilla de OpenVPN o WireGuard en Raspberry Pi OS, Debian y Ubuntu.
export LANG=es_ES.UTF-8
export LC_ALL=es_ES.UTF-8

# ==============================================================================
#                 CONFIGURACIÓN DE RUTAS Y VARIABLES GLOBALES
# ==============================================================================

pivpnGitUrl="https://github.com/pivpn/pivpn.git"

# Para desarrollo: Descomentar y asignar una rama específica si se desea probar código en pruebas
# pivpnGitBranch="custombranchtocheckout"

# Archivos y directorios clave del ecosistema PiVPN
setupVarsFile="setupVars.conf"
setupConfigDir="/etc/pivpn"
tempsetupVarsFile="/tmp/setupVars.conf"
pivpnFilesDir="/usr/local/src/pivpn"
pivpnScriptDir="/opt/pivpn"
GITBIN="/usr/bin/git"

# Integraciones de terceros (Pi-hole / DNSMasq)
piholeVersions="/etc/pihole/versions"
dnsmasqConfig="/etc/dnsmasq.d/02-pivpn.conf"

# Archivos de red y asignaciones de seguridad de OpenVPN
dhcpcdFile="/etc/dhcpcd.conf"
ovpnUserGroup="openvpn:openvpn"

# ==============================================================================
#            GESTIÓN DE PAQUETES Y ARREGLOS DE DEPENDENCIAS
# ==============================================================================

PKG_MANAGER="apt-get"

# SOLUCIÓN DE ERROR CRÍTICO: El uso de cadenas simples provocaba fallos de parsing en ShellCheck (SC2086) 
# y cuelgues aleatorios en el flujo. Se transforman a arreglos nativos de Bash para una expansión segura.
UPDATE_PKG_CACHE=("${PKG_MANAGER}" "update" "-y")
PKG_INSTALL=("${PKG_MANAGER}" "--yes" "--no-install-recommends" "install")

# Comando de monitorización (mantiene estructura de cadena debido al uso de tuberías/pipes)
PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true"
CHECK_PKG_INSTALLED='dpkg-query -s'

# Dependencias base necesarias para sistemas Debian / Ubuntu (independientes del protocolo)
BASE_DEPS=(
  git 
  tar 
  curl 
  grep 
  bind9-dnsutils 
  grepcidr 
  whiptail 
  net-tools
  bsdmainutils 
  bash-completion
)

# Dependencias base optimizadas exclusivamente para entornos Alpine Linux
BASE_DEPS_ALPINE=(
  git 
  grep 
  bind-tools 
  newt 
  net-tools 
  bash-completion 
  coreutils
  openssl 
  util-linux 
  openrc 
  iptables 
  ip6tables 
  sed
  perl 
  libqrencode-tools
)

# Registro dinámico de paquetes instalados durante esta sesión. 
# Evita purgar utilidades preexistentes del usuario al ejecutar una desinstalación.
INSTALLED_PACKAGES=()

# ==============================================================================
#                         RECURSOS Y COMPONENTES EXTERNOS
# ==============================================================================

easyrsaVer="3.2.3"
easyrsaRel="https://github.com/OpenVPN/easy-rsa/releases/download/v${easyrsaVer}/EasyRSA-${easyrsaVer}.tgz"

# ==============================================================================
#          BANDERAS DE AUTOMATIZACIÓN (MODO DESATENDIDO / ADVANCED)
# ==============================================================================

runUnattended=false
usePiholeDNS=false
skipSpaceCheck=false
reconfigure=false
showUnsupportedNICs=false

# Inicializaciones preventivas de variables globales para mitigar errores 
# de referencia vacía ("unbound variable") durante comprobaciones lógicas estrictas.
pivpnPERSISTENTKEEPALIVE=""
pivpnDNS2=""

# ==============================================================================
#                  POLÍTICAS Y CONFIGURACIONES DE RED IPv6
# ==============================================================================

# Nota técnica: El uso del parámetro CLI "--noipv6" desactiva por completo el protocolo,
# previniendo tanto fugas como enrutamientos forzados innecesarios.
# El uso de "--ignoreipv6leak" mitiga la inyección de rutas (No recomendado en producción).

# 1 = Mitigación activa. Fuerza el tráfico IPv6 a través del túnel VPN para prevenir fugas (leak)
# en el cliente, incluso si el servidor carece de conectividad IPv6 nativa hacia el exterior.
pivpnforceipv6route=1

# Estado dinámico del protocolo. Un valor vacío o "1" iniciará un test de enlace ascendente (uplink).
pivpnenableipv6=""

# 1 = Modo bypass estricto. Omite las pruebas de conectividad de red locales y fuerza la tunelización
# total de paquetes IPv6 del cliente hacia la interfaz de WireGuard de forma incondicional.
pivpnforceipv6=0

# ==============================================================================
#          CÁLCULO DINÁMICO DE RESOLUCIÓN PARA INTERFACES WHIPTAIL
# ==============================================================================

# Captura geométrica de la terminal. Si falla o se ejecuta en entornos no interactivos,
# se asume una matriz segura estandarizada de 24 filas por 80 columnas.
screen_size="$(stty size 2> /dev/null || echo "24 80")"

# OPTIMIZACIÓN DE RENDIMIENTO: Reemplazo de subprocesos 'awk' por el comando interno 'read' de Bash.
# Esto reduce el consumo de CPU y elimina dependencias de binarios externos en la inicialización.
read -r rows columns <<< "${screen_size}"

# Dimensionamiento adaptativo: Los menús interactivos escalarán al 50% del tamaño total disponible.
r=$(( rows / 2 ))
c=$(( columns / 2 ))

# MÁRGENES DE SEGURIDAD INTERFAZ: Forzamos límites mínimos de 20 filas y 70 columnas.
# Esto garantiza la correcta visualización de los contenedores de texto, saltos de línea
# y botones de acción de 'Whiptail', evitando truncamientos de interfaz en pantallas pequeñas.
[[ ${r} -lt 20 ]] && r=20
[[ ${c} -lt 70 ]] && c=70

# ==============================================================================
#               TRAZABILIDAD Y MENSAJES DE INICIALIZACIÓN (LOGS)
# ==============================================================================

echo "::: "
echo "::: [INFO] Inicializando variables del entorno e identificando recursos del sistema..."
echo "::: [INFO] Geometría de pantalla configurada para diálogos: ${r} Filas x ${c} Columnas."

# Mantenemos desactivada la sobrescritura forzada de localización del sistema para permitir
# que los mensajes y diálogos emergentes se rendericen en el idioma nativo configurado (ej: es_ES).
# export LC_ALL=C

main() {
  # Asegura la eliminación automática de configuraciones temporales al salir,
  # ya sea por finalización exitosa, error crítico o cancelación con Ctrl+C.
  trap 'rm -f "${tempsetupVarsFile}"' EXIT

  # ==========================================
  # FASE 1: VALIDACIONES E INICIALIZACIÓN
  # ==========================================

  # Procesa primero los argumentos de entrada (--unattended, --skip-space-check, etc.)
  # para que sus variables asociadas estén disponibles en las comprobaciones posteriores.
  flagsCheck "$@"
  distroCheck
  rootCheck
  unattendedCheck
  checkExistingInstall "$@"
  checkHostname

  # Comprobación de almacenamiento disponible
  if [[ "${skipSpaceCheck}" == 'true' ]]; then
    echo "::: Opción --skip-space-check activa: Omitiendo la validación de espacio libre en disco."
  else
    verifyFreeDiskSpace
  fi

  # ==========================================
  # FASE 2: GESTIÓN DE PAQUETES Y DEPENDENCIAS
  # ==========================================

  updatePackageCache
  notifyPackageUpdatesAvailable
  preconfigurePackages

  # Selección e instalación del conjunto de dependencias según la distribución
  if [[ "${PLAT}" == 'Alpine' ]]; then
    installDependentPackages BASE_DEPS_ALPINE
  else
    installDependentPackages BASE_DEPS
  fi

  # Mostrar diálogos de bienvenida interactivos
  welcomeDialogs

  # ==========================================
  # FASE 3: CONFIGURACIÓN DE RED (IPv4 / IPv6)
  # ==========================================

  # Evaluación y enrutamiento del protocolo IPv6
  if [[ "${pivpnforceipv6}" -eq 1 ]]; then
    echo "::: Forzando IPv6 por parámetro: Omitiendo la comprobación del enlace ascendente."
    pivpnenableipv6=1
  else
    if [[ -z "${pivpnenableipv6}" ]] \
      || [[ "${pivpnenableipv6}" -eq 1 ]]; then
      checkipv6uplink
    fi

    if [[ "${pivpnenableipv6}" -eq 0 ]] \
      && [[ "${pivpnforceipv6route}" -eq 1 ]]; then
      askforcedipv6route
    fi
  fi

  # Configuración de interfaces y asignación de direccionamiento IP estático
  chooseInterface

  if checkStaticIpSupported; then
    getStaticIPv4Settings

    # Aplica IP estática solo si no se ha confirmado una reserva DHCP previa
    if [[ "${dhcpReserv}" != "1" ]]; then
      setStaticIPv4
    fi
  else
    staticIpNotSupported
  fi

  # Selección del usuario local del sistema que gestionará los perfiles VPN
  chooseUser
  cloneOrUpdateRepos

  # ==========================================
  # FASE 4: INSTALACIÓN Y DESPLIEGUE NÚCLEO
  # ==========================================

  # Ejecución del instalador principal de la VPN
  if installPiVPN; then
    echo "::: Instalación del núcleo completada con éxito."
  else
    echo "::: [ERROR CRÍTICO] Falló la instalación del núcleo de PiVPN. Abortando proceso."
    exit 1
  fi

  # Reinicio de los servicios de red y del software VPN para aplicar los cambios
  restartServices
  
  # ==========================================
  # FASE 5: POST-INSTALACIÓN Y CONFIGURACIÓN
  # ==========================================

  # Gestión del servicio de actualizaciones de seguridad desatendidas
  askUnattendedUpgrades

  if [[ "${UNATTUPG}" == "1" ]]; then
    confUnattendedUpgrades
  fi

  # Escritura de perfiles, variables finales y despliegue de comandos del sistema
  if ! writeConfigFiles; then
    echo "::: [ERROR CRÍTICO] No se pudieron generar los archivos de configuración finales."
    exit 1
  fi

  if ! installScripts; then
    echo "::: [ERROR CRÍTICO] No se pudieron desplegar los scripts de gestión 'pivpn' en el sistema."
    exit 1
  fi

  # Muestra el resumen final de la instalación y opciones de reinicio del servidor
  displayFinalMessage
  echo ":::"
}

####### FUNCTIONS ##########

# Genera un flujo de salida formateado hacia el canal de errores estándar (stderr)
# incluyendo una marca de tiempo estandarizada ISO 8601.
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [ERROR]: $*" >&2
}

rootCheck() {
  echo ":::"
  
  # Validación de UID: El identificador 0 corresponde exclusivamente a 'root'
  if [[ "${EUID}" -eq 0 ]]; then
    echo "::: [INFO] Privilegios nativos de administrador (root) confirmados."
    # Asegura la limpieza de variables de prefijo en entornos root puros
    export SUDO=""
    export SUDOE=""
  else
    # Corrección de redacción: El script no eleva privilegios por sí mismo en este punto,
    # prepara las variables de entorno para la ejecución delegada posterior.
    echo "::: [INFO] Usuario estándar detectado. Configurando entorno seguro mediante 'sudo'..."

    # Verifica mediante el gestor nativo de la distribución si 'sudo' se encuentra operativo
    if eval "${CHECK_PKG_INSTALLED} sudo" &> /dev/null; then
      export SUDO="sudo"
      export SUDOE="sudo -E"
      echo "::: [INFO] Herramienta 'sudo' validada. Se aplicará como prefijo en tareas del sistema."
    else
      err "Entorno restrictivo. El instalador requiere binarios de elevación. Por favor, instala 'sudo' o ejecuta el script como root."
      exit 1
    fi
  fi
}

flagsCheck() {
  echo ":::"
  echo "::: [INFO] Iniciando el análisis de argumentos y directivas de ejecución por CLI..."

  # SOLUCIÓN DE BUG CRÍTICO: El bucle clásico 'for ((i...))' con expansión indirecta '${!j}'
  # procesaba los argumentos de las banderas (ej. la ruta de --unattended) como si fueran
  # banderas independientes en la siguiente iteración. 
  # Se migra a un control de flujo 'while' nativo basado en desplazamientos ('shift').
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-space-check)
        skipSpaceCheck=true
        echo "::: [PARAM] Directiva activa: Omitiendo la comprobación de almacenamiento local."
        shift
        ;;
      --unattended)
        runUnattended=true
        # Validación preventiva: Asegura que exista un argumento posterior y que no sea otra bandera
        if [[ -n "$2" && "$2" != -* ]]; then
          unattendedConfig="$2"
          echo "::: [PARAM] Modo desatendido activo. Cargando configuración desde: ${unattendedConfig}"
          shift 2
        else
          err "La bandera '--unattended' requiere una ruta válida a un archivo de configuración."
          exit 1
        fi
        ;;
      --use-pihole)
        usePiholeDNS=true
        echo "::: [PARAM] Integración activa: Forzando uso del servidor DNS Pi-hole local."
        shift
        ;;
      --reconfigure)
        reconfigure=true
        echo "::: [PARAM] Solicitud activa: Iniciando el asistente en modo reconfiguración total."
        shift
        ;;
      --show-unsupported-nics)
        showUnsupportedNICs=true
        echo "::: [PARAM] Modo avanzado: Permitiendo visualización de interfaces de red no homologadas."
        shift
        ;;
      --giturl)
        if [[ -n "$2" && "$2" != -* ]]; then
          pivpnGitUrl="$2"
          echo "::: [PARAM] Despliegue modificado: Repositorio origen reasignado a: ${pivpnGitUrl}"
          shift 2
        else
          err "La bandera '--giturl' requiere una URL válida a un repositorio de Git."
          exit 1
        fi
        ;;
      --gitbranch)
        if [[ -n "$2" && "$2" != -* ]]; then
          pivpnGitBranch="$2"
          echo "::: [PARAM] Despliegue modificado: Cambiando a la rama de desarrollo: ${pivpnGitBranch}"
          shift 2
        else
          err "La bandera '--gitbranch' requiere especificar el nombre de una rama válida."
          exit 1
        fi
        ;;
      --noipv6)
        pivpnforceipv6=0
        pivpnenableipv6=0
        pivpnforceipv6route=0
        echo "::: [PARAM] Directiva estricta: Desactivación completa del direccionamiento IPv6."
        shift
        ;;
      --ignoreipv6leak)
        pivpnforceipv6route=0
        echo "::: [PARAM] Advertencia: Se ignorará la inyección de rutas para mitigar fugas IPv6."
        shift
        ;;
      *)
        # Captura e informa al administrador sobre argumentos huérfanos o inválidos pasados al script
        echo "::: [ADVERTENCIA] Parámetro desconocido detectado e ignorado en el flujo: $1"
        shift
        ;;
    esac
  done

  echo "::: [INFO] Finalizado el análisis de argumentos. Estado del entorno consolidado."
}

# ==============================================================================
#                 COMPROBACIONES DE MODO DE EJECUCIÓN Y ENTORNO
# ==============================================================================

unattendedCheck() {
  # Cláusula de guarda: Si no se solicita instalación desatendida, salir de inmediato
  [[ "${runUnattended}" != 'true' ]] && return

  echo "::: [INFO] Modo desatendido activo (--unattended). Se omitirán las interfaces gráficas (whiptail)."

  # Validación de presencia del argumento de configuración
  if [[ -z "${unattendedConfig}" ]]; then
    err "Operación abortada: No se especificó la ruta del archivo de configuración para el modo desatendido."
    exit 1
  fi

  # Validación de existencia y permisos de lectura del archivo de configuración
  if [[ ! -r "${unattendedConfig}" ]]; then
    err "Error de lectura: El archivo de configuración desatendida '${unattendedConfig}' no existe o no es accesible."
    exit 1
  fi

  echo "::: [INFO] Importando directivas de aprovisionamiento desde: ${unattendedConfig}"
  # shellcheck disable=SC1090
  . "${unattendedConfig}"
}

checkExistingInstall() {
  # Definición explícita de variable local para proteger el espacio de nombres global
  local setupVars=""
  
  echo "::: [INFO] Analizando el sistema en busca de instancias previas de PiVPN..."

  # Identificación de rutas y perfiles de configuración según el protocolo implementado
  if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/wireguard/${setupVarsFile}"
    echo "::: [INFO] Alerta: Se detectó un entorno preexistente de WireGuard."
  elif [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/openvpn/${setupVarsFile}"
    echo "::: [INFO] Alerta: Se detectó un entorno preexistente de OpenVPN."
  fi

  # Saneamiento del entorno: Eliminación segura de residuos temporales de sesiones previas
  if [[ -f "${tempsetupVarsFile}" ]]; then
    echo "::: [INFO] Removiendo archivo de variables temporal obsoleto..."
    ${SUDO} rm -f "${tempsetupVarsFile}"
  fi

  # Evaluación del flujo de toma de decisiones ante sistemas existentes
  if [[ -n "${setupVars}" ]]; then
    if [[ "${reconfigure}" == 'true' ]]; then
      echo "::: [PARAM] Directiva --reconfigure detectada: Se sobrescribirá por completo el despliegue actual."
      UpdateCmd="Reconfigure"
    elif [[ "${runUnattended}" == 'true' ]]; then
      echo "::: [PARAM] Colisión detectada en modo desatendido: Forzando reconfiguración automatizada."
      UpdateCmd="Reconfigure"
    else
      # Invoca el cuadro de diálogo gráfico interactivo (puede devolver valores en español)
      askAboutExistingInstall "${setupVars}"
    fi
  fi

  # ==============================================================================
  #            PROCESAMIENTO Y ENRUTAMIENTO DE LA ESTRATEGIA DE CONTROL
  # ==============================================================================
# Soportamos tanto los flags internos (inglés) como las respuestas de la interfaz (español)
  case "${UpdateCmd}" in
    Update|[Aa]ctualizar)
      echo "::: [INFO] Delegando el ciclo de vida al script oficial de actualización de PiVPN..."
      ${SUDO} "${pivpnScriptDir}/update.sh" "$@"
      exit "$?"
      ;;
      
    Repair|[Rr]eparar)
      echo "::: [INFO] Modo reparación activo. Restaurando variables de entorno históricas..."
      # shellcheck disable=SC1090
      . "${setupVars}"
      runUnattended=true
      ;;
      
    Reconfigure|[Rr]econfigurar|"")
      # Flujo normal o de sobreescritura: Informamos trazabilidad y permitimos continuar al main()
      if [[ -n "${setupVars}" ]]; then
        echo "::: [INFO] Preparando los módulos para la reescritura total de la VPN."
      else
        echo "::: [INFO] No se encontraron trazas de software previo. Procediendo con instalación limpia."
      fi
      ;;
      
    *)
      err "Estado de control inconsistente: La directiva de actualización '${UpdateCmd}' no está homologada."
      exit 1
      ;;
  esac
}

askAboutExistingInstall() {
  # TRAZABILIDAD: Registro previo para monitorizar la apertura de componentes interactivos en primer plano
  echo "::: [INFO] Iniciando cuadro de diálogo interactivo para resolver colisión de instalación..."

  # ÁMBITO SEGURO: Declaración local de etiquetas del menú con terminología técnica homologada
  local opt1a="Actualizar"
  local opt1b="Actualizar scripts y componentes internos de PiVPN"

  local opt2a="Reparar"
  local opt2b="Corrige archivos corruptos manteniendo configuración"

  local opt3a="Reconfigurar"
  local opt3b="Reinstalar desde cero o modificar protocolo VPN"

  # INTERFAZ DE USUARIO: Menú adaptativo estructurado con información detallada del entorno detectado
UpdateCmd="$(whiptail \
    --backtitle "Asistente de Configuración PiVPN" \
    --title "¡Instalación Existente Detectada!" \
    --ok-button "Seleccionar" \
    --cancel-button "Cancelar" \
    --menu "El asistente ha detectado un entorno de PiVPN ya operativo en este sistema.

Archivo de variables localizado:
• ${1}

Por favor, selecciona la acción que deseas realizar para continuar:" "${r}" "${c}" 3 \
    "${opt1a}" "${opt1b}" \
    "${opt2a}" "${opt2b}" \
    "${opt3a}" "${opt3b}" \
    3>&2 2>&1 1>&3)" \
    || {
      echo ":::"
      err "Instalación cancelada por el usuario en el menú de selección de entorno existente."
      exit 1
    }

  # TRAZABILIDAD: Confirmación del estado consolidado para guiar los bloques de enrutamiento subsiguientes
  echo "::: [INFO] Acción seleccionada con éxito: '${UpdateCmd}'."
}

distroCheck() {
  # TRAZABILIDAD: Registro de entrada para auditoría y diagnóstico de compatibilidad del sistema
  echo "::: [INFO] Iniciando análisis de compatibilidad de la distribución de Linux..."

  # ==============================================================================
  # DETERMINACIÓN DE PLATAFORMA Y NOMBRE CLAVE (CODENAME)
  # ==============================================================================
  if command -v lsb_release > /dev/null; then
    echo "::: [INFO] Componente 'lsb_release' detectado. Extrayendo metadatos del entorno..."
    PLAT="$(lsb_release -si)"
    OSCN="$(lsb_release -sc)"
    
    # NORMALIZACIÓN: Uniformar el identificador de Raspberry Pi OS para mantener consistencia con el script
    if [[ "${PLAT}" == "RaspberryPiOS" ]]; then
      PLAT="Raspberry"
    fi
  else
    echo "::: [INFO] 'lsb_release' no disponible. Consultando archivo de sistema '/etc/os-release'..."
    # shellcheck disable=SC1091
    . /etc/os-release
    
    # Clasificación de entornos específicos basados en arquitecturas ARM / Raspberry
    if [[ "${ID}" == "raspbian" || "${ID}" == "raspberrypi" || "${ID_LIKE}" == *"raspbian"* ]]; then
      PLAT="Raspberry"
    else
      # OPTIMIZACIÓN: Reemplazo de subproceso externo 'awk' por expansión de parámetros interna de Bash.
      # Elimina la bifurcación de CPU extrayendo de forma segura la primera palabra del campo NAME.
      PLAT="${NAME%% *}"
    fi
    
    VER="${VERSION_ID}"
    
    # ÁMBITO SEGURO: Declaración local del mapa asociativo de versiones para prevenir polución global
    local -A VER_MAP=(
      ["11"]="bullseye"
      ["12"]="bookworm"
      ["13"]="trixie"
      ["20.04"]="focal"
      ["22.04"]="jammy"
      ["24.04"]="noble"
      ["26.04"]="resolute"
    )
    OSCN="${VER_MAP["${VER}"]}"

    # SOPORTE INTEGRADO: Si la distribución carece de codename textual (ej. Alpine), se adopta su versión numérica
    if [[ -z "${OSCN}" ]]; then
      OSCN="${VER}"
    fi
  fi

  echo "::: [INFO] Resultados del análisis de entorno: Plataforma='${PLAT}' | Nombre Clave='${OSCN}'."

  # ==============================================================================
  # VALIDACIÓN Y CONFIGURACIÓN DINÁMICA DE ENTORNO SEGÚN DISTRIBUCIÓN
  # ==============================================================================
  case "${PLAT}" in
    Debian | Raspbian | Raspberry | Ubuntu)
      case "${OSCN}" in
        bullseye | bookworm | trixie | focal | jammy | noble | resolute)
          echo "::: [INFO] Validación exitosa: Entorno homologado y totalmente compatible."
          ;;
        *)
          echo "::: [ADVERTENCIA] Nombre clave '${OSCN}' no verificado oficialmente. Evaluando soporte secundario..."
          maybeOSSupport
          ;;
      esac
      ;;
      
    Alpine)
      echo "::: [INFO] Arquitectura Alpine Linux identificada. Reconfigurando subsistema de paquetes a 'apk'..."
      PKG_MANAGER='apk'
      UPDATE_PKG_CACHE="${PKG_MANAGER} update"
      PKG_INSTALL="${PKG_MANAGER} --no-cache add"
      PKG_COUNT="${PKG_MANAGER} list -u | wc -l || true"
      CHECK_PKG_INSTALLED="${PKG_MANAGER} --no-cache info -e"
      ;;
      
    *)
      echo "::: [ERROR CRÍTICO] Distribución '${PLAT}' no compatible o fuera de los parámetros de soporte."
      noOSSupport
      ;;
  esac

  # PERSISTENCIA: Volcado seguro de las variables validadas para su posterior consumo por los submódulos
  echo "::: [INFO] Almacenando variables de entorno consolidadas en el perfil temporal..."
  {
    echo "PLAT=${PLAT}"
    echo "OSCN=${OSCN}"
  } > "${tempsetupVarsFile}"
}

noOSSupport() {
  if [[ "${runUnattended}" == 'true' ]]; then
    err "::: Sistema Operativo no válido detectado"
    err "::: No hemos podido detectar un Sistema Operativo compatible."
    err "::: Actualmente este instalador soporta Raspberry Pi OS, Debian y Ubuntu."
    exit 1
  fi

  whiptail \
  --backtitle "Error de Compatibilidad de Sistema Operativo" \
  --title "Sistema Operativo No Soportado" --ok-button "Salir" \
  --msgbox "El asistente no ha podido detectar una distribución Linux compatible con este instalador de forma nativa.

Para garantizar la estabilidad, este script solo está diseñado para:
• Raspberry Pi OS (32 y 64 bits)
• Debian Linux
• Ubuntu Server

Si crees que se trata de un error o deseas revisar los requisitos técnicos, por favor consulta la documentación en:
https://github.com/wfhgdev/pivpn_spanish" "${r}" "${c}"
  exit 1
}

maybeOSSupport() {
  # TRAZABILIDAD: Registro inicial para dejar constancia en auditorías del proceso de evaluación del sistema
  echo "::: [INFO] Evaluando compatibilidad para sistema operativo no verificado oficialmente..."

  # MODO DESATENDIDO: Forzar continuación automatizada si se ha declarado la bandera 'runUnattended'
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [ADVERTENCIA] Entorno operativo alternativo detectado en modo desatendido."
    echo "::: [INFO] Omitiendo confirmación visual; continuando instalación en la distribución derivada..."
    return
  fi

  # INTERFAZ DE USUARIO: Cuadro de diálogo interactivo para validar la continuidad en entornos derivados
  if whiptail \
    --backtitle "Verificación de Compatibilidad" \
    --title "Distribución Alternativa Detectada" --yes-button "Continuar" --no-button "Salir" \
    --yesno "El asistente ha detectado que estás utilizando una distribución alternativa o derivada.

Nativamente, este instalador está optimizado para:
• Raspberry Pi OS
• Debian Linux
• Ubuntu Server

Al estar basado en una de estas distribuciones principales, el script suele ejecutarse y configurar la VPN de manera exitosa. Te sugerimos avanzar y supervisar el proceso.

Puedes reportar cualquier incidencia o tu experiencia de uso en:
https://github.com/wfhgdev/pivpn_spanish

¿Deseas continuar con la instalación en este sistema?" "${r}" "${c}"; then
    
    # TRAZABILIDAD: Registro de confirmación afirmativa del administrador
    echo "::: [INFO] Consentimiento otorgado. Continuando con el despliegue en distribución derivada..."
  else
    # ERROR CONTROLADO: Cierre limpio del script delegando el formateo a la función nativa err()
    err "Instalación abortada por el usuario al rechazar el entorno de distribución alternativa."
    exit 1
  fi
}

checkHostname() {
  # TRAZABILIDAD: Auditoría inicial del estado del parámetro de red de la máquina
  echo "::: [INFO] Verificando la conformidad del nombre de host (hostname)..."
  local host_name
  host_name="$(hostname -s)"

  # Validación de longitud o caracteres no admitidos en el estándar RFC 1123
  if [[ "${#host_name}" -gt 28 ]] || [[ ! "${host_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      err "El nombre de host actual ('${host_name}') no cumple los requisitos de red o excede los 28 caracteres."
      err "Por favor, soluciónalo ejecutando manualmente: sudo hostnamectl set-hostname NOMBRE"
      exit 1
    fi

    local proposed_host="${host_name}"
    local exit_status

    # BUCLE DE VALIDACIÓN INTERACTIVA: Garantiza un formato limpio antes de aplicarlo al sistema
    while [[ "${#proposed_host}" -gt 28 ]] || [[ ! "${proposed_host}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,27}$ ]]; do
      proposed_host="$(whiptail \
        --backtitle "Asistente de Configuración PiVPN" \
        --title "Ajuste del Nombre de Host" --ok-button "Guardar" cancel-button "Cancelar" \
        --inputbox "El nombre actual de este equipo (${host_name}) excede el límite permitido o contiene caracteres no válidos para configurar la VPN. Por favor, introduce uno nuevo:

Requisitos:
• Máximo 28 caracteres de longitud.
• Solo letras, números y guiones (sin espacios ni caracteres especiales)." "${r}" "${c}" \
        3>&1 1>&2 2>&3)"
      
      exit_status=$?

      # SEGURIDAD: Si el usuario cancela el diálogo, salimos limpiamente en lugar de romper el hostname
      if [[ ${exit_status} -ne 0 ]]; then
        echo ":::"
        err "Instalación abortada por el usuario durante la reconfiguración del nombre de host."
        exit 1
      fi

      # Limpieza básica: Eliminar espacios en blanco accidentales que introduzca el usuario
      proposed_host="${proposed_host// /}"
    done

    # APLICACIÓN DE CAMBIOS: Persistencia del nuevo parámetro en el sistema operativo
    echo "::: [INFO] Aplicando el nuevo nombre de host validado: '${proposed_host}'..."
    if ${SUDO} hostnamectl set-hostname "${proposed_host}"; then
      echo "::: [INFO] Nombre de host actualizado con éxito a '${proposed_host}'."
    else
      err "Error crítico al intentar actualizar el nombre de host mediante 'hostnamectl'."
      exit 1
    fi
  else
    echo "::: [INFO] Nombre de host verificado correctamente ('${host_name}')."
  fi
}

spinner() {
  # ÁMBITO SEGURO: Aislamiento estricto de variables del indicador de carga
  local pid="${1}"
  local delay=0.50
  local spinstr='/-\|'
  local temp

  # OPTIMIZACIÓN: Uso de 'kill -0' en sustitución de la tubería pesada 'ps | awk | grep'.
  # Valida de forma nativa la existencia del PID sin bifurcar procesos (forks) en alta frecuencia.
  while kill -0 "${pid}" 2>/dev/null; do
    temp="${spinstr#?}"
    printf " [%c]  " "${spinstr}"
    spinstr="${temp}${spinstr%"${temp}"}"
    sleep "${delay}"
    printf "\b\b\b\b\b\b"
  done

  # LIMPIEZA: Remoción estética de los caracteres residuales del indicador en la consola
  printf "    \b\b\b\b"
}

verifyFreeDiskSpace() {
  # TRAZABILIDAD: Registro inicial para auditar el estado físico del almacenamiento del sistema
  echo "::: [INFO] Verificando el espacio libre en disco en el directorio raíz..."
  local required_free_kilobytes=76800
  local existing_free_kilobytes
  
  # OPTIMIZACIÓN: Se consulta directamente el volumen raíz '/' con 'df -P' para evitar 
  # la concatenación ineficiente y propensa a fallos de 'df | grep | awk'.
  existing_free_kilobytes="$(df -P / 2>/dev/null | awk 'NR==2 {print $4}')"

  # COMPROBACIÓN 1: El espacio libre en disco es desconocido o el formato no es un entero válido
  if [[ ! "${existing_free_kilobytes}" =~ ^[0-9]+$ ]]; then
    echo "::: [ADVERTENCIA] No se pudo determinar con precisión el espacio libre disponible en el almacenamiento."

    if [[ "${runUnattended}" == 'true' ]]; then
      err "Espacio libre en disco indeterminado. Abortando instalación automática en modo desatendido por seguridad."
      exit 1
    fi

    echo "::: [ADVERTENCIA] Continuar sin verificar el espacio libre puede corromper paquetes o interrumpir el despliegue."
    echo "::: Si estás seguro de que el sistema cuenta con almacenamiento libre suficiente, escribe 'YES'."
    echo -n "::: ¿Deseas forzar la continuidad de la instalación? (YES/no): "
    read -r response

    case "${response}" in
      [Yy][Ee][Ss])
        echo "::: [ADVERTENCIA] Omisión de validación de almacenamiento forzada por el administrador."
        ;;
      *)
        err "Confirmación explícita no recibida. Abortando el instalador por razones de seguridad."
        exit 1
        ;;
    esac

  # COMPROBACIÓN 2: El espacio libre disponible es inferior al umbral mínimo de contingencia (75 MB)
  elif [[ "${existing_free_kilobytes}" -lt "${required_free_kilobytes}" ]]; then
    # Conversión matemática interna nativa para enriquecer el output de diagnóstico en consola
    local req_mb=$((required_free_kilobytes / 1024))
    local ext_mb=$((existing_free_kilobytes / 1024))

    err "Espacio en disco insuficiente para garantizar una instalación estable."
    echo "::: [DETALLES] Umbral mínimo requerido: ${required_free_kilobytes} KB (~${req_mb} MB)"
    echo "::: [DETALLES] Almacenamiento disponible: ${existing_free_kilobytes} KB (~${ext_mb} MB)"
    echo "::: [AYUDA] Si estás utilizando un entorno nuevo sobre Raspberry Pi OS, expande tu partición:"
    echo ":::         Ejecuta 'sudo raspi-config' -> 'Advanced Options' -> 'Expand Filesystem'"
    echo ":::         Reinicia el dispositivo y vuelve a lanzar este asistente de instalación."
    exit 1
  fi

  # TRAZABILIDAD: Verificación exitosa del componente de almacenamiento antes de proceder a la descarga
  echo "::: [INFO] Espacio libre en disco verificado con éxito. Capacidad suficiente garantizada."
}

updatePackageCache() {
  # TRAZABILIDAD: Registro inicial homogeneizado con el sistema de trazas global
  echo "::: [INFO] Sincronizando e indexando la caché de repositorios locales..."
  
  local cache_pid
  
  # ROBUSTEZ: Detección dinámica del tipo de variable (Arreglo vs. Cadena)
  # Previene que en Debian/Ubuntu solo se ejecute el primer elemento de la matriz (apt-get)
  if [[ "$(declare -p UPDATE_PKG_CACHE 2>/dev/null)" =~ "declare -a" ]]; then
    # shellcheck disable=SC2086
    ${SUDO} "${UPDATE_PKG_CACHE[@]}" > /dev/null 2>&1 &
  else
    # shellcheck disable=SC2086
    ${SUDO} ${UPDATE_PKG_CACHE} > /dev/null 2>&1 &
  fi
  cache_pid=$!
  
  # Delegación del control visual al indicador de carga síncrono
  spinner "${cache_pid}"
  
  # ROBUSTEZ: Captura y evaluación del código de estado real del proceso en segundo plano
  wait "${cache_pid}"
  if [[ $? -eq 0 ]]; then
    echo "::: [ÉXITO] Caché de paquetes locales actualizada correctamente."
  else
    # No interrumpimos el flujo crítico, pero dejamos constancia clara del incidente en consola y logs
    echo "::: [ADVERTENCIA] No se pudo actualizar la caché de repositorios de forma óptima."
    echo ":::               El asistente continuará intentando resolver las dependencias de todos modos."
  fi
}

notifyPackageUpdatesAvailable() {
  # TRAZABILIDAD: Auditoría visual estructurada del estado de actualización del sistema operativo anfitrión
  echo "::: [INFO] Consultando la disponibilidad de actualizaciones de software pendientes..."
  
  local updatesToInstall
  # Redirección segura de stderr para evitar rupturas visuales si el gestor está bloqueado temporalmente
  updatesToInstall="$(eval "${PKG_COUNT}" 2>/dev/null)"
  
  # SANITIZACIÓN: Validar mediante expresión regular si la salida es un entero matemático puro
  if [[ ! "${updatesToInstall}" =~ ^[0-9]+$ ]]; then
    echo "::: [ADVERTENCIA] No se pudo determinar con precisión el volumen de actualizaciones pendientes."
    return
  fi

  # EVALUACIÓN DE ENTORNO: Enrutamiento de mensajes formateados según la densidad de parches requeridos
  if [[ "${updatesToInstall}" -eq 0 ]]; then
    echo "::: [INFO] El sistema operativo base se encuentra totalmente al día. Continuando..."
  else
    echo "::: [ADVERTENCIA] Se han detectado ${updatesToInstall} actualizaciones de paquetes disponibles en este sistema."
    echo "::: [RECOMENDACIÓN] Para preservar la seguridad y estabilidad de la red, se aconseja encarecidamente"
    echo ":::                 aplicar los parches pendientes del sistema operativo una vez concluido este despliegue."
  fi
}

preconfigurePackages() {
  # TRAZABILIDAD: Registro de inicio unificado para la fase de preconfiguración
  echo "::: [INFO] Iniciando la validación del entorno de empaquetado y dependencias..."
  
  local INSTALLED_APT DPKG_ARCH AVAILABLE_OPENVPN AVAILABLE_WIREGUARD down_dir

  # COMPROBACIÓN: Soporte HTTPS para gestores de paquetes antiguos (Apt < 1.5)
  if [[ "${PKG_MANAGER}" == 'apt-get' ]] && [[ -f /etc/apt/sources.list ]]; then
    # Inmunidad a localización: extrae la versión directamente de la base de datos de dpkg
    INSTALLED_APT="$(dpkg-query -W -f='${Version}' apt 2>/dev/null)"

    if [[ -n "${INSTALLED_APT}" ]] && dpkg --compare-versions "${INSTALLED_APT}" lt 1.5; then
      echo "::: [INFO] Versión de apt antigua detectada. Añadiendo soporte para repositorios HTTPS..."
      BASE_DEPS+=("apt-transport-https")
    fi
  fi

  # CONFIGURACIÓN: Evaluación de soporte de asignación de direccionamiento estático
  if checkStaticIpSupported; then
    echo "::: [INFO] Validando la suite de gestión de redes del sistema anfitrión..."
    if [[ "${OSCN}" == "bullseye" ]]; then
      BASE_DEPS+=(dhcpcd5)
    else
      useNetworkManager=true
    fi
  fi

  # ARQUITECTURA: Identificación de la firma de compilación binaria del sistema
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    DPKG_ARCH="$(dpkg --print-architecture)"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    DPKG_ARCH="$(apk --print-arch)"
  fi

  # DETECCIÓN OPENVPN: Consulta optimizada de candidatos de instalación en repositorios
  echo "::: [INFO] Comprobando disponibilidad de paquetes oficiales para OpenVPN..."
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    AVAILABLE_OPENVPN="$(apt-cache policy openvpn 2>/dev/null | awk '/Candidate:/ && !/\(none\)/ {print $2}')"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    AVAILABLE_OPENVPN="$(apk search -e openvpn 2>/dev/null | sed -E -e 's/openvpn\-(.*)/\1/')"
  fi

  OPENVPN_SUPPORT=0
  NEED_OPENVPN_REPO=0

  # LÓGICA DE COMPATIBILIDAD: Requerimiento mínimo de OpenVPN 2.5 (Soporte ECC / tls-crypt-v2)
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    if [[ -n "${AVAILABLE_OPENVPN}" ]] && dpkg --compare-versions "${AVAILABLE_OPENVPN}" ge 2.5; then
      OPENVPN_SUPPORT=1
    else
      # Inyección de repositorio oficial de OpenVPN para arquitecturas x86 compatibles
      if [[ "${PLAT}" == "Debian" ]] || [[ "${PLAT}" == "Ubuntu" ]]; then
        if [[ "${DPKG_ARCH}" == "amd64" ]] || [[ "${DPKG_ARCH}" == "i386" ]]; then
          echo "::: [INFO] Habilitando repositorio externo oficial de OpenVPN para obtener rama 2.5+..."
          NEED_OPENVPN_REPO=1
          OPENVPN_SUPPORT=1
        fi
      fi
    fi
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    if [[ -n "${AVAILABLE_OPENVPN}" ]] && [[ "$(apk version -t "${AVAILABLE_OPENVPN}" 2.5)" == '>' ]]; then
      OPENVPN_SUPPORT=1
    fi
  fi

  # DETECCIÓN WIREGUARD: Consulta de candidatos disponibles en los repositorios locales
  echo "::: [INFO] Comprobando disponibilidad de paquetes oficiales para WireGuard..."
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    AVAILABLE_WIREGUARD="$(apt-cache policy wireguard 2>/dev/null | awk '/Candidate:/ && !/\(none\)/ {print $2}')"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    AVAILABLE_WIREGUARD="$(apk search -e wireguard-tools 2>/dev/null | sed -E -e 's/wireguard\-tools\-(.*)/\1/')"
  fi

  WIREGUARD_SUPPORT=0
  WIREGUARD_BUILTIN=0

  # NÚCLEO: Verificación de la presencia del módulo de WireGuard integrado en el kernel (LXC/Anfitrión)
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    if dpkg-query -S '/lib/modules/*/wireguard.ko*' &> /dev/null \
      || dpkg-query -S '/usr/lib/modules/*/wireguard.ko*' &> /dev/null \
      || modinfo wireguard 2> /dev/null | grep -q '^filename:[[:blank:]]*(builtin)$' \
      || lsmod | grep -q '^wireguard'; then
      WIREGUARD_BUILTIN=1
      echo "::: [INFO] Módulo WireGuard integrado o cargado en el kernel detectado."
    fi
  fi

  # EVALUACIÓN MATRIZ WIREGUARD: Validación extendida multi-distribución (Incluye soporte arm64 moderno)
  if [[ "${WIREGUARD_BUILTIN}" -eq 1 && -n "${AVAILABLE_WIREGUARD}" ]] \
    || [[ "${WIREGUARD_BUILTIN}" -eq 1 && ("${PLAT}" == 'Debian' || "${PLAT}" == 'Raspbian' || "${PLAT}" == 'Raspberry') ]] \
    || [[ "${PLAT}" == 'Raspbian' || "${PLAT}" == 'Raspberry' ]] \
    || [[ "${PLAT}" == 'Alpine' && ! -f /.dockerenv && "$(uname -mrs)" =~ ^Linux\ +[0-9\.\-]+\-((lts)|(virt))\ +.*$ ]] \
    || [[ "${PLAT}" == 'Alpine' && -f /.dockerenv ]] \
    || [[ "${PLAT}" == 'Alpine' && -n "${AVAILABLE_WIREGUARD}" ]] \
    || [[ "${PLAT}" == 'Debian' && "${DPKG_ARCH}" == 'amd64' ]] \
    || [[ "${PLAT}" == 'Ubuntu' && "${DPKG_ARCH}" == 'amd64' && -n "${AVAILABLE_WIREGUARD}" ]] \
    || [[ "${PLAT}" == 'Ubuntu' && "${DPKG_ARCH}" == 'arm64' && "${OSCN}" == 'focal' && -n "${AVAILABLE_WIREGUARD}" ]]; then
    WIREGUARD_SUPPORT=1
  fi

  # SEGURIDAD CRÍTICA: Abortar si ningún motor VPN es viable en este entorno operativo
  if [[ "${OPENVPN_SUPPORT}" -eq 0 ]] && [[ "${WIREGUARD_SUPPORT}" -eq 0 ]]; then
    err "Ni OpenVPN ni WireGuard se encuentran disponibles para su instalación en este sistema."
    exit 1
  fi

  # CORTAFUEGOS: Evaluación de persistencia e integración con el framework UFW
  echo "::: [INFO] Evaluando la presencia y el estado del cortafuegos (UFW)..."
  if ${SUDO} bash -c 'command -v ufw' > /dev/null; then
    if ! ${SUDO} ufw status || ${SUDO} ufw status | grep -q inactive; then
      USING_UFW=0
    else
      USING_UFW=1
      echo "::: [INFO] FireWall UFW activo detectado. La configuración de reglas se adaptará de forma automática."
    fi
  else
    USING_UFW=0
  fi

  # DEBCONF: Automatización desatendida para confirmaciones del paquete iptables-persistent
  if [[ "${PKG_MANAGER}" == 'apt-get' ]] && [[ "${USING_UFW}" -eq 0 ]]; then
    echo "::: [INFO] Inyectando directivas de automatización desatendida para iptables-persistent..."
    BASE_DEPS+=(iptables-persistent)
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | ${SUDO} debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | ${SUDO} debconf-set-selections
  fi

  # COMPILACIÓN ESPECÍFICA (Alpine Linux): Despliegue e instalación manual de grepcidr
  if [[ "${PLAT}" == 'Alpine' ]] && ! command -v grepcidr &> /dev/null; then
    echo "::: [INFO] Compilando grepcidr desde el origen para compatibilidad con el entorno Alpine..."
    
    # shellcheck disable=SC2086
    ${SUDO} ${PKG_INSTALL} build-base make curl tar

    if ! down_dir="$(mktemp -d)"; then
      err "Fallo crítico al inicializar el directorio temporal de compilación para grepcidr."
      exit 1
    fi

    # Descarga e infraestructura de construcción en subproceso aislado
    if curl -fLo "${down_dir}/master.tar.gz" "https://github.com/pivpn/grepcidr/archive/master.tar.gz"; then
      tar -xzC "${down_dir}" -f "${down_dir}/master.tar.gz"
      (
        cd "${down_dir}/grepcidr-master" || exit 1
        
        # Ajuste de rutas estándar en el Makefile de compilación
        sed -i -E -e 's/^PREFIX\=.*/PREFIX\=\/usr\nCC\=gcc/' Makefile
        
        make && ${SUDO} make install

        if ! command -v grepcidr &> /dev/null; then
          err "El proceso de compilación nativa finalizó pero 'grepcidr' no responde en el PATH."
          exit 1
        fi
      ) || exit 1
    else
      err "Fallo al descargar el archivo de código fuente comprimido de grepcidr."
      exit 1
    fi
  fi

  # PERSISTENCIA: Almacenamiento del estado del cortafuegos en variables temporales de instalación
  echo "USING_UFW=${USING_UFW}" >> "${tempsetupVarsFile}"
  echo "::: [ÉXITO] Análisis del entorno y preconfiguración de paquetes completada."
}

installDependentPackages() {
  # ==============================================================================
  #       INSTALACIÓN CONTROLADA DE DEPENDENCIAS DEL SISTEMA (SIN SPINNER)
  # ==============================================================================
  # Nota técnica: Se prescinde del indicador de carga (spinner) en este bloque debido
  # a conflictos de concurrencia y flujo con la directiva estricta 'set -e'.
  
  local FAILED=0
  local APTLOGFILE
  local is_installed
  local i
  declare -a TO_INSTALL=()
  declare -a argArray1=("${!1}")

  echo ":::"
  echo "::: [INFO] Iniciando el análisis y validación de las dependencias requeridas..."

  # ------------------------------------------------------------------------------
  # FASE 1: EVALUACIÓN DE PAQUETES PREEXISTENTES
  # ------------------------------------------------------------------------------
  for i in "${argArray1[@]}"; do
    is_installed=false

    if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
      if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null | grep -q "ok installed"; then
        is_installed=true
      fi
    elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
      if eval "${SUDO} ${CHECK_PKG_INSTALLED} ${i}" &> /dev/null; then
        is_installed=true
      fi
    fi

    if ${is_installed}; then
      echo "::: [INFO] Dependencia: ${i} -> [✓ DETECTADA] (Ya se encuentra instalada)."
    else
      echo "::: [INFO] Dependencia: ${i} -> [✗ NO DETECTADA] (Marcada para instalación)."
      TO_INSTALL+=("${i}")
    fi
  done

  # Cláusula de guarda: Si todas las dependencias están resueltas, finalizar limpiamente
  if [[ "${#TO_INSTALL[@]}" -eq 0 ]]; then
    echo "::: [ÉXITO] Todas las dependencias ya están totalmente satisfechas. No se requieren cambios."
    return 0
  fi

  # ------------------------------------------------------------------------------
  # FASE 2: PROCESO DE INSTALACIÓN Y CAPTURA DE LOGS
  # ------------------------------------------------------------------------------
  echo ":::"
  echo "::: [INFO] Procediendo a instalar las dependencias faltantes: ${TO_INSTALL[*]}"
  
  # Creación segura del archivo temporal para el registro de trazas
  APTLOGFILE="$(${SUDO} mktemp)"
  
  # SOLUCIÓN DE BUG CRÍTICO: Se separa la ejecución por gestor de paquetes. 
  # Para 'apt-get', PKG_INSTALL es un arreglo nativo y expandirlo como cadena simple 
  # omitía los parámetros esenciales (--yes --no-install-recommends install).
  # Además, se redirige el flujo (stdout/stderr) para que el archivo de log no quede vacío.
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    ${SUDO} "${PKG_INSTALL[@]}" "${TO_INSTALL[@]}" > "${APTLOGFILE}" 2>&1
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    # shellcheck disable=SC2086
    ${SUDO} ${PKG_INSTALL} "${TO_INSTALL[@]}" > "${APTLOGFILE}" 2>&1
  fi

  # ------------------------------------------------------------------------------
  # FASE 3: VERIFICACIÓN POST-INSTALACIÓN Y AUDITORÍA
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Verificando el resultado de las operaciones..."
  for i in "${TO_INSTALL[@]}"; do
    is_installed=false

    if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
      if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null | grep -q "ok installed"; then
        is_installed=true
      fi
    elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
      if eval "${SUDO} ${CHECK_PKG_INSTALLED} ${i}" &> /dev/null; then
        is_installed=true
      fi
    fi

    if ${is_installed}; then
      echo "::: [ÉXITO] -> El paquete '${i}' se ha instalado correctamente."
      # Registro dinámico en la lista global para evitar purgar utilidades del usuario al desinstalar
      INSTALLED_PACKAGES+=("${i}")
    else
      echo "::: [ERROR] -> ¡Fallo crítico al intentar instalar el paquete '${i}'!" >&2
      ((FAILED++))
    fi
  done

  # ------------------------------------------------------------------------------
  # FASE 4: CONTROL DE ERRORES Y LIMPIEZA DE RESIDUOS (GARBAGE COLLECTION)
  # ------------------------------------------------------------------------------
  if [[ "${FAILED}" -gt 0 ]]; then
    echo ":::" >&2
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [ERROR CRÍTICO]: Falló la instalación de dependencias del sistema." >&2
    echo "::: [DETALLE DEL LOG DEL GESTOR DE PAQUETES]:" >&2
    ${SUDO} cat "${APTLOGFILE}" >&2
    
    # Saneamiento preventivo de archivos temporales propiedad de root antes de abortar
    ${SUDO} rm -f "${APTLOGFILE}"
    exit 1
  fi

  # Saneamiento del entorno en caso de éxito
  ${SUDO} rm -f "${APTLOGFILE}"
  echo "::: [ÉXITO] Despliegue y validación de dependencias finalizado sin incidencias."
}

welcomeDialogs() {
  # ------------------------------------------------------------------------------
  # CASO 1: ENTRADA EN MODO DESATENDIDO / AUTOMATIZADO
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido activo. Iniciando el instalador automatizado de PiVPN..."
    echo "::: [INFO] Transformando el entorno local '${PLAT}' en un servidor VPN seguro..."
    echo "::: [INFO] Inicializando la evaluación de interfaces de red..."
    return
  fi

  # ------------------------------------------------------------------------------
  # CASO 2: ENTRADA EN MODO INTERACTIVO (INTERFAZ WHIPTAIL)
  # ------------------------------------------------------------------------------
  # TRAZABILIDAD: Registro de auditoría previo al lanzamiento de la interfaz gráfica
  echo "::: [INFO] Abriendo el cuadro de diálogo de bienvenida en la terminal..."

  # DIÁLOGO: Presentación formal del asistente interactivo traducido al español
  whiptail \
    --backtitle "Asistente de Instalación PiVPN" \
    --title "Bienvenido a PiVPN en Español" --ok-button "Comenzar" \
    --msgbox "Este asistente interactivo simplificará la instalación y gestión de tu servidor VPN (WireGuard o OpenVPN).

PiVPN automatiza las configuraciones complejas de red y seguridad, permitiéndote desplegar un servidor seguro en cuestión de minutos, ideal tanto para Raspberry Pi como para servidores locales o virtuales basados en Debian y Ubuntu." "${r}" "${c}"

  # TRAZABILIDAD: Confirmación de paso a la sección de requisitos de red
  echo "::: [INFO] El usuario ha iniciado el asistente interactivo. Evaluando prerrequisitos..."

  # DIÁLOGO: Explicación de la importancia de la persistencia de direccionamiento IP
  whiptail \
    --backtitle "Configuración de Red Local" \
    --title "Requisito: Dirección IP Fija (Estática)" --ok-button "Aceptar" \
    --msgbox "Para que tus dispositivos puedan conectarse de forma remota, este servidor necesita una dirección IP local fija que no cambie con el tiempo.

A continuación, evaluaremos tu conexión de red actual. Podrás elegir mantener los parámetros que ya tienes asignados por DHCP o editarlos manualmente si lo consideras necesario." "${r}" "${c}"

  # TRAZABILIDAD: Confirmación final para dar paso al análisis de adaptadores físicos
  echo "::: [INFO] Explicación de IP estática aceptada por el usuario. Pasando al módulo de red."
}


chooseInterface() {
  # ==============================================================================
  #       DETECCIÓN Y ASIGNACIÓN DE INTERFACES DE RED (IPv4 / IPv6)
  # ==============================================================================
  
  local interfacesArray=()
  local interfaceCount=0
  local chooseInterfaceCmd
  local chooseInterfaceOptions
  local firstloop=1
  local availableInterfaces
  local line
  local mode
  local desiredInterface

  echo "::: [INFO] Iniciando el análisis de los adaptadores de red instalados..."

  # OPTIMIZACIÓN: Se unifica la extracción, filtrado y formateo usando un único 
  # proceso 'awk'. Esto elimina la sobrecarga de múltiples forks de 'cut' y 'grep'.
  if [[ "${showUnsupportedNICs}" == 'true' ]]; then
    # Evalúa todas las interfaces del sistema excepto bucles locales y docker
    availableInterfaces="$(ip -o link | awk '{ sub(/:$/, "", $2); split($2, a, "@"); if (a[1] != "lo" && a[1] !~ /^docker/) print a[1] }')"
  else
    # Filtra únicamente los adaptadores cuyo estado operativo actual sea 'UP'
    availableInterfaces="$(ip -o link | awk '/state UP/ { sub(/:$/, "", $2); split($2, a, "@"); if (a[1] != "lo" && a[1] !~ /^docker/) print a[1] }')"
  fi

  # VALIDACIÓN: Detener el proceso si no se localiza infraestructura de red apta
  if [[ -z "${availableInterfaces}" ]]; then
    err "No se detectó ninguna interfaz de red activa o compatible en este entorno."
    exit 1
  fi

  # Construcción del vector de opciones estructurado para la interfaz de Whiptail
  while read -r line; do
    [[ -z "${line}" ]] && continue
    mode="OFF"

    if [[ "${firstloop}" -eq 1 ]]; then
      firstloop=0
      mode="ON"  # Preselecciona la primera interfaz de la lista de forma activa
    fi

    interfacesArray+=("${line}" "Disponible" "${mode}")
    ((interfaceCount++))
  done <<< "${availableInterfaces}"

  # ------------------------------------------------------------------------------
  # FLUJO A: GESTIÓN EN MODO DESATENDIDO / AUTOMATIZADO
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido detectado. Procesando reglas de auto-asignación..."

    # Evaluación y validación del adaptador para IPv4
    if [[ -z "${IPv4dev}" ]]; then
      if [[ "${interfaceCount}" -eq 1 ]]; then
        IPv4dev="${availableInterfaces}"
        echo "::: [INFO] Interfaz IPv4 omitida en la configuración. Asignando la única disponible: ${IPv4dev}"
      else
        err "No se especificó la interfaz IPv4 y existen múltiples adaptadores en el sistema."
        exit 1
      fi
    else
      if ip -o link | grep -qw "${IPv4dev}"; then
        echo "::: [INFO] Interfaz IPv4 validada correctamente: ${IPv4dev}"
      else
        err "La interfaz IPv4 preconfigurada (${IPv4dev}) no existe o no está disponible."
        exit 1
      fi
    fi

    # Evaluación y validación del adaptador para IPv6 (Si está habilitado)
    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      if [[ -z "${IPv6dev}" ]]; then
        if [[ "${interfaceCount}" -eq 1 ]]; then
          IPv6dev="${availableInterfaces}"
          echo "::: [INFO] Interfaz IPv6 omitida en la configuración. Asignando la única disponible: ${IPv6dev}"
        else
          err "No se especificó la interfaz IPv6 y existen múltiples adaptadores en el sistema."
          exit 1
        fi
      else
        if ip -o link | grep -qw "${IPv6dev}"; then
          echo "::: [INFO] Interfaz IPv6 validada correctamente: ${IPv6dev}"
        else
          err "La interfaz IPv6 preconfigurada (${IPv6dev}) no existe o no está disponible."
          exit 1
        fi
      fi
    fi

    # Persistencia de variables en el entorno temporal de instalación
    {
      echo "IPv4dev=${IPv4dev}"
      if [[ "${pivpnenableipv6}" -eq 1 ]] && [[ -n "${IPv6dev}" ]]; then
        echo "IPv6dev=${IPv6dev}"
      fi
    } >> "${tempsetupVarsFile}"

    echo "::: [ÉXITO] Mapeo automático de adaptadores completado."
    return
  fi

  # ------------------------------------------------------------------------------
  # FLUJO B: CLÁUSULA DE INTERFAZ ÚNICA (AHORRO DE DIÁLOGOS INTERACTIVOS)
  # ------------------------------------------------------------------------------
  if [[ "${interfaceCount}" -eq 1 ]]; then
    IPv4dev="${availableInterfaces}"
    echo "::: [INFO] Solo se localizó un adaptador activo (${IPv4dev}). Omitiendo selección manual."

    {
      echo "IPv4dev=${IPv4dev}"
      if [[ "${pivpnenableipv6}" -eq 1 ]]; then
        IPv6dev="${availableInterfaces}"
        echo "IPv6dev=${IPv6dev}"
      fi
    } >> "${tempsetupVarsFile}"
    return
  fi

  # ------------------------------------------------------------------------------
  # FLUJO C: ASISTENTE INTERACTIVO (SELECCIÓN MULTI-INTERFAZ)
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Abriendo el cuadro de diálogo para la selección manual de interfaces..."

  # INTERFAZ INTERACTIVA: Selección del dispositivo de red para IPv4
  chooseInterfaceCmd=(whiptail
    --separate-output
    --backtitle "Configuración de Interfaces de Red"
    --title "Selección de Interfaz IPv4"
    --ok-button "Aceptar"
    --cancel-button "Cancelar"
    --radiolist "Por favor, elija el adaptador de red principal que utilizará el servidor para el tráfico IPv4\n(Presione ESPACIO para marcar su opción y ENTER para continuar):" 
    "${r}" "${c}" "${interfaceCount}")

  if chooseInterfaceOptions="$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 > /dev/tty)"; then
    for desiredInterface in ${chooseInterfaceOptions}; do
      IPv4dev="${desiredInterface}"
      echo "::: [INFO] Interfaz IPv4 seleccionada por el usuario: ${IPv4dev}"
      echo "IPv4dev=${IPv4dev}" >> "${tempsetupVarsFile}"
    done
  else
    err "El usuario canceló la selección de la interfaz de red. Cancelando la instalación."
    exit 1
  fi

  # INTERFAZ INTERACTIVA: Selección opcional del dispositivo de red para IPv6
  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    chooseInterfaceCmd=(whiptail
      --separate-output
      --backtitle "Configuración de Interfaces de Red"
      --title "Selección de Interfaz IPv6"
      --ok-button "Aceptar"
      --cancel-button "Cancelar"
      --radiolist "Elija el adaptador de red para el tráfico IPv6\n(Por norma general, se recomienda seleccionar el mismo dispositivo usado para IPv4):" 
      "${r}" "${c}" "${interfaceCount}")

    if chooseInterfaceOptions="$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 > /dev/tty)"; then
      for desiredInterface in ${chooseInterfaceOptions}; do
        IPv6dev="${desiredInterface}"
        echo "::: [INFO] Interfaz IPv6 seleccionada por el usuario: ${IPv6dev}"
        echo "IPv6dev=${IPv6dev}" >> "${tempsetupVarsFile}"
      done
    else
      err "El usuario canceló la asignación de interfaz para IPv6. Cancelando la instalación."
      exit 1
    fi
  fi

  echo "::: [ÉXITO] Enrutamiento de adaptadores configurado y guardado correctamente."
}

checkStaticIpSupported() {
  # ==============================================================================
  #     VERIFICACIÓN DE COMPATIBILIDAD DE CONFIGURACIÓN AUTOMÁTICA DE IP
  # ==============================================================================
  # Evalúa si el sistema operativo anfitrión cuenta con soporte nativo automatizado
  # dentro del script para modificar directamente los archivos locales de red.

  echo "::: [INFO] Evaluando compatibilidad de red para el entorno de la plataforma: '${PLAT}'..."

  if [[ "${PLAT}" == "Raspbian" || "${PLAT}" == "Raspberry" ]]; then
    echo "::: [INFO] Entorno Raspberry Pi OS compatible detectado de forma directa."
    return 0
  elif [[ "${PLAT}" == "Debian" ]] \
    && [[ -s /etc/apt/sources.list.d/raspi.list || -s /etc/apt/sources.list.d/raspi.sources ]]; then
    echo "::: [INFO] Sistema operativo Debian con repositorios de entorno Raspberry detectado."
    return 0
  else
    echo "::: [AVISO] La plataforma actual '${PLAT}' no admite asignación automatizada de IP estática local."
    return 1
  fi
}

staticIpNotSupported() {
  # ==============================================================================
  #     MANEJO DE EXCEPCIÓN: ENTIDAD DE RED NO COMPATIBLE LOCALMENTE
  # ==============================================================================
  
  # Gestión de salida limpia en caso de ejecuciones automatizadas de fondo
  if [[ "${AUTOMATED_INSTALL}" -eq 1 || "${runUnattended}" == 'true' ]]; then
    echo "::: [AVISO] El instalador omitirá la gestión automática de direccionamiento de red."
    echo "::: [AVISO] Razón: El sistema operativo anfitrión requiere aprovisionamiento externo de IP."
    return
  fi

  # TRAZABILIDAD: Despliegue de advertencia interactiva
  echo "::: [INFO] Lanzando advertencia en pantalla sobre la gestión independiente de IP estática..."

  # DIÁLOGO INTERACTIVO WHIPTAIL (Botones adaptados al español)
  whiptail \
    --backtitle "Asistente de Configuración de Red - PiVPN" \
    --title "Aviso Importante: Dirección IP Estática" \
    --ok-button "Entendido y Continuar" \
    --msgbox "Este instalador automático solo gestiona la asignación de archivos de IP estática de forma local en sistemas basados en Raspberry Pi OS.

Recomendaciones y buenas prácticas según tu entorno actual:
• Servidores en la Nube (AWS, Oracle Cloud, Proxmox remotos): Tu proveedor asigna y mapea la IP interna mediante su propia infraestructura de red. No alteres la configuración local.
• Servidores Locales (Ubuntu Server, Debian puro o Máquinas Virtuales): Te recomendamos encarecidamente fijar la IP de este equipo asignando una 'Reserva DHCP' vinculada a la MAC en la consola de tu router o gateway de red.

Si decides forzar una IP fija directamente en este sistema operativo más adelante, recuerda editar adecuadamente Netplan (/etc/netplan/) o el archivo clásico /etc/network/interfaces antes de pasar este servidor a producción." "${r}" "${c}"

  echo "::: [INFO] Confirmación de aviso de red registrada por el usuario."
}

validIP() {
  # ==============================================================================
  #                      VALIDACIÓN ESTÁNDAR DE DIRECCIÓN IPv4
  # ==============================================================================
  # Optimización: Se utiliza BASH_REMATCH para capturar los octetos directamente.
  # Esto elimina la manipulación de la variable interna IFS y acelera la comprobación.
  
  local ip_str="${1}"
  local -a octets

  # Expresión regular estricta para formato de 4 octetos delimitados por puntos
  if [[ "${ip_str}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    # Extraer los bloques capturados por la expresión regular
    octets=("${BASH_REMATCH[@]:1:4}")

    # Evaluación aritmética de rangos válidos de red (0 a 255 por octeto)
    if (( octets[0] <= 255 && octets[1] <= 255 && octets[2] <= 255 && octets[3] <= 255 )); then
      return 0
    fi
  fi

  return 1
}

validIPAndNetmask() {
  # ==============================================================================
  #               VALIDACIÓN DE DIRECCIÓN IPv4 BAJO NOTACIÓN CIDR
  # ==============================================================================
  # Solución de Bugs de Diseño: Se segmentan las variables en tipos string y array
  # independientes, resolviendo de forma limpia las alertas ShellCheck SC2178 y SC2128.

  local cidr_str="${1}"
  # Normalizar la cadena sustituyendo la barra oblicua '/' por un punto '.' para unificar la regex
  local normalized="${cidr_str/\//.}"
  local -a parts

  # Expresión regular para validar 4 octetos tradicionales + 1 prefijo de subred CIDR
  if [[ "${normalized}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,2})$ ]]; then
    parts=("${BASH_REMATCH[@]:1:5}")

    # Validación matemática: Octetos <= 255 y máscara de subred IPv4 <= 32 bits
    if (( parts[0] <= 255 && parts[1] <= 255 && parts[2] <= 255 && parts[3] <= 255 && parts[4] <= 32 )); then
      return 0
    fi
  fi

  return 1
}

checkipv6uplink() {
  # ==============================================================================
  #         COMPROBACIÓN DE ENLACE ASCENDENTE IPv6 (UPLINK TEST)
  # ==============================================================================
  # Realiza una petición controlada para determinar si la red local cuenta con
  # conectividad IPv6 real hacia el exterior antes de habilitar su configuración.

  local curlv6testres

  echo "::: [INFO] Comprobando la conectividad de red externa para IPv6..."

  # Ejecución de sondeo IPv6 hacia un dominio de alta disponibilidad con tiempos límite estrictos
  curl \
    --max-time 3 \
    --connect-timeout 3 \
    --silent \
    -6 \
    https://google.com \
    > /dev/null 2>&1
  curlv6testres="$?"

  if [[ "${curlv6testres}" -ne 0 ]]; then
    echo "::: [AVISO] La prueba de enlace ascendente IPv6 ha fallado (Código de error curl: ${curlv6testres})."
    echo "::: [AVISO] Deshabilitando el soporte de direccionamiento IPv6 para este despliegue."
    pivpnenableipv6=0
  else
    echo "::: [ÉXITO] Conexión de prueba IPv6 realizada correctamente. El host cuenta con salida IPv6 activa."
    echo "::: [INFO] Habilitando el soporte de IPv6 en la configuración base del servidor."
    pivpnenableipv6=1
  fi
}

askforcedipv6route() {
  # ==============================================================================
  #         CONFIGURACIÓN DE ENRUTAMIENTO FORZADO IPv6 (PREVENCIÓN DE FUGAS)
  # ==============================================================================
  # Previene el "IPv6 Leak" en entornos donde el servidor carece de IPv6 pero los
  # clientes operan en redes dual-stack (móviles/hogar) que sí lo utilizan.

  # ------------------------------------------------------------------------------
  # CASO 1: ENTRADA EN MODO DESATENDIDO / AUTOMATIZADO
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido activo. Aplicando directiva de enrutamiento IPv6 forzado..."
    echo "::: [INFO] Estado de ruta IPv6 forzada asignado (pivpnforceipv6route): ${pivpnforceipv6route}"
    echo "pivpnforceipv6route=${pivpnforceipv6route}" >> "${tempsetupVarsFile}"
    return
  fi

  # ------------------------------------------------------------------------------
  # CASO 2: ASISTENTE INTERACTIVO (INTERFAZ WHIPTAIL)
  # ------------------------------------------------------------------------------
  # TRAZABILIDAD: Registro de auditoría previo al despliegue del cuadro de diálogo
  echo "::: [INFO] Abriendo cuadro de diálogo interactivo: Mitigación de fugas IPv6..."

  if whiptail \
    --backtitle "Configuración de Privacidad y Seguridad - PiVPN" \
    --title "Prevención de Fugas IPv6 (IPv6 Leak)" \
    --yes-button "Sí, activar protección" \
    --no-button "No, omitir protección" \
    --yesno "Este servidor no dispone de una conexión IPv6 activa hacia internet. Sin embargo, los dispositivos remotos que se conecten a tu VPN (móviles, portátiles) podrían estar navegando desde redes locales externas que sí utilicen IPv6 de forma nativa.\n\nSi dejas esta opción desactivada, el tráfico IPv6 de tus clientes podría 'fugarse' fuera del túnel cifrado y seguro de la VPN, exponiendo su IP pública real al navegar por ciertos sitios web.\n\nPara mitigar este riesgo, se recomienda forzar una ruta IPv6 ficticia dentro del túnel. Esto bloqueará eficazmente las fugas de datos y blindará la privacidad de la conexión, aunque en redes móviles muy específicas podría generar una leve latencia al resolver dominios.\n\n¿Deseas activar la protección para forzar el enrutamiento IPv6?" \
    "${r}" "${c}"; then
    
    pivpnforceipv6route=1
    echo "::: [INFO] El usuario ha activado la mitigación contra fugas de IPv6 (Ruta forzada activa)."
  else
    pivpnforceipv6route=0
    echo "::: [AVISO] El usuario ha decidido no forzar el enrutamiento IPv6. Riesgo de fuga potencial activo."
  fi

  # Persistencia del parámetro y cierre de trazabilidad del módulo
  echo "pivpnforceipv6route=${pivpnforceipv6route}" >> "${tempsetupVarsFile}"
  echo "::: [ÉXITO] Parámetro de enrutamiento IPv6 salvado en el archivo de variables temporales."
}

getStaticIPv4Settings() {
  # ==============================================================================
  #       RECOPILACIÓN Y CONFIGURACIÓN DE PARÁMETROS RED IPv4 ESTÁTICA
  # ==============================================================================
  
  echo "::: [INFO] Analizando la topología de red local y resolviendo pasarelas..."

  # OPTIMIZACIÓN: Extracción de la Puerta de Enlace (Gateway) activa de forma eficiente
  CurrentIPv4gw="$(ip route get 192.0.2.1 2>/dev/null | grep -oE 'via [0-9]{1,3}(\.[0-9]{1,3}){3}' | awk '{print $2}')"
  if [[ -z "${CurrentIPv4gw}" ]]; then
    # Fallback secundario si la ruta directa no expone el tag 'via'
    CurrentIPv4gw="$(ip route show default 2>/dev/null | awk '/default via/ {print $3; exit}')"
  fi

  # OPTIMIZACIÓN: Extracción de la Dirección IP actual con su máscara en formato CIDR
  CurrentIPv4addr="$(ip -o -f inet address show dev "${IPv4dev}" 2>/dev/null | awk '/inet / {print $4; exit}')"

  # OPTIMIZACIÓN: Extracción limpia de servidores DNS activos excluyendo comentarios
  IPv4dns="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | xargs)"

  # Registrar traza con los datos obtenidos en la fase de descubrimiento
  echo "::: [INFO] Datos DHCP descubiertos -> IP: ${CurrentIPv4addr} | GW: ${CurrentIPv4gw} | DNS: ${IPv4dns}"

  # ------------------------------------------------------------------------------
  # FLUJO A: GESTIÓN EN MODO DESATENDIDO / AUTOMATIZADO
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido activo. Validando variables de red preconfiguradas..."
    
    if [[ -z "${dhcpReserv}" ]] || [[ "${dhcpReserv}" -ne 1 ]]; then
      local MISSING_STATIC_IPV4_SETTINGS=0

      if [[ -z "${IPv4addr}" ]]; then
        echo "::: [AVISO] Configuración incompleta: Falta definir la dirección 'IPv4addr'"
        ((MISSING_STATIC_IPV4_SETTINGS++))
      fi

      if [[ -z "${IPv4gw}" ]]; then
        echo "::: [AVISO] Configuración incompleta: Falta definir la puerta de enlace 'IPv4gw'"
        ((MISSING_STATIC_IPV4_SETTINGS++))
      fi

      if [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 0 ]]; then
        # Ambas variables existen; procedemos a validar su integridad formal
        if validIPAndNetmask "${IPv4addr}"; then
          echo "::: [INFO] IPv4 estática configurada: ${IPv4addr}"
        else
          err "La dirección IPv4 desatendida (${IPv4addr}) no es válida o carece de máscara CIDR."
          exit 1
        fi

        if validIP "${IPv4gw}"; then
          echo "::: [INFO] Puerta de enlace configurada: ${IPv4gw}"
        else
          err "La puerta de enlace IPv4 desatendida (${IPv4gw}) no es una dirección IP válida."
          exit 1
        fi

      elif [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 1 ]]; then
        err "Inconsistencia en modo desatendido: Solo se proporcionó uno de los parámetros requeridos de IP/GW."
        exit 1

      elif [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 2 ]]; then
        # Si no se definieron parámetros, se heredan de forma segura los asignados por el DHCP actual
        IPv4addr="${CurrentIPv4addr}"
        IPv4gw="${CurrentIPv4gw}"
        echo "::: [INFO] Sin parámetros explícitos asignados. Adoptando configuración DHCP por defecto."
        echo "::: [INFO] IPv4 estática asignada: ${IPv4addr}"
        echo "::: [INFO] Puerta de enlace asignada: ${IPv4gw}"
      fi
    else
      echo "::: [INFO] Reserva DHCP activa declarada. Omitiendo reconfiguración local de IP estática."
    fi

    # Volcado y persistencia de variables en el archivo temporal de instalación
    {
      echo "dhcpReserv=${dhcpReserv}"
      echo "IPv4addr=${IPv4addr}"
      echo "IPv4gw=${IPv4gw}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  # ------------------------------------------------------------------------------
  # FLUJO B: ASISTENTE INTERACTIVO (GRAFICO - WHIPTAIL)
  # ------------------------------------------------------------------------------
  local ipSettingsCorrect=false
  local IPv4AddrValid=false
  local IPv4gwValid=false

  echo "::: [INFO] Lanzando consulta interactiva sobre el método de asignación de direccionamiento..."

  # INTERFAZ INTERACTIVA: Selección del Tipo de Direccionamiento (DHCP permanente vs Local)
  if whiptail \
    --backtitle "Asistente de Configuración de Red - PiVPN" \
    --title "Método de Asignación de IP" \
    --yes-button "Mantener DHCP (Recomendado)" \
    --no-button "Configurar Manualmente" \
    --defaultno \
    --yesno "Para garantizar la accesibilidad permanente a tu VPN, este servidor requiere una dirección IP fija.\n\nEl asistente ha detectado los siguientes parámetros activos en tu interfaz:\n  • Dirección IP:       ${CurrentIPv4addr}\n  • Puerta de enlace:   ${CurrentIPv4gw}\n\n¿Tienes esta IP ya configurada como una 'Reserva Estática' o 'Reserva DHCP' en tu enrutador?\n\n• Elige 'Mantener DHCP' si ya has vinculado la MAC de este equipo a una IP fija en tu router (Es la opción más limpia y segura).\n• Elige 'Configurar Manualmente' si prefieres forzar una IP fija de forma estática directamente en este sistema operativo." \
    "${r}" "${c}"; then
    
    # El usuario confirma que el Router se encarga de mantener la IP fija
    dhcpReserv=1
    echo "::: [INFO] El usuario optó por mantener DHCP (Se asume existencia de Reserva DHCP externa)."

    {
      echo "dhcpReserv=${dhcpReserv}"
      echo "IPv4addr=${CurrentIPv4addr}"
      echo "IPv4gw=${CurrentIPv4gw}"
    } >> "${tempsetupVarsFile}"
  else
    # El usuario desea forzar los archivos locales e independizarse del DHCP automático
    dhcpReserv=0
    echo "::: [INFO] El usuario ha optado por la reconfiguración manual / estática local."

    # INTERFAZ INTERACTIVA: Clonación de parámetros DHCP actuales como base estática
    if whiptail \
      --backtitle "Asistente de Configuración de Red - PiVPN" \
      --title "Confirmación de IP Estática" \
      --yes-button "Confirmar y Usar" \
      --no-button "Modificar Parámetros" \
      --yesno "Has elegido configurar una dirección IP estática local.\n\n¿Deseas clonar y fijar de forma definitiva los parámetros actuales del sistema o prefieres modificarlos manualmente?\n\n  • Dirección IP sugerida:   ${CurrentIPv4addr}\n  • Puerta de enlace:        ${CurrentIPv4gw}" \
      "${r}" "${c}"; then
      
      IPv4addr="${CurrentIPv4addr}"
      IPv4gw="${CurrentIPv4gw}"
      echo "::: [INFO] El usuario confirmó el uso de los parámetros de red actuales como IP fija local."

      {
        echo "IPv4addr=${IPv4addr}"
        echo "IPv4gw=${IPv4gw}"
      } >> "${tempsetupVarsFile}"

      # INTERFAZ INTERACTIVA: Alerta preventiva de riesgos por colisión / solapamiento de direccionamiento
      whiptail \
        --backtitle "Asistente de Configuración de Red - PiVPN" \
        --title "Aviso Crítico: Riesgo de Conflicto de IP" \
        --ok-button "Entendido y Mitigado" \
        --msgbox "¡Atención! Al fijar una dirección IP directamente de forma local sin avisar al router, existe la posibilidad de que el servidor DHCP de tu red asigne esta misma IP a otro dispositivo (móvil, TV, pc) en el futuro.\n\nEsto causaría un conflicto de red colapsando el acceso a tu servidor VPN.\n\nPara prevenirlo de forma permanente, asegúrate de cumplir una de estas medidas:\n1. Accede a tu router y crea una 'Reserva DHCP' para la dirección MAC de este servidor usando esta misma IP.\n2. Modifica el rango dinámico del DHCP de tu router para que tu IP estática quede excluida de las asignaciones automáticas." \
        "${r}" "${c}"
      
      echo "::: [INFO] Alerta de conflicto de direccionamiento IP leída y aceptada."
    else
      # ----------------------------------------------------------------------------
      # BUCLE DE ENTRADA MANUAL COMPLETA (IP -> GATEWAY -> VALIDACIÓN -> CONFIRMACIÓN)
      # ----------------------------------------------------------------------------
      echo "::: [INFO] Iniciando el bucle de captura manual de datos de red..."
      
      until [[ "${ipSettingsCorrect}" == 'true' ]]; do
        
        # Sub-bucle 1: Solicitar y validar Dirección IP + Máscara (Formato CIDR requerido)
        until [[ "${IPv4AddrValid}" == 'true' ]]; do
          if IPv4addr="$(whiptail \
            --backtitle "Configuración Manual de Red - PiVPN" \
            --title "Asignar Dirección IPv4 (CIDR)" \
            --ok-button "Guardar" \
            --cancel-button "Cancelar Asistente" \
            --inputbox "Introduce la dirección IPv4 local que deseas fijar de manera estática a este servidor.\n\nEs OBLIGATORIO incluir la máscara de subred en notación CIDR.\n\nEjemplo válido de red doméstica: 192.168.1.150/24\n(Donde '/24' equivale a la máscara tradicional 255.255.255.0)" \
            "${r}" "${c}" "${CurrentIPv4addr}" \
            3>&1 1>&2 2>&3)"; then
            
            if validIPAndNetmask "${IPv4addr}"; then
              echo "::: [INFO] Entrada válida de IPv4 estática: ${IPv4addr}"
              IPv4AddrValid=true
            else
              echo "::: [AVISO] Formato IPv4 inválido provisto por el usuario: ${IPv4addr}"
              whiptail \
                --backtitle "Configuración Manual de Red - PiVPN" \
                --title "Error: Formato IPv4 No Válido" \
                --ok-button "Volver a Intentar" \
                --msgbox "La dirección IP o máscara introducida no es válida: '${IPv4addr}'\n\nPor favor, verifica que cumpla con los rangos numéricos correctos (0-255) y que finalice con su prefijo CIDR correspondiente (Ej. /24, /22)." \
                "${r}" "${c}"
              IPv4AddrValid=false
            fi
          else
            err "El usuario canceló la introducción manual de la dirección IPv4. Abortando instalación."
            exit 1
          fi
        done

        # Sub-bucle 2: Solicitar y validar la Puerta de Enlace Predeterminada (Gateway / Router IP)
        until [[ "${IPv4gwValid}" == 'true' ]]; do
          if IPv4gw="$(whiptail \
            --backtitle "Configuración Manual de Red - PiVPN" \
            --title "Dirección de Puerta de Enlace (Router)" \
            --ok-button "Guardar" \
            --cancel-button "Cancelar Asistente" \
            --inputbox "Introduce la dirección IP interna correspondiente a tu puerta de enlace predeterminada (La IP de administración local de tu Router).\n\nEste parámetro NO debe llevar máscara de subred.\n\nEjemplo común: 192.168.1.1" \
            "${r}" "${c}" "${CurrentIPv4gw}" \
            3>&1 1>&2 2>&3)"; then
            
            if validIP "${IPv4gw}"; then
              echo "::: [INFO] Entrada válida de Puerta de Enlace IPv4: ${IPv4gw}"
              IPv4gwValid=true
            else
              echo "::: [AVISO] Formato de puerta de enlace inválido provisto por el usuario: ${IPv4gw}"
              whiptail \
                --backtitle "Configuración Manual de Red - PiVPN" \
                --title "Error: Puerta de Enlace No Válida" \
                --ok-button "Volver a Intentar" \
                --msgbox "La dirección de la pasarela no cumple con el estándar IPv4: '${IPv4gw}'\n\nIntroduce una IP limpia de 4 octetos sin barras ni máscaras de subred adicionales." \
                "${r}" "${c}"
              IPv4gwValid=false
            fi
          else
            err "El usuario canceló la introducción manual de la puerta de enlace. Abortando instalación."
            exit 1
          fi
        done

        # Verificación y Cierre: Presentación del balance final de datos para validación visual del administrador
        if whiptail \
          --backtitle "Configuración Manual de Red - PiVPN" \
          --title "Revisión de Parámetros de Red Escritos" \
          --yes-button "Confirmar y Aplicar" \
          --no-button "Corregir Datos" \
          --yesno "¿Confirmas que los siguientes datos estructurados son los correctos para inicializar el despliegue de interfaces?\n\n  • Dirección IPv4 fija (CIDR):  ${IPv4addr}\n  • Puerta de enlace local:     ${IPv4gw}" \
          "${r}" "${c}"; then
          
          # Persistencia final tras validación completa del bloque interactivo
          {
            echo "IPv4addr=${IPv4addr}"
            echo "IPv4gw=${IPv4gw}"
          } >> "${tempsetupVarsFile}"
          
          echo "::: [ÉXITO] Parámetros manuales de red confirmados por el usuario y guardados con éxito."
          ipSettingsCorrect=true
        else
          # El usuario detectó un error en la revisión; reiniciamos los flags para repetir las capturas
          echo "::: [AVISO] El usuario rechazó el resumen de red. Reiniciando bucle de captura manual."
          ipSettingsCorrect=false
          IPv4AddrValid=false
          IPv4gwValid=false
        fi
      done # Fin del bucle principal 'until ipSettingsCorrect'
    fi # Fin de modificación manual vs parámetros DHCP heredados
  fi # Fin de decisión Reserva DHCP vs Configuración local manual
}

setDHCPCD() {
  # ==============================================================================
  #         APLICACIÓN DE DIRECCIÓN IP ESTÁTICA VÍA SUBSISTEMA DHCPCD
  # ==============================================================================
  # Valida la existencia del archivo de configuración global de dhcpcd y añade
  # las directivas estáticas correspondientes si no se encuentran ya registradas.

  echo "::: [INFO] Configurando direccionamiento estático mediante el demonio dhcpcd..."

  if [[ -f "${dhcpcdFile}" ]]; then
    # Evitar duplicaciones redundantes inspeccionando el archivo de configuración
    if grep -q "${IPv4addr}" "${dhcpcdFile}"; then
      echo "::: [INFO] La dirección IP estática ya se encuentra registrada en: ${dhcpcdFile}."
    else
      echo "::: [INFO] Escribiendo nuevas directivas de red en '${dhcpcdFile}'..."
      writeDHCPCDConf

      echo "::: [INFO] Intentando actualizar dinámicamente la IP en la interfaz '${IPv4dev}'..."
      if ${SUDO} ip addr replace dev "${IPv4dev}" "${IPv4addr}"; then
        echo "::: [ÉXITO] Dirección IP local reemplazada en caliente correctamente a ${IPv4addr}."
        echo "::: [AVISO] Nota: Se recomienda realizar un reinicio limpio al finalizar la instalación."
      else
        echo "::: [AVISO] No se pudo aplicar el cambio en caliente. La nueva IP se asentará tras el reinicio."
      fi
    fi
  else
    err "Error crítico: No se localizó el archivo de configuración de red esperado en '${dhcpcdFile}'."
    exit 1
  fi
}

writeDHCPCDConf() {
  # ==============================================================================
  #         ESCRITURA ATÓMICA DE PARÁMETROS EN EL ARCHIVO DHCPCD.CONF
  # ==============================================================================
  # Vuelca las directivas estructuradas de red local mediante elevación de privilegios.

  {
    echo "interface ${IPv4dev}"
    echo "static ip_address=${IPv4addr}"
    echo "static routers=${IPv4gw}"
    echo "static domain_name_servers=${IPv4dns}"
  } | ${SUDO} tee -a "${dhcpcdFile}" > /dev/null

  if [[ "${PIPESTATUS[1]}" -ne 0 ]]; then
    err "Error grave: Falló la escritura persistente en el archivo '${dhcpcdFile}'."
    exit 1
  fi
}

setNetworkManager() {
  # ==============================================================================
  #       APLICACIÓN DE DIRECCIÓN IP ESTÁTICA VÍA NETWORKMANAGER (NMCLI)
  # ==============================================================================
  # Identifica de forma precisa la conexión activa vinculada al dispositivo de red
  # y conmuta su comportamiento de asignación automática (DHCP) a estático/manual.

  echo "::: [INFO] Solicitando identificador único de conexión activa para la interfaz '${IPv4dev}'..."

  # Extracción limpia del UUID de red de la conexión actualmente en uso
  local connectionUUID
  connectionUUID=$(nmcli -t con show --active | awk -v ref="${IPv4dev}" -F: 'match($0, ref){print $2}')

  # Control de Contingencia: Intento de resolución específico por mapeo de dispositivo si el flujo general falla
  if [[ -z "${connectionUUID}" ]]; then
    connectionUUID=$(nmcli -t -f DEVICE,UUID con show --active 2>/dev/null | awk -F: -v dev="${IPv4dev}" '$1==dev {print $2}')
  fi

  if [[ -z "${connectionUUID}" ]]; then
    err "No se pudo identificar una conexión activa de NetworkManager vinculada a la interfaz '${IPv4dev}'."
    exit 1
  fi

  echo "::: [INFO] Conexión activa validada (UUID: ${connectionUUID}). Modificando perfil de red..."

  # Reconfiguración manual del perfil de red mediante nmcli
  if ${SUDO} nmcli con mod "${connectionUUID}" \
    ipv4.addresses "${IPv4addr}" \
    ipv4.gateway "${IPv4gw}" \
    ipv4.dns "${IPv4dns}" \
    ipv4.method "manual"; then
    
    echo "::: [ÉXITO] Los parámetros de NetworkManager se han modificado de forma correcta."
    echo "::: [INFO] El gestor aplicará la configuración estática de forma permanente al reiniciar los servicios."
  else
    err "Error al aplicar las modificaciones IPv4 de NetworkManager sobre la conexión con UUID: ${connectionUUID}."
    exit 1
  fi
}

setStaticIPv4() {
  # ==============================================================================
  #            ORQUESTADOR GENERAL DE ASIGNACIÓN DE RED CONFIGURADA
  # ==============================================================================
  # Evalúa dinámicamente cuál es el motor de red operativo del sistema anfitrión
  # y deriva el flujo hacia el gestor correspondiente.

  echo "::: [INFO] Iniciando el volcado final de la configuración estática de IPv4..."

  if [[ -v useNetworkManager ]]; then
    echo "::: [INFO] Motor de red detectado en las variables: NetworkManager."
    setNetworkManager
    echo "useNetworkManager=${useNetworkManager}" >> "${tempsetupVarsFile}"
  else
    echo "::: [INFO] Motor de red detectado en las variables: Subsistema clásico DHCPCD."
    setDHCPCD
  fi

  echo "::: [ÉXITO] Configuración e inicialización de interfaces fijas IPv4 completada."
}

chooseUser() {
  # ==============================================================================
  #         SELECCIÓN / CREACIÓN DEL USUARIO DE CONFIGURACIÓN VPN
  # ==============================================================================
  # Define o crea el usuario local no privilegiado (no-root) bajo cuya ruta home
  # se almacenarán y custodiarán los perfiles y certificados criptográficos (.ovpn / .conf).

  local numUsers
  local availableUsers
  local install_home

  # ------------------------------------------------------------------------------
  # FLUJO A: GESTIÓN EN MODO DESATENDIDO / AUTOMATIZADO
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido activo. Validando privilegios de usuario..."

    if [[ -z "${install_user}" ]]; then
      # Contar cuántos usuarios reales con UID estándar (1000-60000) existen en el sistema
      numUsers="$(awk -F ':' 'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' /etc/passwd)"

      if [[ "${numUsers}" -eq 1 ]]; then
        install_user="$(awk -F ':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)"
        echo "::: [INFO] No se especificó usuario explícito. Detectado único usuario válido: '${install_user}'. Asignándolo de forma automática."
      else
        err "Error desatendido: No se especificó la variable 'install_user' y existen múltiples o ninguna cuenta de usuario válida en el sistema."
        exit 1
      fi
    else
      # Si el usuario fue provisto, verificar si ya existe en la base de datos de cuentas locales
      if awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd | grep -qw "${install_user}"; then
        echo "::: [INFO] El usuario especificado '${install_user}' ha sido validado. Alojará las configuraciones de los clientes."
      else
        echo "::: [AVISO] El usuario solicitado '${install_user}' no existe en el sistema anfitrión. Procediendo a su aprovisionamiento..."

        if [[ "${PLAT}" == 'Alpine' ]]; then
          ${SUDO} adduser -s /bin/bash -D "${install_user}"
          ${SUDO} addgroup "${install_user}" wheel
        else
          ${SUDO} useradd -ms /bin/bash "${install_user}"
        fi

        echo "::: [ÉXITO] Usuario '${install_user}' creado de forma correcta sin contraseña asignada."
        echo "::: [AVISO] IMPORTANTE: Recuerda establecer una contraseña segura ejecutando manualmente: 'sudo passwd ${install_user}'"
      fi
    fi

    # Resolver la ruta del directorio HOME asignada al usuario seleccionado
    install_home="$(awk -F: -v user="${install_user}" '$1==user {print $6}' /etc/passwd)"
    install_home="${install_home%/}"

    # Persistencia de variables de entorno del despliegue
    {
      echo "install_user=${install_user}"
      echo "install_home=${install_home}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  # ------------------------------------------------------------------------------
  # FLUJO B: ASISTENTE INTERACTIVO (GRÁFICO - WHIPTAIL)
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Desplegando advertencia informativa sobre privilegios de almacenamiento..."

  # INTERFAZ INTERACTIVA: Cuadro explicativo de roles de seguridad (Corrección de duplicación de flag --msgbox)
  whiptail \
    --backtitle "Gestión de Usuarios del Sistema - PiVPN" \
    --title "Perfil de Almacenamiento VPN" \
    --ok-button "Entendido, Continuar" \
    --msgbox "Por motivos estrictos de seguridad y privilegios mínimos, este instalador requiere asociar las configuraciones y llaves de cifrado (.ovpn o .conf) a una cuenta de usuario estándar del sistema operativo que no sea 'root'.\n\nA continuación, se te presentará la lista de usuarios locales para que selecciones el encargado de custodiar estos perfiles." \
    "${r}" "${c}"

  # Escaneo inicial y conteo formal de cuentas de usuario no root
  numUsers="$(awk -F ':' 'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' /etc/passwd)"

  # CONGENCIENCIA INTERACTIVA: Si el sistema está complemente limpio y carece de usuarios estándar
  if [[ "${numUsers}" -eq 0 ]]; then
    echo "::: [AVISO] No se han encontrado cuentas de usuario estándar en el rango UID tradicional. Solicitando creación..."
    
    local userToAdd
    if userToAdd="$(whiptail \
      --backtitle "Gestión de Usuarios del Sistema - PiVPN" \
      --title "Crear Nuevo Usuario Local" \
      --ok-button "Crear Usuario" \
      --cancel-button "Cancelar e Interrumpir" \
      --inputbox "No se ha detectado ninguna cuenta de usuario local válida (no-root) en este sistema operativo.\n\nPor favor, introduce un nombre para crear un nuevo usuario administrador de configuraciones:" \
      "${r}" "${c}" \
      3>&1 1>&2 2>&3)"; then
      
      local PASSWORD
      PASSWORD="$(whiptail \
        --backtitle "Gestión de Usuarios del Sistema - PiVPN" \
        --title "Contraseña del Nuevo Usuario" \
        --ok-button "Asignar Contraseña" \
        --cancel-button "Cancelar" \
        --passwordbox "Establece una contraseña de acceso segura para la cuenta recién introducida ('${userToAdd}'):" \
        "${r}" "${c}" \
        3>&1 1>&2 2>&3)"

      echo "::: [INFO] Registrando usuario '${userToAdd}' en el sistema utilizando mecanismos criptográficos nativos..."

      if [[ "${PLAT}" == 'Alpine' ]]; then
        if ${SUDO} adduser -Ds /bin/bash "${userToAdd}"; then
          ${SUDO} addgroup "${userToAdd}" wheel
          echo "${userToAdd}:${PASSWORD}" | ${SUDO} chpasswd
          ${SUDO} passwd -u "${userToAdd}" > /dev/null 2>&1
          echo "::: [ÉXITO] Usuario '${userToAdd}' creado y configurado correctamente en Alpine Linux."
          ((numUsers += 1))
        else
          err "Fallo crítico al intentar ejecutar 'adduser' en el entorno de Alpine."
          exit 1
        fi
      else
        # OPTIMIZACIÓN DE SEGURIDAD: Sustitución de Perl + Salt estático por chpasswd nativo del sistema
        if ${SUDO} useradd -m -s /bin/bash "${userToAdd}"; then
          echo "${userToAdd}:${PASSWORD}" | ${SUDO} chpasswd
          echo "::: [ÉXITO] Usuario '${userToAdd}' creado y configurado correctamente en el sistema anfitrión."
          ((numUsers += 1))
        else
          err "Fallo crítico al intentar ejecutar 'useradd' en la distribución."
          exit 1
        fi
      fi
    else
      err "El usuario canceló la fase mandatoria de creación de cuenta local. Abortando instalación."
      exit 1
    fi
  fi

  # ------------------------------------------------------------------------------
  # CONSTRUCCIÓN DINÁMICA DE LA LISTA DE RADIOLIST (SELECCIÓN DE USUARIO)
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Construyendo matriz dinámica de selección para la interfaz visual..."
  availableUsers="$(awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)"
  
  local userArray=()
  local firstloop=1
  local mode

  while read -r line; do
    [[ -z "${line}" ]] && continue
    mode="OFF"
    if [[ "${firstloop}" -eq 1 ]]; then
      firstloop=0
      mode="ON" # Pre-marcar por defecto el primer elemento de la lista para facilitar la UX
    fi
    userArray+=("${line}" "Usuario local del sistema" "${mode}")
  done <<< "${availableUsers}"

  # Inicialización estructurada del comando Whiptail Radiolist
  local chooseUserCmd=(
    whiptail
    --backtitle "Gestión de Usuarios del Sistema - PiVPN"
    --title "Selección de Usuario Local"
    --ok-button "Confirmar Selección"
    --cancel-button "Cancelar e Interrumpir"
    --separate-output
    --radiolist "Selecciona la cuenta de usuario encargada de custodiar las llaves y certificados criptográficos de tus clientes VPN:\n(Usa las flechas de dirección para navegar y la barra 'Espacio' para marcar tu opción)"
    "${r}" "${c}" "${numUsers}"
  )

  echo "::: [INFO] Desplegando selector interactivo de cuentas disponibles..."
  local chooseUserOptions
  if chooseUserOptions=$("${chooseUserCmd[@]}" "${userArray[@]}" 2>&1 > /dev/tty); then
    
    local desiredUser
    for desiredUser in ${chooseUserOptions}; do
      install_user="${desiredUser}"
      
      # Extracción optimizada y limpia de la ruta del directorio HOME
      install_home="$(awk -F: -v user="${install_user}" '$1==user {print $6}' /etc/passwd)"
      install_home="${install_home%/}"

      echo "::: [ÉXITO] Usuario del ecosistema seleccionado formalmente: ${install_user} (Ruta base: ${install_home})"

      {
        echo "install_user=${install_user}"
        echo "install_home=${install_home}"
      } >> "${tempsetupVarsFile}"
    done
  else
    err "El usuario interrumpió la pantalla de asignación de perfil local. Abortando proceso."
    exit 1
  fi
}

isRepo() {
  # ==============================================================================
  #       VERIFICACIÓN DE INTEGRIDAD DE REPOSITORIO GIT LOCAL
  # ==============================================================================
  # Evalúa si un directorio específico existe y está inicializado formalmente
  # como un árbol de trabajo válido de Git.

  local target_dir="${1}"
  echo "::: [INFO] Verificando la presencia e integridad del repositorio en: ${target_dir}"

  if [[ ! -d "${target_dir}" ]]; then
    echo "::: [AVISO] El directorio de destino no existe o no es accesible."
    return 1
  fi

  # OPTIMIZACIÓN: Verificación nativa e independiente del directorio de ejecución actual
  if ${SUDO} ${GITBIN} -C "${target_dir}" rev-parse --is-inside-work-tree &>/dev/null; then
    echo "::: [INFO] Estructura Git válida detectada en la ruta objetivo."
    return 0
  else
    echo "::: [AVISO] La ruta existe pero no corresponde a un repositorio Git válido."
    return 1
  fi
}

cloneAndSetupRepo() {
  # ==============================================================================
  #       TRABAJADOR INTERNO: CLONACIÓN, MONITOREO Y CONMUTACIÓN DE RAMAS
  # ==============================================================================
  # Centraliza la lógica de descarga para mitigar la duplicación de código.
  # Garantiza operaciones de limpieza seguras y valida la correcta ejecución en background.

  local target_dir="${1}"
  local repo_url="${2}"
  local parent_dir
  parent_dir="$(dirname "${target_dir}")"

  echo "::: [INFO] Saneando el espacio de trabajo local para evitar colisiones..."
  
  # Medida de protección crítica contra borrados accidentales en la raíz
  if [[ -n "${target_dir}" && "${target_dir}" != "/" && "${target_dir}" != "." ]]; then
    ${SUDO} rm -rf "${target_dir}"
  fi

  echo "::: [INFO] Descargando componentes del repositorio remoto..."
  
  # Posicionarse en el directorio padre antes de clonar para evitar bloqueos de Git
  cd "${parent_dir}" || exit 1

  # Clonación asíncrona optimizada en profundidad (Shallow Clone)
  ${SUDO} ${GITBIN} clone -q \
    --depth 1 \
    --no-single-branch \
    "${repo_url}" \
    "${target_dir}" > /dev/null 2>&1 &
  
  # Invocar el monitor visual de progreso mediante su PID
  spinner $!

  # Validación post-clonación: Asegurar que el proceso asíncrono se consolidó con éxito
  if [[ ! -d "${target_dir}" ]]; then
    err "Fallo crítico: No se pudo clonar el repositorio remoto en la ruta: '${target_dir}'"
    exit 1
  fi

  cd "${target_dir}" || exit 1
  echo "::: [ÉXITO] Sincronización del repositorio base completada."

  # ------------------------------------------------------------------------------
  # GESTIÓN DE RAMAS (PRODUCCIÓN / DESARROLLO CUSTOM / TESTING)
  # ------------------------------------------------------------------------------
  if [[ -n "${pivpnGitBranch}" ]]; then
    echo "::: [INFO] Conmutando a la rama de desarrollo personalizada: '${pivpnGitBranch}'..."
    if ${SUDOE} ${GITBIN} checkout -q "${pivpnGitBranch}"; then
      echo "::: [ÉXITO] Despliegue completado sobre la rama: '${pivpnGitBranch}'."
    else
      err "No se pudo cambiar a la rama solicitada '${pivpnGitBranch}'. Verifica su existencia en el origen."
      exit 1
    fi
  elif [[ -n "${TESTING:-}" ]]; then
    echo "::: [AVISO] Variable de entorno TESTING detectada. Conmutando a la rama 'test'..."
    if ${SUDOE} ${GITBIN} checkout -q test; then
      echo "::: [ÉXITO] Despliegue completado sobre la rama de pruebas: 'test'."
    else
      err "No se pudo conmutar el repositorio a la rama 'test'."
      exit 1
    fi
  fi
}

updateRepo() {
  # ==============================================================================
  #         ACTUALIZACIÓN / REPARACIÓN DE REPOSITORIO EXISTENTE
  # ==============================================================================
  
  if [[ "${UpdateCmd}" == "Repair" ]]; then
    echo "::: [INFO] Modo reparación activo. Preservando el estado del repositorio local actual sin realizar descargas."
  else
    echo "::: [INFO] Iniciando la actualización y sobreescritura controlada del repositorio..."
    cloneAndSetupRepo "${1}" "${2}"
  fi
}

makeRepo() {
  # ==============================================================================
  #         INICIALIZACIÓN LIMPIA DE REPOSITORIO INEXISTENTE
  # ==============================================================================
  
  echo "::: [INFO] Procediendo con una inicialización limpia del repositorio de fuentes..."
  cloneAndSetupRepo "${1}" "${2}"
}

getGitFiles() {
  # ==============================================================================
  #         ORQUESTADOR DE EVALUACIÓN DE ARCHIVOS BASE
  # ==============================================================================
  
  echo "::: [INFO] Evaluando la validez del árbol de directorios de PiVPN..."

  if isRepo "${1}"; then
    updateRepo "${1}" "${2}"
  else
    makeRepo "${1}" "${2}"
  fi
}

cloneOrUpdateRepos() {
  # ==============================================================================
  #         PUNTO DE ENTRADA GLOBAL PARA LA ADQUISICIÓN DE FUENTES
  # ==============================================================================
  
  echo "::: [INFO] Asegurando jerarquía de directorios del sistema en /usr/local/src..."
  
  if ! ${SUDO} mkdir -p /usr/local/src; then
    err "Error de entorno: No se pudo crear o verificar el directorio '/usr/local/src'. Revisa los privilegios del sistema."
    exit 1
  fi

  # Ejecución de la descarga o actualización de archivos Git
  if ! getGitFiles "${pivpnFilesDir}" "${pivpnGitUrl}"; then
    err "Error catastrófico: No se pudo procesar la descarga de '${pivpnGitUrl}' hacia '${pivpnFilesDir}'."
    exit 1
  fi
}

installPiVPN() {
  # ==============================================================================
  #          ORQUESTADOR PRINCIPAL DEL PROCESO DE INSTALACIÓN DE PIVPN
  # ==============================================================================
  # Coordina de forma secuencial la creación de directorios del ecosistema,
  # la recopilación interactiva de parámetros y el despliegue del motor VPN elegido.

  echo "::: [INFO] Iniciando el despliegue formal del ecosistema PiVPN..."

  # Garantizar la existencia de la ruta de configuración con control de errores directo
  if ! ${SUDO} mkdir -p /etc/pivpn/; then
    err "Fallo crítico: No se pudo crear el directorio de configuración persistente en '/etc/pivpn/'."
    exit 1
  fi

  # Selección interactiva del motor de virtualización de red
  echo "::: [INFO] Desplegando asistente de selección de motor VPN..."
  askWhichVPN
  setVPNDefaultVars

  # ------------------------------------------------------------------------------
  # FASE 1: INSTALACIÓN Y PARAMETRIZACIÓN DEL DEMONIO ESPECÍFICO
  # ------------------------------------------------------------------------------
  if [[ "${VPN}" == 'openvpn' ]]; then
    echo "::: [INFO] Inicializando rutina de aprovisionamiento para OpenVPN..."
    setOpenVPNDefaultVars
    askAboutCustomizing
    installOpenVPN
    askCustomProto
  elif [[ "${VPN}" == 'wireguard' ]]; then
    echo "::: [INFO] Inicializando rutina de aprovisionamiento para WireGuard..."
    setWireguardDefaultVars
    installWireGuard
  else
    err "Motor VPN desconocido o no parametrizado: '${VPN}'."
    exit 1
  fi

  # ------------------------------------------------------------------------------
  # FASE 2: CONFIGURACIÓN INTEGRAL DE RED, PUERTOS Y RESOLUCIÓN DNS
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Configurando parámetros de red global y asignación de puertos..."
  askCustomPort
  askClientDNS

  if [[ "${VPN}" == 'openvpn' ]]; then
    askCustomDomain
  fi

  # Definición de la puerta de enlace pública (IP Estática o Nombre de Dominio DNS)
  askPublicIPOrDNS

  # ------------------------------------------------------------------------------
  # FASE 3: CRIPTOGRAFÍA Y CONSOLIDACIÓN DE DIRECTIVAS
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Consolidando archivos de configuración criptográfica..."
  if [[ "${VPN}" == 'openvpn' ]]; then
    askEncryption
    confOpenVPN
    confOVPN
  elif [[ "${VPN}" == 'wireguard' ]]; then
    confWireGuard
  fi

  # Ajustes de enrutamiento del núcleo del sistema (Sysctl, Forwarding, IPTables)
  echo "::: [INFO] Aplicando directivas de red del sistema anfitrión..."
  confNetwork

  # ------------------------------------------------------------------------------
  # FASE 4: PERSISTENCIA DE LOGS Y VOLCADO DE VARIABLES VOLÁTILES
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Volcando variables de entorno para el gestor de perfiles..."
  if [[ "${VPN}" == 'openvpn' ]]; then
    if [[ "${PLAT}" == 'Alpine' ]]; then
      confLogging
    fi
  elif [[ "${VPN}" == 'wireguard' ]]; then
    writeWireguardTempVarsFile
  fi

  writeVPNTempVarsFile
  echo "::: [ÉXITO] Fase de instalación y preconfiguración completada correctamente."
}

decIPv4ToDot() {
  # ==============================================================================
  #          CONVERSIÓN DE ENTERO DECIMAL A NOTACIÓN PUNTO-DECIMAL IPv4
  # ==============================================================================
  # Toma un entero de 32 bits y realiza máscaras de bits dinámicas para extraer
  # los cuatro octetos tradicionales de una dirección IP (A.B.C.D).

  local ip_dec="${1}"
  local a b c d

  a=$(( (ip_dec & 0xFF000000) >> 24 ))
  b=$(( (ip_dec & 0x00FF0000) >> 16 ))
  c=$(( (ip_dec & 0x0000FF00) >> 8 ))
  d=$(( ip_dec & 0x000000FF ))

  printf "%s.%s.%s.%s\n" "${a}" "${b}" "${c}" "${d}"
}

dotIPv4ToDec() {
  # ==============================================================================
  #          CONVERSIÓN DE NOTACIÓN PUNTO-DECIMAL IPv4 A ENTERO DECIMAL
  # ==============================================================================
  # Procesa una cadena de texto IP (A.B.C.D) de forma segura. Se parametriza IFS
  # en línea para evitar la mutación y contaminación del entorno global de la shell.

  local a b c d
  IFS='.' read -r a b c d <<< "${1}"

  printf "%s\n" "$(( (a * 16777216) + (b * 65536) + (c * 256) + d ))"
}

dotIPv4FirstDec() {
  # ==============================================================================
  #          CÁLCULO DEL PRIMER VALOR DECIMAL DE UNA SUBRED (NETWORK ID)
  # ==============================================================================
  local decimal_ip decimal_mask
  
  decimal_ip=$(dotIPv4ToDec "${1}")
  decimal_mask=$(( 0xFFFFFFFF << (32 - ${2}) & 0xFFFFFFFF ))
  
  printf "%s\n" "$(( decimal_ip & decimal_mask ))"
}

dotIPv4LastDec() {
  # ==============================================================================
  #          CÁLCULO DEL ÚLTIMO VALOR DECIMAL DE UNA SUBRED (BROADCAST)
  # ==============================================================================
  local decimal_ip decimal_mask_inv
  
  decimal_ip=$(dotIPv4ToDec "${1}")
  decimal_mask_inv=$(( (1 << (32 - ${2})) - 1 ))
  
  printf "%s\n" "$(( decimal_ip | decimal_mask_inv ))"
}

decIPv4ToHex() {
  # ==============================================================================
  #          CONVERSIÓN DE ENTERO DECIMAL A IDENTIFICADOR HEXADECIMAL
  # ==============================================================================
  # Transforma la dirección en una cadena hexadecimal formateada en dos cuartetos.
  # Corrección crítica: Se declaran todas las variables internas como locales.

  local ip_dec="${1}"
  local hex quartet_hi quartet_lo leading_zeros_hi leading_zeros_lo

  hex="$(printf "%08x\n" "${ip_dec}")"
  quartet_hi=${hex:0:4}
  quartet_lo=${hex:4:4}

  # Limpieza estética de ceros a la izquierda en los bloques resultantes
  leading_zeros_hi="${quartet_hi%%[!0]*}"
  leading_zeros_lo="${quartet_lo%%[!0]*}"
  
  printf "%s:%s\n" "${quartet_hi#"${leading_zeros_hi}"}" "${quartet_lo#"${leading_zeros_lo}"}"
}

cidrToMask() {
  # ==============================================================================
  #          CONVERSIÓN DE PREFIJO CIDR A MÁSCARA DE RED TRADICIONAL
  # ==============================================================================
  # Optimización avanzada: Reemplaza el antiguo volcado posicional por el cálculo
  # matemático nativo de bits de la máscara, reutilizando la función decIPv4ToDot.

  local cidr="${1}"
  local mask_dec

  # Evitar desbordamientos si el prefijo está fuera de los rangos estándar de IPv4
  if [[ "${cidr}" -lt 0 || "${cidr}" -gt 32 ]]; then
    echo "255.255.255.0" # Retorno seguro de contingencia estándar (/24)
    return
  fi

  mask_dec=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
  decIPv4ToDot "${mask_dec}"
}

setVPNDefaultVars() {
  # ==============================================================================
  #         CONFIGURACIÓN DE PARÁMETROS Y MÁSCARAS POR DEFECTO DE LA VPN
  # ==============================================================================
  # Inicializa las clases de subred estándar para IPv4 e IPv6 si no han sido
  # preconfiguradas previamente en el archivo de instalación desatendida.

  echo "::: [INFO] Inicializando máscaras y variables de red por defecto..."

  if [[ -z "${subnetClass}" ]]; then
    subnetClass="24"
  fi

  if [[ -z "${subnetClassv6}" ]]; then
    subnetClassv6="64"
  fi
}

generateRandomSubnet() {
  # ==============================================================================
  #       GENERACIÓN AUTOMÁTICA Y SEGURA DE SUBREDES PARA EVITAR CONFLICTOS
  # ==============================================================================
  # Escanea las interfaces de red del sistema y subredes comunes de enrutadores
  # domésticos para encontrar una zona aislada y libre de colisiones IP.
  # Fuente base: https://community.openvpn.net/openvpn/wiki/AvoidRoutingConflicts

  local source_subnet="${1}"
  local target_netmask="${2}"

  echo "::: [INFO] Analizando el mapa de direccionamiento local para prevenir solapamientos..."

  # Declaración explícita con ámbito local para evitar contaminación de variables globales
  local -a excluded_subnets_dec=(
    167772160 167772415   # 10.0.0.0/24
    167772416 167772671   # 10.0.1.0/24
    167837952 167838207   # 10.1.1.0/24
    167840256 167840511   # 10.1.10.0/24
    167903232 167903487   # 10.2.0.0/24
    168296448 168296703   # 10.8.0.0/24
    168427776 168428031   # 10.10.1.0/24
    173693440 173693695   # 10.90.90.0/24
    174326016 174326271   # 10.100.1.0/24
    184549120 184549375   # 10.255.255.0/24
    3232235520 3232235775 # 192.168.0.0/24
    3232235776 3232236031 # 192.168.1.0/24
  )

  # OPTIMIZACIÓN DE FLUJO: Uso de mapfile y sustitución de procesos para evitar falsos positivos vacíos
  local -a currently_used_subnets=()
  mapfile -t currently_used_subnets < <(ip route show | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/[0-9]{1,2}' || true)

  local used used_ip used_mask
  for used in "${currently_used_subnets[@]}"; do
    # Protección crítica contra líneas vacías si grep no obtuvo coincidencias
    [[ -z "${used}" ]] && continue
    
    used_ip="${used%/*}"
    used_mask="${used##*/}"

    excluded_subnets_dec+=("$(dotIPv4FirstDec "${used_ip}" "${used_mask}")")
    excluded_subnets_dec+=("$(dotIPv4LastDec "${used_ip}" "${used_mask}")")
  done

  local excluded_subnets_count="${#excluded_subnets_dec[@]}"
  echo "::: [INFO] Se han registrado $((excluded_subnets_count / 2)) rangos de subred IP excluidos."

  local source_ip="${source_subnet%/*}"
  local source_netmask="${source_subnet##*/}"
  
  # Corrección SC2155: Separación estricta de declaración y asignación dinámica
  local source_ip_dec
  source_ip_dec="$(dotIPv4ToDec "${source_ip}")"
  
  # OPTIMIZACIÓN: Sustitución de cálculo exponencial por máscaras de bits aritméticas puras
  local source_netmask_dec=$(( (0xFFFFFFFF << (32 - source_netmask)) & 0xFFFFFFFF ))
  local first_ip_target_subnet_dec=$(( source_ip_dec & source_netmask_dec ))
  local total_ips_target_subnet=$(( 1 << (32 - target_netmask) ))

  # Mapeo y barajado aleatorio para garantizar inspección única por segmento sin repeticiones
  local subnets_count=$(( 1 << (target_netmask - source_netmask) ))
  local -a random_perm=()
  mapfile -t random_perm < <(shuf -i 0-$((subnets_count - 1)) 2>/dev/null || seq 0 $((subnets_count - 1)) | shuf)

  # Mitigación de sobrecarga en CPUs mononúcleo (ej. Raspberry Pi Zero / arquitecturas embebidas)
  local max_tries="${subnets_count}"
  if [[ $((subnets_count * excluded_subnets_count)) -ge 5000 ]]; then
    max_tries=$(( 5000 / (excluded_subnets_count / 2) ))
  fi

  local first_ip_subnet_dec last_ip_subnet_dec
  local first_ip_excluded_subnet_dec last_ip_excluded_subnet_dec
  local overlap
  local i j
  local subnet_encontrada="false"

  for ((i = 0; i < max_tries; i++)); do
    first_ip_subnet_dec=$(( first_ip_target_subnet_dec + (total_ips_target_subnet * random_perm[i]) ))
    last_ip_subnet_dec=$(( first_ip_subnet_dec + total_ips_target_subnet - 1 ))
    overlap="false"

    for ((j = 0; j < excluded_subnets_count; j += 2)); do
      first_ip_excluded_subnet_dec="${excluded_subnets_dec[j]}"
      last_ip_excluded_subnet_dec="${excluded_subnets_dec[j + 1]}"

      # Verificación lógica estructural de solapamiento de segmentos de red
      # Rango Excluido:  |----------- [j] ----------- [j+1] -----------|
      # Rango Candidato:           |------- [first] ------- [last] -------|
      if (( last_ip_excluded_subnet_dec >= first_ip_subnet_dec )) && (( first_ip_excluded_subnet_dec <= last_ip_subnet_dec )); then
        overlap="true"
        break
      fi
    done

    # Corrección estética y de rendimiento: Evaluación de cadena estándar en lugar de ejecución directa de string
    if [[ "${overlap}" == "false" ]]; then
      decIPv4ToDot "${first_ip_subnet_dec}"
      subnet_encontrada="true"
      break
    fi
  done

  # Control de contingencia si el espacio de red está completamente saturado
  if [[ "${subnet_encontrada}" == "false" ]]; then
    err "Error crítico: No se ha podido determinar una subred IPv4 libre de conflictos tras ${max_tries} intentos."
    return 1
  fi
}

allocateVPNSubnet() {
  # ==============================================================================
  #       ASIGNADOR ASISTIDO DE POOL DE SUBREDES PRIVADAS (RFC 1918)
  # ==============================================================================
  # Evalúa secuencialmente los tres bloques principales de direccionamiento privado
  # para mitigar colisiones con la LAN física del servidor o de los clientes.

  if [[ -n "${pivpnNET}" ]]; then
    echo "::: [INFO] Reutilizando subred estática preconfigurada de forma desatendida: ${pivpnNET}/${subnetClass}"
    return 0
  fi

  echo "::: [INFO] Buscando un segmento IPv4 dinámico libre de conflictos de enrutamiento..."

  # Intento 1: Bloque de Clase A (Común en entornos empresariales / Docker vnet)
  echo "::: [INFO] Evaluando disponibilidad en el espacio de direccionamiento 10.0.0.0/8..."
  pivpnNET="$(generateRandomSubnet "10.0.0.0/8" "${subnetClass}")"

  # Intento 2: Bloque de Clase B (Menos común, óptimo para aislamiento de VPN)
  if [[ -z "${pivpnNET}" ]]; then
    echo "::: [AVISO] Espacio 10.0.0.0/8 saturado o en conflicto. Probando bloque 172.16.0.0/12..."
    pivpnNET="$(generateRandomSubnet "172.16.0.0/12" "${subnetClass}")"
  fi

  # Intento 3: Bloque de Clase C (Uso doméstico masivo, última opción de contingencia)
  if [[ -z "${pivpnNET}" ]]; then
    echo "::: [AVISO] Espacio 172.16.0.0/12 no disponible. Probando bloque de contingencia 192.168.0.0/16..."
    pivpnNET="$(generateRandomSubnet "192.168.0.0/16" "${subnetClass}")"
  fi

  # Control de saturación total del entorno de red virtual
  if [[ -z "${pivpnNET}" ]]; then
    err "Error catastrófico: No se ha podido reservar una subred privada. Todos los segmentos RFC 1918 están ocupados."
    exit 1
  fi

  echo "::: [ÉXITO] Subred virtual asignada con éxito al direccionamiento local: ${pivpnNET}/${subnetClass}"
}

calculateVPNEndpoints() {
  # ==============================================================================
  #       CALCULADOR DE PARÁMETROS DE RED Y DIRECCIONES DE ENLACE
  # ==============================================================================
  # Transforma la subred en formato decimal y extrae de forma automática la primera 
  # IP válida para ser utilizada como la interfaz de la pasarela de enlace (Gateway).

  pivpnNETdec="$(dotIPv4ToDec "${pivpnNET}")"
  vpnGwdec="$((pivpnNETdec + 1))"
  vpnGw="$(decIPv4ToDot "${vpnGwdec}")"
  vpnGwhex="$(decIPv4ToHex "${vpnGwdec}")"

  # Tratamiento y aprovisionamiento automático de direccionamiento IPv6 (ULA)
  if [[ "${pivpnenableipv6:-0}" -eq 1 ]]; then
    if [[ -z "${pivpnNETv6}" ]]; then
      pivpnNETv6="fd11:5ee:bad:c0de::"
    fi
    vpnGwv6="${pivpnNETv6}${vpnGwhex}"
    echo "::: [INFO] Direccionamiento IPv6 activo. Pasarela virtual calculada: [${vpnGwv6}]"
  fi
}

setOpenVPNDefaultVars() {
  # ==============================================================================
  #       ESTABLECER CONFIGURACIONES POR DEFECTO PARA EL MOTOR OPENVPN
  # ==============================================================================
  
  echo "::: [INFO] Cargando entorno de variables predeterminadas para OpenVPN..."
  pivpnDEV="tun0"

  # Ejecutar asignación matricial de red y gateways
  allocateVPNSubnet
  calculateVPNEndpoints
}

setWireguardDefaultVars() {
  # ==============================================================================
  #       ESTABLECER CONFIGURACIONES POR DEFECTO PARA EL MOTOR WIREGUARD
  # ==============================================================================
  
  echo "::: [INFO] Cargando entorno de variables predeterminadas para WireGuard..."
  
  # WireGuard opera nativamente de forma exclusiva sobre la capa de transporte UDP
  pivpnPROTO="udp"
  pivpnDEV="wg0"

  # Ejecutar asignación matricial de red y gateways
  allocateVPNSubnet
  calculateVPNEndpoints

  # ------------------------------------------------------------------------------
  # GESTIÓN DE POLÍTICAS DE TRÁFICO PERMITIDO (ALLOWED IPs - SPLIT/FULL TUNNEL)
  # ------------------------------------------------------------------------------
  if [[ -z "${ALLOWED_IPS}" ]]; then
    # Por defecto, se aprovisiona como "Túnel Completo" (Full Tunnel) enrutando todo el tráfico
    ALLOWED_IPS="0.0.0.0/0"

    # Enrutar el tráfico global IPv6 a través del túnel si la pila dual está habilitada
    if [[ "${pivpnenableipv6:-0}" -eq 1 || "${pivpnforceipv6route:-0}" -eq 1 ]]; then
      ALLOWED_IPS="${ALLOWED_IPS}, ::0/0"
    fi
  fi

  # ------------------------------------------------------------------------------
  # OPTIMIZACIÓN DE MTU (MAXIMUM TRANSMISSION UNIT)
  # ------------------------------------------------------------------------------
  # Se establece 1420 por defecto para dejar un margen seguro de 80 bytes (overhead) 
  # evitando la fragmentación de paquetes encapsulados en enlaces WAN estándar de 1500.
  if [[ -z "${pivpnMTU}" ]]; then
    pivpnMTU="1420"
  fi

  # Desactivar bandera de personalización interactiva por defecto
  CUSTOMIZE=0
}

writeVPNTempVarsFile() {
  {
    echo "pivpnDEV=${pivpnDEV}"
    echo "pivpnNET=${pivpnNET}"
    echo "subnetClass=${subnetClass}"
    echo "pivpnenableipv6=${pivpnenableipv6}"

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      echo "pivpnNETv6=\"${pivpnNETv6}\""
      echo "subnetClassv6=${subnetClassv6}"
    fi

    echo "ALLOWED_IPS=\"${ALLOWED_IPS}\""
  } >> "${tempsetupVarsFile}"
}

writeWireguardTempVarsFile() {
  {
    echo "pivpnPROTO=${pivpnPROTO}"
    echo "pivpnMTU=${pivpnMTU}"

    # Escribir PERSISTENTKEEPALIVE si se proporciona a través del archivo desatendido
    # También se puede añadir manualmente a /etc/pivpn/wireguard/setupVars.conf
    # post instalación para ser utilizado en la generación del perfil del cliente
    if [[ -n "${pivpnPERSISTENTKEEPALIVE}" ]]; then
      echo "pivpnPERSISTENTKEEPALIVE=${pivpnPERSISTENTKEEPALIVE}"
    fi
  } >> "${tempsetupVarsFile}"
}

askWhichVPN() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ "${WIREGUARD_SUPPORT}" -eq 1 ]]; then
      if [[ -z "${VPN}" ]]; then
        echo ":: No se especificó ningún protocolo VPN, usando WireGuard"
        VPN="wireguard"
      else
        VPN="${VPN,,}"

        if [[ "${VPN}" == "wireguard" ]]; then
          echo "::: WireGuard se instalará"
        elif [[ "${VPN}" == "openvpn" ]]; then
          echo "::: OpenVPN se instalará"
        else
          err ":: ${VPN} no es un protocolo VPN compatible, por favor especifica 'wireguard' o 'openvpn'"
          exit 1
        fi
      fi
    else
      if [[ -z "${VPN}" ]]; then
        echo ":: No se especificó ningún protocolo VPN, usando OpenVPN"
        VPN="openvpn"
      else
        VPN="${VPN,,}"

        if [[ "${VPN}" == "openvpn" ]]; then
          echo "::: OpenVPN se instalará"
        else
          err ":: ${VPN} no es un protocolo VPN compatible en ${DPKG_ARCH} ${PLAT}, solo 'openvpn' lo es"
          exit 1
        fi
      fi
    fi
  else
    if [[ "${WIREGUARD_SUPPORT}" -eq 1 ]] \
      && [[ "${OPENVPN_SUPPORT}" -eq 1 ]]; then
      chooseVPNCmd=(whiptail
        --backtitle "Configuración Inicial del Servidor"
        --title "Selección de Protocolo VPN"
        --separate-output
        --radiolist "Selecciona el motor VPN que deseas instalar en tu sistema:

• WireGuard (Recomendado): Criptografía de última generación, máxima velocidad, conexión casi instantánea y excelente ahorro de batería en móviles.
• OpenVPN: El estándar tradicional. Muy flexible, altamente compatible y recomendado si necesitas usar TCP para evadir bloqueos de red estrictos.

(Presiona la barra espaciadora para marcar tu opción):" "${r}" "${c}" 2)
      VPNChooseOptions=(WireGuard "" on
        OpenVPN "" off)

      if VPN="$("${chooseVPNCmd[@]}" \
        "${VPNChooseOptions[@]}" \
        2>&1 > /dev/tty)"; then
        echo "::: Usando VPN: ${VPN}"
        VPN="${VPN,,}"
      else
        err "::: Cancelar seleccionado, saliendo...."
        exit 1
      fi
    elif [[ "${OPENVPN_SUPPORT}" -eq 1 ]] \
      && [[ "${WIREGUARD_SUPPORT}" -eq 0 ]]; then
      echo "::: Usando VPN: OpenVPN"
      VPN="openvpn"
    elif [[ "${OPENVPN_SUPPORT}" -eq 0 ]] \
      && [[ "${WIREGUARD_SUPPORT}" -eq 1 ]]; then
      echo "::: Usando VPN: WireGuard"
      VPN="wireguard"
    fi
  fi

  echo "VPN=${VPN}" >> "${tempsetupVarsFile}"
}

askAboutCustomizing() {
  if [[ "${runUnattended}" == 'false' ]]; then
    # CAMBIO: Se ha reestructurado el texto y la lógica de los botones para que el flujo sea más intuitivo (Sí = Confirmar lo recomendado, No = Personalizar). También se ha mejorado el formato de la lista para una lectura limpia en la terminal ()
    if whiptail \
      --backtitle "Configuración del Servidor PiVPN" \
      --title "Modo de Instalación y Parámetros" --yes-button "Aceptar y Continuar" --no-button "Personalizar" \
      --yesno "Para la mayoría de los entornos, PiVPN aplica un perfil de configuración optimizado por defecto. Se compone de los siguientes parámetros técnicos:

• Protocolo de Red: UDP (Más rápido y eficiente)
• Dominio de Búsqueda DNS: Ninguno (Por defecto)
• Nivel de Seguridad: Perfil Moderno (Certificado de 256 bits + Cifrado TLS Avanzado)

¿Deseas aplicar estos valores recomendados directamente o prefieres personalizar los detalles de la instalación?" "${r}" "${c}"; then
      # El usuario eligió "Aceptar y Continuar" -> NO quiere personalizar de forma manual
      CUSTOMIZE=0
    else
      # El usuario eligió "Personalizar" -> SÍ quiere cambiar los parámetros manuales
      CUSTOMIZE=1
    fi
  fi
}

installOpenVPN() {
  local PIVPN_DEPS gpg_path gpg_path="${pivpnFilesDir}/files/etc/apt/repo-public.gpg"
  echo "::: Instalando OpenVPN desde el paquete de Debian... "

  if [[ "${NEED_OPENVPN_REPO}" -eq 1 ]]; then
    # gnupg es usado por apt-key para importar la clave GPG de openvpn en el
    # llavero de APT
    PIVPN_DEPS=(gnupg)
    installDependentPackages PIVPN_DEPS[@]

    # Clave GPG pública del repositorio de OpenVPN
    # (huella digital 0x30EBF4E73CCE63EEE124DD278E6DA8B4E158C569)
    echo "::: Añadiendo clave del repositorio..."
    
    # CAMBIO: Definición de una ruta de llavero moderna y segura. Se prioriza /usr/share/keyrings en sistemas modernos, cayendo en /etc/apt/trusted.gpg.d si no existe para máxima compatibilidad con distribuciones antiguas ()
    local keyring_dir="/usr/share/keyrings"
    if [[ ! -d "${keyring_dir}" ]]; then
      keyring_dir="/etc/apt/trusted.gpg.d"
    fi
    local keyring_path="${keyring_dir}/openvpn-repo-keyring.gpg"

    # CAMBIO: Reemplazo del comando obsoleto apt-key add. Ahora se analiza si la clave está en formato ASCII armadura o binario y se escribe en el archivo de destino de forma segura usando gpg --dearmor si es necesario ()
    if gpg --valid-extension "${gpg_path}" &>/dev/null || file "${gpg_path}" | grep -q "gpg public public keyring" || ! grep -q "BEGIN PGP PUBLIC KEY BLOCK" "${gpg_path}"; then
      ${SUDO} cp "${gpg_path}" "${keyring_path}"
    else
      ${SUDO} gpg --dearmor < "${gpg_path}" | ${SUDO} tee "${keyring_path}" > /dev/null
    fi

    # CAMBIO: Verificación de control para asegurar que el archivo del llavero se haya creado correctamente antes de proceder con la instalación ()
    if [[ ! -f "${keyring_path}" ]]; then
      err "::: No se puede importar la clave GPG de OpenVPN"
      exit 1
    fi

    echo "::: Añadiendo repositorio de OpenVPN... "
    # CAMBIO: Modificación de la línea del repositorio para incluir el parámetro [signed-by=...] vinculando directamente la clave GPG específica al repositorio de OpenVPN, eliminando la vulnerabilidad global de apt-key ()
    echo "deb [signed-by=${keyring_path}] https://build.openvpn.net/debian/openvpn/stable ${OSCN} main" \
      | ${SUDO} tee /etc/apt/sources.list.d/pivpn-openvpn-repo.list > /dev/null
    echo "::: Actualizando la caché de paquetes..."
    updatePackageCache
  fi

  PIVPN_DEPS=(openvpn)
  installDependentPackages PIVPN_DEPS[@]
}

installWireGuard() {
  local PIVPN_DEPS

  echo -n "::: Instalando WireGuard"
  PIVPN_DEPS=(wireguard-tools)

  if [[ "${PLAT}" == "Raspbian" ]]; then
    echo " desde el paquete Raspbian..."

    # qrencode se usa para generar qrcodes desde el archivo de config,
    # para uso con clientes móviles
    PIVPN_DEPS+=(qrencode)
  elif [[ "${PLAT}" == "Debian" ]]; then
    echo " desde el paquete Debian..."

    PIVPN_DEPS+=(qrencode)

    if [[ "${WIREGUARD_BUILTIN}" -eq 0 ]]; then
      # Instalar explícitamente el módulo si no está integrado
      PIVPN_DEPS+=(linux-headers-amd64 wireguard-dkms)
    fi
  elif [[ "${PLAT}" == "Ubuntu" ]]; then
    echo "..."

    PIVPN_DEPS+=(qrencode)

    if [[ "${WIREGUARD_BUILTIN}" -eq 0 ]]; then
      PIVPN_DEPS+=(linux-headers-generic wireguard-dkms)
    fi
  elif [[ "${PLAT}" == 'Alpine' ]]; then
    echo "..."

    PIVPN_DEPS+=(libqrencode)
  fi

  if [[ "${PLAT}" == "Raspbian" || "${PLAT}" == "Debian" ]] \
    && [[ -z "${AVAILABLE_WIREGUARD}" ]]; then
    if [[ "${PLAT}" == "Debian" ]]; then
      echo "::: Añadiendo repositorio Debian Bullseye... "
      echo "deb https://deb.debian.org/debian/ bullseye main" \
        | ${SUDO} tee /etc/apt/sources.list.d/pivpn-bullseye-repo.list > /dev/null
    else
      echo "::: Añadiendo repositorio Raspbian Bullseye... "
      echo "deb http://raspbian.raspberrypi.org/raspbian/ bullseye main" \
        | ${SUDO} tee /etc/apt/sources.list.d/pivpn-bullseye-repo.list > /dev/null
    fi

    {
      printf 'Package: *\n'
      printf 'Pin: release n=bullseye\n'
      printf 'Pin-Priority: -1\n\n'
      printf 'Package: wireguard wireguard-dkms wireguard-tools\n'
      printf 'Pin: release n=bullseye\n'
      printf 'Pin-Priority: 100\n'
    } | ${SUDO} tee /etc/apt/preferences.d/pivpn-limit-bullseye > /dev/null

    echo "::: Actualizando la caché de paquetes..."
    updatePackageCache
  fi

  installDependentPackages PIVPN_DEPS[@]
}

askCustomProto() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnPROTO}" ]]; then
      echo "::: No se especificó un protocolo TCP/IP, usando el protocolo udp predeterminado"
      pivpnPROTO="udp"
    else
      pivpnPROTO="${pivpnPROTO,,}"

      if [[ "${pivpnPROTO}" == "udp" ]] \
        || [[ "${pivpnPROTO}" == "tcp" ]]; then
        echo "::: Usando el protocolo ${pivpnPROTO}"
      else
        err ":: ${pivpnPROTO} no es un protocolo TCP/IP compatible, especifica 'udp' o 'tcp'"
        exit 1
      fi
    fi

    echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
    return
  fi

  if [[ "${CUSTOMIZE}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
      pivpnPROTO="udp"
      echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
      return
    fi
  fi

  # Establecer los protocolos disponibles en un arreglo para que pueda ser usado
  # con un diálogo de whiptail
  if pivpnPROTO="$(whiptail \
    --backtitle "Configuración de Red" \
    --title "Selección de Protocolo VPN" --ok-button "Aceptar" --cancel-button "Cancelar" \
    --radiolist "Selecciona el protocolo de transporte para tu VPN. 

• UDP (Recomendado): Ofrece la mayor velocidad y rendimiento. Es el estándar ideal para la mayoría de los usuarios.
• TCP: Recomendado únicamente si necesitas atravesar redes corporativas o cortafuegos muy restrictivos que bloquean UDP.

(Usa la barra espaciadora para seleccionar tu opción):" "${r}" "${c}" 2 \
    "UDP" "" ON \
    "TCP" "" OFF \
    3>&1 1>&2 2>&3)"; then
    # Convertir la opción a minúsculas (UDP->udp)
    pivpnPROTO="${pivpnPROTO,,}"
    echo "::: Usando protocolo: ${pivpnPROTO}"
    echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
  else
    err "::: Cancelar seleccionado, saliendo...."
    exit 1
  fi
}

askCustomPort() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnPORT}" ]]; then
      if [[ "${VPN}" == "wireguard" ]]; then
        echo "::: No se especificó un puerto, usando el puerto predeterminado 51820"
        pivpnPORT=51820
      elif [[ "${VPN}" == "openvpn" ]]; then
        if [[ "${pivpnPROTO}" == "udp" ]]; then
          echo "::: No se especificó un puerto, usando el puerto predeterminado 1194"
          pivpnPORT=1194
        elif [[ "${pivpnPROTO}" == "tcp" ]]; then
          echo "::: No se especificó un puerto, usando el puerto predeterminado 443"
          pivpnPORT=443
        fi
      fi
    else
      if [[ "${pivpnPORT}" =~ ^[0-9]+$ ]] \
        && [[ "${pivpnPORT}" -ge 1 ]] \
        && [[ "${pivpnPORT}" -le 65535 ]]; then
        echo "::: Usando puerto ${pivpnPORT}"
      else
        err "::: ${pivpnPORT} no es un puerto válido, usa un puerto en el rango [1,65535] (inclusive)"
        exit 1
      fi
    fi

    echo "pivpnPORT=${pivpnPORT}" >> "${tempsetupVarsFile}"
    return
  fi

  until [[ "${PORTNumCorrect}" == 'true' ]]; do
    portInvalid="Invalid"

    if [[ "${VPN}" == "wireguard" ]]; then
      DEFAULT_PORT=51820
    elif [[ "${VPN}" == "openvpn" ]]; then
      if [[ "${pivpnPROTO}" == "udp" ]]; then
        DEFAULT_PORT=1194
      else
        DEFAULT_PORT=443
      fi
    fi

    if pivpnPORT="$(whiptail \
      --title "Puerto predeterminado de ${VPN}" \
      --inputbox "Puedes modificar el puerto predeterminado de ${VPN}.
Introduce un nuevo valor o presiona 'Enter' para mantener \
el predeterminado" "${r}" "${c}" "${DEFAULT_PORT}" \
      3>&1 1>&2 2>&3)"; then
      if [[ "${pivpnPORT}" =~ ^[0-9]+$ ]] \
        && [[ "${pivpnPORT}" -ge 1 ]] \
        && [[ "${pivpnPORT}" -le 65535 ]]; then
        :
      else
        pivpnPORT="${portInvalid}"
      fi
    else
      err "::: Cancelar seleccionado, saliendo...."
      exit 1
    fi

    if [[ "${pivpnPORT}" == "${portInvalid}" ]]; then
      whiptail \
        --backtitle "Puerto inválido" \
        --title "Puerto inválido" --ok-button "Aceptar" \
        --msgbox "Has introducido un número de puerto inválido.
    Por favor, introduce un número entre 1 - 65535.
    Si no estás seguro, simplemente mantén el predeterminado." "${r}" "${c}"
      PORTNumCorrect=false
    else
      if whiptail \
        --backtitle "Especificar puerto personalizado" \
        --title "Confirmar número de puerto personalizado" --yes-button "Sí" --no-button "No" \
        --yesno "¿Son correctas estas configuraciones?
    PUERTO: ${pivpnPORT}" "${r}" "${c}"; then
        PORTNumCorrect=true
      else
        # Si las configuraciones son incorrectas, el bucle continúa
        PORTNumCorrect=false
      fi
    fi
  done

  # escribir el puerto
  echo "pivpnPORT=${pivpnPORT}" >> "${tempsetupVarsFile}"
}

setupPiholeDNS() {
  # Añadir un archivo hosts personalizado para clientes VPN para que aparezcan
  # como 'nombre.pivpn' en el panel de Pi-hole además de resolverse
  # por sus nombres.
  echo "addn-hosts=/etc/pivpn/hosts.${VPN}" \
    | ${SUDO} tee "${dnsmasqConfig}" > /dev/null

  # Luego crear un archivo hosts vacío o limpiarlo si existe.
  ${SUDO} bash -c "> /etc/pivpn/hosts.${VPN}"

  # shellcheck disable=SC1090
  CORE_VERSION="$(source "$piholeVersions" && echo "${CORE_VERSION}")"
  if [ "$(echo -e 'v6.0.0\n'"${CORE_VERSION}" | sort -V | head -n 1)" = "v6.0.0" ]; then
    # Ejecutando Pi-hole v6 o posterior
    ${SUDO} pihole-FTL --config dns.listeningMode LOCAL
    ${SUDO} pihole-FTL --config misc.etc_dnsmasq_d true
  else
    # Configurar Pi-hole a "Escuchar en todas las interfaces" permite
    # que dnsmasq escuche en la interfaz VPN mientras permite
    # consultas solo de hosts cuya dirección esté en la LAN y
    # subredes VPN.
    ${SUDO} pihole -a -i local
  fi

  # Usar la IP de VPN de la Raspberry Pi como servidor DNS.
  pivpnDNS1="${vpnGw}"

  {
    echo "pivpnDNS1=${pivpnDNS1}"
    echo "pivpnDNS2=${pivpnDNS2}"
  } >> "${tempsetupVarsFile}"

  # Permitir solicitudes DNS entrantes a través de UFW.
  if [[ "${USING_UFW}" -eq 1 ]]; then
    ${SUDO} ufw insert 1 allow in \
      on "${pivpnDEV}" to any port 53 \
      from "${pivpnNET}/${subnetClass}" > /dev/null
  else
    ${SUDO} iptables -I INPUT -i "${pivpnDEV}" \
      -p udp --dport 53 -j ACCEPT -m comment --comment "pihole-DNS-rule"
  fi
}

askClientDNS() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ "${usePiholeDNS}" == 'true' ]] \
      && command -v pihole > /dev/null; then
      setupPiholeDNS
      return
    elif [[ -z "${pivpnDNS1}" ]] \
      && [[ -n "${pivpnDNS2}" ]]; then
      pivpnDNS1="${pivpnDNS2}"
      unset pivpnDNS2
    elif [[ -z "${pivpnDNS1}" ]] \
      && [[ -z "${pivpnDNS2}" ]]; then
      pivpnDNS1="9.9.9.9"
      pivpnDNS2="149.112.112.112"
      echo -n "::: Ningún proveedor DNS especificado, "
      echo "usando DNS Quad9 (${pivpnDNS1} ${pivpnDNS2})"
    fi

    local INVALID_DNS_SETTINGS=0

    if ! validIP "${pivpnDNS1}"; then
      INVALID_DNS_SETTINGS=1
      echo "::: DNS inválido ${pivpnDNS1}"
    fi

    if [[ -n "${pivpnDNS2}" ]] \
      && ! validIP "${pivpnDNS2}"; then
      INVALID_DNS_SETTINGS=1
      echo "::: DNS inválido ${pivpnDNS2}"
    fi

    if [[ "${INVALID_DNS_SETTINGS}" -eq 0 ]]; then
      echo "::: Usando DNS ${pivpnDNS1} ${pivpnDNS2}"
    else
      exit 1
    fi

    {
      echo "pivpnDNS1=${pivpnDNS1}"
      echo "pivpnDNS2=${pivpnDNS2}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  # Detectar y ofrecer el uso de Pi-hole
  if command -v pihole > /dev/null; then
    if [[ "${usePiholeDNS}" == 'true' ]] \
      || whiptail \
        --backtitle "Configurador PiVPN" \
        --title "Integración con Pi-hole" \
        --yes-button "Sí, configurar" \
        --no-button "No, gracias" \
        --yesno "Se ha detectado una instalación activa de Pi-hole. \
¿Deseas configurarlo como servidor DNS de tu VPN para disfrutar \
de bloqueo de anuncios en todos tus dispositivos?" "${r}" "${c}"; then
      setupPiholeDNS
      return
    fi
  fi

  DNSChoseCmd=(whiptail
    ---backtitle "Configurador PiVPN" \
    --title "Selección de Proveedor DNS" --ok-button "Seleccionar" --cancel-button "Cancelar" \
    --separate-output \
    --radiolist "Elige el proveedor DNS que usarán tus clientes VPN. \
(Usa la barra espaciadora para marcar tu opción).

Si deseas ingresar IPs personalizadas, selecciona 'Custom'.

NOTA PARA RESOLUTORES LOCALES:
Si ejecutas un Servidor DNS local (Pi-hole, AdGuard Home, Unbound, etc.), \
selecciona 'PiVPN-is-local-DNS'. Asegúrate de que escuche en la \
IP \"${vpnGw}\" y acepte peticiones desde \"${pivpnNET}/${subnetClass}\"." "${r}" "${c}" 6)
  DNSChooseOptions=(Google "" on
    CloudFlare "" off
    OpenDNS "" off
    Quad9 "" off
    AdGuard "" off
    FamilyShield "" off
    PiVPN-is-local-DNS "" off
    Custom "" off)

  if DNSchoices="$("${DNSChoseCmd[@]}" \
    "${DNSChooseOptions[@]}" \
    2>&1 > /dev/tty)"; then
    if [[ "${DNSchoices}" != "Custom" ]]; then
      echo "::: Usando servidores ${DNSchoices}."
      declare -A DNS_MAP=(["Google"]="8.8.8.8 8.8.4.4"
      ["CloudFlare"]="1.1.1.1 1.0.0.1"
      ["OpenDNS"]="208.67.222.222 208.67.220.220"
      ["Quad9"]="9.9.9.9 149.112.112.112"
      ["AdGuard"]="94.140.14.14 94.140.15.15"
      ["FamilyShield"]="208.67.222.123 208.67.220.123"
      ["PiVPN-is-local-DNS"]="${vpnGw}")
      pivpnDNS1=$(awk '{print $1}' <<< "${DNS_MAP["${DNSchoices}"]}")
      pivpnDNS2=$(awk '{print $2}' <<< "${DNS_MAP["${DNSchoices}"]}")
    else
      until [[ "${DNSSettingsCorrect}" == 'true' ]]; do
        strInvalid="Invalid"

        if pivpnDNS="$(whiptail \
          --backtitle "Configurador PiVPN" \
        --title "Servidores DNS Personalizados" --ok-button "Aceptar" cancel-button "Cancelar" \
        --inputbox "Introduce las direcciones IP de tus servidores DNS de subida, \
separadas por una coma.

Ejemplo: '1.1.1.1, 9.9.9.9'" "${r}" "${c}" "" \
          3>&1 1>&2 2>&3)"; then
          # Procesamiento de las IPs introducidas para extraer el primer y segundo servidor DNS, eliminando espacios y tabulaciones alrededor de las comas
          pivpnDNS1="$(echo "${pivpnDNS}" \
            | sed 's/[, \t]\+/,/g' \
            | awk -F, '{print$1}')"
          pivpnDNS2="$(echo "${pivpnDNS}" \
            | sed 's/[, \t]\+/,/g' \
            | awk -F, '{print$2}')"

          if ! validIP "${pivpnDNS1}" \
            || [[ ! "${pivpnDNS1}" ]]; then
            pivpnDNS1="${strInvalid}"
          fi

          if ! validIP "${pivpnDNS2}" \
            && [[ "${pivpnDNS2}" ]]; then
            pivpnDNS2="${strInvalid}"
          fi
        else
          err "::: Cancelar seleccionado, saliendo...."
          exit 1
        fi

        if [[ "${pivpnDNS1}" == "${strInvalid}" ]] \
          || [[ "${pivpnDNS2}" == "${strInvalid}" ]]; then
          whiptail \
            --backtitle "Configurador PiVPN" \
            --title "Error: IP Inválida" --ok-button "Reintentar" \
            --msgbox "Una o ambas direcciones IP introducidas no son válidas. \
Por favor, comprueba los datos e inténtalo de nuevo.

Datos detectados:
  • Servidor DNS 1: ${pivpnDNS1:-(Vacío)}
  • Servidor DNS 2: ${pivpnDNS2:-(Vacío)}" "${r}" "${c}"

          if [[ "${pivpnDNS1}" == "${strInvalid}" ]]; then
            pivpnDNS1=""
          fi

          if [[ "${pivpnDNS2}" == "${strInvalid}" ]]; then
            pivpnDNS2=""
          fi

          DNSSettingsCorrect=false
        else
          if whiptail \
            --backtitle "Especificar Proveedor(es) DNS de subida" \
            --title "Proveedor(es) DNS de subida" --yes-button "Sí" --no-button "No" \
            --yesno "¿Son correctas estas configuraciones?
    Servidor DNS 1: ${pivpnDNS1}
    Servidor DNS 2: ${pivpnDNS2}" "${r}" "${c}"; then
            DNSSettingsCorrect=true
          else
            # Si las configuraciones son incorrectas, el bucle continúa
            DNSSettingsCorrect=false
          fi
        fi
      done
    fi

  else
    err "::: Cancelación seleccionada. Saliendo..."
    exit 1
  fi

  {
    echo "pivpnDNS1=${pivpnDNS1}"
    echo "pivpnDNS2=${pivpnDNS2}"
  } >> "${tempsetupVarsFile}"
}

# Llama a esta función para usar una expresión regular y verificar
# si la entrada del usuario es un dominio personalizado válido
validDomain() {
  local domain="${1}"
  local perl_regexp='(?=^.{4,253}$)'
  perl_regexp="${perl_regexp}(^(?:[a-zA-Z0-9](?:(?:[a-zA-Z0-9\-]){0,61}"
  perl_regexp="${perl_regexp}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$)"
  grep -qP "${perl_regexp}" <<< "${domain}"
}

# Este procedimiento permite al usuario especificar un
# dominio de búsqueda personalizado si tiene uno.
askCustomDomain() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -n "${pivpnSEARCHDOMAIN}" ]]; then
      if validDomain "${pivpnSEARCHDOMAIN}"; then
        echo "::: Usando dominio personalizado ${pivpnSEARCHDOMAIN}"
      else
        err "::: El dominio personalizado ${pivpnSEARCHDOMAIN} no es válido"
        exit 1
      fi
    else
      echo "::: Omitiendo dominio personalizado"
    fi

    echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
    return
  fi

  if [[ "${CUSTOMIZE}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
      echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
      return
    fi
  fi

  DomainSettingsCorrect=false

  if whiptail \
    --backtitle "Configurador PiVPN" \
    --title "Dominio de Búsqueda Personalizado" --yes-button "Sí, añadir" --no-button "Omitir" \
    --defaultno \
    --yesno "¿Deseas configurar un sufijo de dominio de búsqueda personalizado?

[AVISO] Esta opción se recomienda solo para usuarios avanzados o entornos corporativos que dispongan de una infraestructura de dominio propia." "${r}" "${c}"; then
    until [[ "${DomainSettingsCorrect}" == 'true' ]]; do
      if pivpnSEARCHDOMAIN="$(whiptail \
        --backtitle "Configurador PiVPN" \
        --title "Dominio Personalizado" --ok-button "Continuar" --cancel-button "Cancelar" \
        --inputbox "Introduce tu sufijo de dominio personalizado.

Ejemplo: midominio.com" "${r}" "${c}" \
        --title "Dominio Personalizado" \
        3>&1 1>&2 2>&3)"; then
        if validDomain "${pivpnSEARCHDOMAIN}"; then
          if whiptail \
            ---backtitle "Configurador PiVPN" \
        --title "Confirmar Configuración" --yes-button "Confirmar" --no-button "Modificar" \
        --yesno "¿Es correcto el dominio introducido?

  • Dominio de búsqueda: ${pivpnSEARCHDOMAIN}" "${r}" "${c}"; then
            DomainSettingsCorrect=true
          else
            # Si las configuraciones son incorrectas, el bucle continúa
            DomainSettingsCorrect=false
          fi
        else
          whiptail \
            --backtitle "Configurador PiVPN" \
            --title "Error: Dominio Inválido" --ok-button "Reintentar" \
            --msgbox "El dominio introducido no tiene un formato válido. \
Por favor, comprueba la sintaxis e inténtalo de nuevo.

Texto detectado:
  • Dominio: ${pivpnSEARCHDOMAIN:-(Vacío)}" "${r}" "${c}"
          DomainSettingsCorrect=false
        fi
      else
        err "::: Cancelación seleccionada. Saliendo..."
        exit 1
      fi
    done
  fi

  echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
}

askPublicIPOrDNS() {
  # 1. Obtención optimizada de la IP pública con Timeouts
  if ! IPv4pub="$(dig +short +time=3 +tries=1 myip.opendns.com @208.67.222.222 2>/dev/null)" \
    || ! validIP "${IPv4pub}"; then
    err "dig falló o devolvió una IP inválida. Probando con curl..."

    if ! IPv4pub="$(curl -sSf --connect-timeout 4 https://checkip.amazonaws.com 2>/dev/null)" \
      || ! validIP "${IPv4pub}"; then
      err "No se pudo determinar tu IP pública. Verifica tu conexión a Internet o DNS."
      exit 1
    fi
  fi

  # 2. Modo de instalación desatendida (Unattended)
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnHOST}" ]]; then
      echo "::: No se especificó HOST, usando IP pública detectada: ${IPv4pub}"
      pivpnHOST="${IPv4pub}"
    else
      if validIP "${pivpnHOST}"; then
        echo "::: Usando IP pública configurada: ${pivpnHOST}"
      elif validDomain "${pivpnHOST}"; then
        echo "::: Usando nombre de dominio configurado: ${pivpnHOST}"
      else
        err "::: '${pivpnHOST}' no es una IP o nombre de dominio válido."
        exit 1
      fi
    fi

    echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"
    return
  fi

  # 3. Modo Interactivo (Inicialización explícita de variables)
  local publicDNSCorrect=false
  local publicDNSValid=false

  if METH="$(whiptail \
    --backtitle "Configurador PiVPN" \
    --title "Método de Conexión" --ok-button "Seleccionar" --cancel-button "Salir" \
    --radiolist "¿Qué método usarán los clientes para conectarse a tu servidor VPN? \
(Usa la barra espaciadora para marcar tu opción)." "${r}" "${c}" 2 \
    "${IPv4pub}" "Usar esta dirección IP pública detectada" "ON" \
    "DNS Entry" "Usar un nombre de dominio (DDNS / DNS público)" "OFF" \
    3>&1 1>&2 2>&3)"; then

    if [[ "${METH}" == "${IPv4pub}" ]]; then
      pivpnHOST="${IPv4pub}"
    else
      # Bucle principal de validación del dominio personalizado
      until [[ "${publicDNSCorrect}" == 'true' ]]; do
        # Reinicio explícito del estado del bucle interno para evitar saltos lógicos
        publicDNSValid=false
        
        until [[ "${publicDNSValid}" == 'true' ]]; do
          if PUBLICDNS="$(whiptail \
            --backtitle "Configurador PiVPN" \
            --title "Configuración de Dominio" --ok-button "Continuar" --cancel-button "Cancelar" \
            --inputbox "Introduce el nombre de dominio público o DDNS para este servidor.

Ejemplo: midominio.com" "${r}" "${c}" \
            3>&1 1>&2 2>&3)"; then
            
            if validDomain "${PUBLICDNS}"; then
              publicDNSValid=true
              pivpnHOST="${PUBLICDNS}"
            else
              whiptail \
                --backtitle "Configurador PiVPN" \
                --title "Error: Dominio Inválido" --ok-button "Reintentar" \
                --msgbox "El nombre DNS introducido no tiene un formato válido. \
Por favor, comprueba la sintaxis e inténtalo de nuevo.

Texto detectado:
  • Nombre DNS: ${PUBLICDNS:-(Vacío)}" "${r}" "${c}"
              publicDNSValid=false
            fi
          else
            err "::: Cancelación seleccionada por el usuario. Saliendo..."
            exit 1
          fi
        done

        # Pantalla de confirmación final
        if whiptail \
          --backtitle "Configurador PiVPN" \
          --title "Confirmar Nombre DNS" --yes-button "Confirmar" --no-button "Modificar" \
          --yesno "¿Es correcto el dominio para tus clientes?

  • DNS Público: ${PUBLICDNS}" "${r}" "${c}"; then
          publicDNSCorrect=true
        else
          publicDNSCorrect=false
          # Al poner esto en false, obligamos a que el bucle 'until' interno vuelva a ejecutarse
          publicDNSValid=false 
        fi
      done
    fi
  else
    err "::: Cancelación seleccionada por el usuario. Saliendo..."
    exit 1
  fi

  # Guardar la variable final en el archivo de configuración
  echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"
}

askEncryption() {
  # Inicializamos por defecto para evitar variables vacías en el volcado final
  USE_PREDEFINED_DH_PARAM=0

  # ==========================================
  # 1. MODO DESATENDIDO (UNATTENDED)
  # ==========================================
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${TWO_POINT_FIVE}" ]] || [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
      TWO_POINT_FIVE=1
      echo "::: Usando funciones modernas de OpenVPN 2.5 (ECDSA)"

      if [[ -z "${pivpnENCRYPT}" ]]; then
        pivpnENCRYPT=256
      fi

      if [[ "${pivpnENCRYPT}" -eq 256 ]] \
        || [[ "${pivpnENCRYPT}" -eq 384 ]] \
        || [[ "${pivpnENCRYPT}" -eq 521 ]]; then
        echo "::: Usando un certificado de ${pivpnENCRYPT} bits"
      else
        err "::: ${pivpnENCRYPT} no es un tamaño de certificado ECDSA válido. Usa 256, 384 o 521."
        exit 1
      fi
    else
      TWO_POINT_FIVE=0
      echo "::: Usando configuración tradicional de OpenVPN (RSA)"

      if [[ -z "${pivpnENCRYPT}" ]]; then
        pivpnENCRYPT=2048
      fi

      if [[ "${pivpnENCRYPT}" -eq 2048 ]] \
        || [[ "${pivpnENCRYPT}" -eq 3072 ]] \
        || [[ "${pivpnENCRYPT}" -eq 4096 ]]; then
        echo "::: Usando un certificado de ${pivpnENCRYPT} bits"
      else
        err "::: ${pivpnENCRYPT} no es un tamaño de certificado RSA válido. Usa 2048, 3072 o 4096."
        exit 1
      fi

      if [[ -z "${USE_PREDEFINED_DH_PARAM}" ]]; then
        USE_PREDEFINED_DH_PARAM=1
      fi

      if [[ "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
        echo "::: Se usarán parámetros DH predefinidos"
      else
        echo "::: Los parámetros DH se generarán localmente"
      fi
    fi

    {
      echo "TWO_POINT_FIVE=${TWO_POINT_FIVE}"
      echo "pivpnENCRYPT=${pivpnENCRYPT}"
      echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  # ==========================================
  # 2. MODO INTERACTIVO POR DEFECTO (SIN PERSONALIZAR)
  # ==========================================
  if [[ "${CUSTOMIZE}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
      TWO_POINT_FIVE=1
      pivpnENCRYPT=256
      USE_PREDEFINED_DH_PARAM=0 # Aseguramos valor por defecto limpio

      {
        echo "TWO_POINT_FIVE=${TWO_POINT_FIVE}"
        echo "pivpnENCRYPT=${pivpnENCRYPT}"
        echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
      } >> "${tempsetupVarsFile}"
      return
    fi
  fi

  # ==========================================
  # 3. MODO INTERACTIVO PERSONALIZADO (CUSTOM)
  # ==========================================
  
  # Pantalla 1: Selección del tipo de cifrado (ECDSA vs RSA)
  whiptail \
    --backtitle "Configurador PiVPN" \
    --title "Motor de Cifrado (Curvas Elípticas vs RSA)" --yes-button "Moderno (ECDSA)" --no-button "Tradicional (RSA)" \
    --yesno "OpenVPN 2.5 permite utilizar criptografía de Curvas Elípticas (ECDSA).

• Nivel Moderno: Ofrece mayor velocidad, seguridad superior y certificados más ligeros. Además, cifra el canal de control (tls-crypt-v2) para maximizar la privacidad.
• Nivel Tradicional: Utiliza RSA. Garantiza compatibilidad total con clientes OpenVPN antiguos a costa de un rendimiento ligeramente menor.

Si tus dispositivos cliente son recientes, te recomendamos el perfil Moderno." "${r}" "${c}"
  
  crypto_choice="$?"

  # Manejo estricto de cancelación global o Esc en la primera pantalla
  if [[ "${crypto_choice}" -eq 255 ]]; then
    err "::: Instalación cancelada por el usuario. Saliendo..."
    exit 1
  fi

  if [[ "${crypto_choice}" -eq 0 ]]; then
    # --- PERFIL MODERNO (ECDSA) ---
    TWO_POINT_FIVE=1
    USE_PREDEFINED_DH_PARAM=0 # ECDSA no requiere Diffie-Hellman
    
    pivpnENCRYPT="$(whiptail \
      --backtitle "Configurador PiVPN" \
      --title "Tamaño del Certificado ECDSA" \
      --ok-button "Seleccionar" \
      --cancel-button "Cancelar" \
      --radiolist "Elige la longitud de clave para tu certificado ECDSA \
(Usa la barra espaciadora para marcar tu opción):

Nota: Una clave de 256 bits equivale en seguridad a una clave RSA de 3072 bits, \
siendo drásticamente más rápida." "${r}" "${c}" 3 \
      "256" "Certificado de 256 bits (Recomendado por rendimiento)" ON \
      "384" "Certificado de 384 bits (Seguridad avanzada)" OFF \
      "521" "Certificado de 521 bits (Máxima seguridad militar)" OFF \
      3>&1 1>&2 2>&3)"
  else
    # --- PERFIL TRADICIONAL (RSA) ---
    TWO_POINT_FIVE=0
    
    pivpnENCRYPT="$(whiptail \
      --backtitle "Configurador PiVPN" \
      --title "Tamaño del Certificado RSA" --ok-button "Seleccionar" --cancel-button "Cancelar" \
      --radiolist "Elige la longitud de clave para tu certificado RSA \
(Usa la barra espaciadora para marcar tu opción):

A mayor tamaño de clave, mayor seguridad, pero aumentará el tiempo \
de procesamiento durante la instalación." "${r}" "${c}" 3 \
      "2048" "Certificado de 2048 bits (Estándar recomendado)" ON \
      "3072" "Certificado de 3072 bits (Seguridad reforzada)" OFF \
      "4096" "Certificado de 4096 bits (Alta seguridad / Procesamiento lento)" OFF \
      3>&1 1>&2 2>&3)"
  fi

  # Validamos si el usuario canceló en cualquiera de las sublistas de radio
  if [[ $? -ne 0 ]] || [[ -z "${pivpnENCRYPT}" ]]; then
    err "::: Operación cancelada. Saliendo..."
    exit 1
  fi

  # --- CONFIGURACIÓN DIFFIE-HELLMAN (Solo aplica para RSA) ---
  if [[ "${pivpnENCRYPT}" -ge 2048 ]]; then
    if whiptail \
      --backtitle "Configurador PiVPN" \
      --title "Parámetros Diffie-Hellman" \
      --yes-button "Sí, predefinidos" \
      --no-button "No, generar nuevos" \
      --yesno "La generación local de parámetros DH puede demorar varias horas en entornos como Raspberry Pi.

¿Deseas utilizar los parámetros DH predefinidos y validados por la IETF (Recomendado)?

Si prefieres generar parámetros Diffie-Hellman únicos en este hardware, selecciona 'No'." "${r}" "${c}"; then
      USE_PREDEFINED_DH_PARAM=1
    else
      USE_PREDEFINED_DH_PARAM=0
    fi
  fi

  # Volcado limpio de variables de entorno al archivo temporal
  {
    echo "TWO_POINT_FIVE=${TWO_POINT_FIVE}"
    echo "pivpnENCRYPT=${pivpnENCRYPT}"
    echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
  } >> "${tempsetupVarsFile}"
}

confOpenVPN() {
  local sed_pattern file_pattern

  # Obtener el nombre de host existente
  host_name="$(hostname -s)"
  # Generar un UUID aleatorio para este servidor para que podamos usar
  # verify-x509-name más adelante que sea único para esta
  # instalación.
  NEW_UUID="$(< /proc/sys/kernel/random/uuid)"
  # Crear un nombre de servidor único usando el nombre de host y UUID
  SERVER_NAME="${host_name}_${NEW_UUID}"

  # Hacer copia de seguridad de la carpeta openvpn
  OPENVPN_BACKUP="openvpn_$(date +%Y-%m-%d-%H%M%S).tar.gz"
  echo "::: Generando respaldo de la configuración anterior en /etc/${OPENVPN_BACKUP}..."
  CURRENT_UMASK="$(umask)"
  umask 0077
  ${SUDO} tar -czf "/etc/${OPENVPN_BACKUP}" /etc/openvpn &> /dev/null
  umask "${CURRENT_UMASK}"

  if [[ -f /etc/openvpn/server.conf ]]; then
    ${SUDO} rm /etc/openvpn/server.conf
  fi

  if [[ -d /etc/openvpn/ccd ]]; then
    ${SUDO} rm -rf /etc/openvpn/ccd
  fi

  # Crear carpeta para almacenar directivas específicas del cliente usadas para empujar IPs estáticas
  ${SUDO} mkdir /etc/openvpn/ccd

  # Si easy-rsa existe, eliminarlo
  if [[ -d /etc/openvpn/easy-rsa/ ]]; then
    ${SUDO} rm -rf /etc/openvpn/easy-rsa/
  fi

  # Obtener easy-rsa
  curl -sSfL "${easyrsaRel}" \
    | ${SUDO} tar -xz --one-top-level=/etc/openvpn/easy-rsa --strip-components 1

  if [[ ! -s /etc/openvpn/easy-rsa/easyrsa ]]; then
    err "${0}: ERR: Fallo al descargar EasyRSA."
    exit 1
  fi

  # arreglar propiedad
  ${SUDO} chown -R root:root /etc/openvpn/easy-rsa
  ${SUDO} mkdir /etc/openvpn/easy-rsa/pki
  ${SUDO} chmod 700 /etc/openvpn/easy-rsa/pki

  cd /etc/openvpn/easy-rsa || exit 1

  if [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
    pivpnCERT="ec"
    pivpnTLSVERS="1.3"
    pivpnTLSPROT="tls-crypt-v2"
  else
    pivpnCERT="rsa"
    pivpnTLSVERS="1.2"
    pivpnTLSPROT="tls-auth"
  fi

  # Eliminar cualquier clave anterior
  ${SUDOE} ./easyrsa --batch init-pki

  # Copiar archivo de variables de plantilla
  ${SUDOE} cp vars.example pki/vars

  # Establecer certificado de curva elíptica o certificados rsa tradicionales
  ${SUDOE} sed -i \
    "s/#set_var EASYRSA_ALGO.*/set_var EASYRSA_ALGO ${pivpnCERT}/" \
    pki/vars

  # Establecer expiración para la CRL a 10 años
  ${SUDOE} sed -i \
    's/#set_var EASYRSA_CRL_DAYS.*/set_var EASYRSA_CRL_DAYS 3650/' \
    pki/vars

  if [[ "${pivpnENCRYPT}" -ge 2048 ]]; then
    # Establecer tamaño de clave personalizado si es diferente al predeterminado
    sed_pattern="s/#set_var EASYRSA_KEY_SIZE.*/"
    sed_pattern="${sed_pattern} set_var EASYRSA_KEY_SIZE ${pivpnENCRYPT}/"
    ${SUDOE} sed -i "${sed_pattern}" pki/vars
  else
    # Si es menor a 2048, entonces debe ser 521 o inferior,
    # lo que significa que se seleccionó un certificado de curva elíptica.
    # Establecemos la curva en este caso.
    declare -A ECDSA_MAP=(["256"]="prime256v1"
      ["384"]="secp384r1"
      ["521"]="secp521r1")

    sed_pattern="s/#set_var EASYRSA_CURVE.*/"
    sed_pattern="${sed_pattern} set_var EASYRSA_CURVE"
    sed_pattern="${sed_pattern} ${ECDSA_MAP["${pivpnENCRYPT}"]}/"
    ${SUDOE} sed -i "${sed_pattern}" pki/vars
  fi

  # Construir la autoridad de certificación
  printf "::: Construyendo CA...\\n"
  ${SUDOE} ./easyrsa --batch build-ca nopass
  printf "\\n::: CA Completada.\\n"

  if [[ "${pivpnCERT}" == "rsa" ]] \
    && [[ "${USE_PREDEFINED_DH_PARAM}" -ne 1 ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      echo "::: La clave del servidor, los parámetros Diffie-Hellman, \
y la clave HMAC se generarán ahora."
    else
      whiptail \
        --msgbox \
        --backtitle "Configurar OpenVPN" \
        --title "Información del Servidor" --ok-button "Aceptar" \
        "La clave del servidor, los parámetros Diffie-Hellman, \
y la clave HMAC se generarán ahora." \
        "${r}" \
        "${c}"
    fi
  elif [[ "${pivpnCERT}" == "ec" ]] \
    || [[ "${pivpnCERT}" == "rsa" && "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      echo "::: La clave del servidor y la clave HMAC se generarán ahora."
    else
      whiptail \
        --msgbox \
  --backtitle "Configuración de Seguridad" \
  --title "Generación de Llaves Criptográficas" --ok-button "Continuar" \
  "El instalador procederá a generar las llaves de cifrado del servidor y la firma de seguridad HMAC. 

Este proceso es automático y garantiza que tu conexión VPN sea privada y segura. Por favor, espera un momento mientras se completan las operaciones criptográficas." "${r}" "${c}"
    fi
  fi

  # Construir el servidor
  EASYRSA_CERT_EXPIRE=3650 ${SUDOE} \
    ./easyrsa --batch build-server-full "${SERVER_NAME}" nopass

  if [[ "${pivpnCERT}" == "rsa" ]]; then
    if [[ "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
      file_pattern="${pivpnFilesDir}/files/etc/openvpn"
      file_pattern="${file_pattern}/easy-rsa/pki/ffdhe${pivpnENCRYPT}.pem"
      # Usar parámetros Diffie-Hellman del RFC 7919 (FFDHE)
      ${SUDOE} install -m 644 "${file_pattern}" \
        "pki/dh${pivpnENCRYPT}.pem"
    else
      # Generar intercambio de claves Diffie-Hellman
      ${SUDOE} ./easyrsa gen-dh
      ${SUDOE} mv pki/dh.pem "pki/dh${pivpnENCRYPT}".pem
    fi
  fi

  # Generar clave HMAC estática para defenderse contra DDoS
  if [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
    ${SUDOE} mkdir -p "/etc/openvpn/easy-rsa/pki/tc-v2"
    ${SUDOE} openvpn --genkey tls-crypt-v2-server pki/tc-v2/server.key
  else
    ${SUDOE} openvpn --genkey tls-auth pki/ta.key
  fi

  # Generar una Lista de Revocación de Certificados vacía
  ${SUDOE} ./easyrsa gen-crl
  ${SUDOE} cp pki/crl.pem /etc/openvpn/crl.pem

  if ! getent passwd "${ovpnUserGroup%:*}"; then
    if [[ "${PLAT}" == 'Alpine' ]]; then
      ${SUDOE} adduser -SD \
        -h /var/lib/openvpn/ \
        -s /sbin/nologin \
        "${ovpnUserGroup%:*}"
    else
      ${SUDOE} useradd \
        --system \
        --home /var/lib/openvpn/ \
        --shell /usr/sbin/nologin \
        "${ovpnUserGroup%:*}"
    fi
  fi

  ${SUDOE} chown "${ovpnUserGroup}" /etc/openvpn/crl.pem

  # Escribir el archivo de configuración para el servidor usando el archivo template.txt
  ${SUDO} install -m 644 \
    "${pivpnFilesDir}/files/etc/openvpn/server_config.txt" \
    /etc/openvpn/server.conf

  # Aplicar configuraciones DNS del cliente
  ${SUDOE} sed -i \
    "0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1${pivpnDNS1}\"/" \
    /etc/openvpn/server.conf

  if [[ -z "${pivpnDNS2}" ]]; then
    ${SUDOE} sed -i '/\(dhcp-option DNS \)/{n;N;d}' /etc/openvpn/server.conf
  else
    ${SUDOE} sed -i \
      "0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1${pivpnDNS2}\"/" \
      /etc/openvpn/server.conf
  fi

  # Establecer el tamaño de la clave de encriptación del usuario
  ${SUDO} sed -i \
    "s#\\(dh /etc/openvpn/easy-rsa/pki/dh\\).*#\\1${pivpnENCRYPT}.pem#" \
    /etc/openvpn/server.conf

  if [[ "${pivpnTLSPROT}" == "tls-crypt-v2" ]]; then
    # Si habilitaron 2.5 usar tls-crypt-v2 en lugar de tls-auth para cifrar el canal de control
    ta_path="/etc/openvpn/easy-rsa/pki/ta.key"
    tc_v2_path="/etc/openvpn/easy-rsa/pki/tc-v2/server.key"
    tc_v2_cmd_path="/opt/pivpn/openvpn/TLSCryptV2Verify.sh"
    sed_pattern='s|tls-auth '"${ta_path}"' 0|tls-crypt-v2 '"${tc_v2_path}"'\ntls-crypt-v2-verify '"${tc_v2_cmd_path}"'\nscript-security 2|'
    ${SUDO} sed -i "${sed_pattern}" /etc/openvpn/server.conf
  fi

  if [[ "${pivpnCERT}" == "ec" ]]; then
    # Si habilitaron 2.5 deshabilitar parámetros dh y especificar la
    # curva coincidente del certificado ECDSA
    sed_pattern="s/\(dh \/etc\/openvpn\/easy-rsa\/pki\/dh\).*/dh"
    sed_pattern="${sed_pattern} none\necdh-curve"
    sed_pattern="${sed_pattern} ${ECDSA_MAP["${pivpnENCRYPT}"]}/"
    ${SUDO} sed -i \
      "${sed_pattern}" \
      /etc/openvpn/server.conf
  elif [[ "${pivpnCERT}" == "rsa" ]]; then
    # De lo contrario, establecer el tamaño de la clave de encriptación del usuario
    ${SUDO} sed -i \
      "s#\\(dh /etc/openvpn/easy-rsa/pki/dh\\).*#\\1${pivpnENCRYPT}.pem#" \
      /etc/openvpn/server.conf
  fi

  # Aumentar la versión mínima de TLS para limitar las suites de cifrado, reduciendo la superficie de ataque
  if [[ "${pivpnTLSVERS}" == "1.3" ]]; then
    ${SUDO} sed -i "s|tls-version-min 1.2|tls-version-min 1.3|" "/etc/openvpn/server.conf"
    ${SUDO} sed -i "s|tls-version-min 1.2|tls-version-min 1.3|" "${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/Default.txt"
  fi

  # si modificaron la red VPN, poner el valor en server.conf
  if [[ "${pivpnNET}" != "10.8.0.0" ]]; then
    ${SUDO} sed -i "s/10.8.0.0/${pivpnNET}/g" /etc/openvpn/server.conf
  fi

  # si modificaron la clase de subred VPN, poner el valor en server.conf
  if [[ "$(cidrToMask "${subnetClass}")" != "255.255.255.0" ]]; then
    ${SUDO} sed -i \
      "s/255.255.255.0/$(cidrToMask "${subnetClass}")/g" \
      /etc/openvpn/server.conf
  fi

  # si modificaron el puerto, poner el valor en server.conf
  if [[ "${pivpnPORT}" -ne 1194 ]]; then
    ${SUDO} sed -i "s/1194/${pivpnPORT}/g" /etc/openvpn/server.conf
  fi

  # si modificaron el protocolo, poner el valor en server.conf
  if [[ "${pivpnPROTO}" != "udp" ]]; then
    ${SUDO} sed -i "s/proto udp/proto tcp/g" /etc/openvpn/server.conf
  fi

  if [[ -n "${pivpnSEARCHDOMAIN}" ]]; then
    sed_pattern="0,/\\(.*dhcp-option.*\\)/"
    sed_pattern="${sed_pattern}s//push \"dhcp-option "
    sed_pattern="${sed_pattern}DOMAIN ${pivpnSEARCHDOMAIN}\" \\n&/"
    ${SUDO} sed -i \
      "${sed_pattern}" \
      /etc/openvpn/server.conf
  fi

  # escribir los certificados del servidor en el archivo conf
  ${SUDO} sed -i \
    "s#\\(key /etc/openvpn/easy-rsa/pki/private/\\).*#\\1${SERVER_NAME}.key#" \
    /etc/openvpn/server.conf
  ${SUDO} sed -i \
    "s#\\(cert /etc/openvpn/easy-rsa/pki/issued/\\).*#\\1${SERVER_NAME}.crt#" \
    /etc/openvpn/server.conf

  # En Alpine Linux, el archivo de configuración predeterminado para OpenVPN es
  # "/etc/openvpn/openvpn.conf".
  # Para evitar fallos a través de OpenRC, creamos un enlace simbólico a este archivo.
  if [[ "${PLAT}" == 'Alpine' ]]; then
    ${SUDO} ln -sfT \
      /etc/openvpn/server.conf \
      /etc/openvpn/openvpn.conf \
      > /dev/null
  fi
}

confOVPN() {
  ${SUDO} install -m 644 \
    "${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/Default.txt" \
    /etc/openvpn/easy-rsa/pki/Default.txt

  ${SUDO} sed -i \
    "s/IPv4pub/${pivpnHOST}/" \
    /etc/openvpn/easy-rsa/pki/Default.txt

  # si modificaron el puerto, poner el valor en Default.txt para que lo usen los clientes
  if [[ "${pivpnPORT}" -ne 1194 ]]; then
    ${SUDO} sed -i \
      "s/1194/${pivpnPORT}/g" \
      /etc/openvpn/easy-rsa/pki/Default.txt
  fi

  # si modificaron el protocolo, poner el valor en Default.txt para que lo usen los clientes
  if [[ "${pivpnPROTO}" != "udp" ]]; then
    ${SUDO} sed -i \
      "s/proto udp/proto tcp/g" \
      /etc/openvpn/easy-rsa/pki/Default.txt
  fi

  # verificar el nombre del servidor para fortalecer la seguridad
  ${SUDO} sed -i \
    "s/SRVRNAME/${SERVER_NAME}/" \
    /etc/openvpn/easy-rsa/pki/Default.txt

  if [[ "${pivpnTLSPROT}" == "tls-crypt-v2" ]]; then
    # Si habilitaron 2.5, eliminar las opciones de key-direction ya que no son necesarias
    ${SUDO} sed -i \
      "/key-direction 1/d" \
      /etc/openvpn/easy-rsa/pki/Default.txt
  fi
}

confWireGuard() {
  # El tipo de trabajo de recarga aún no está disponible en wireguard-tools incluido con
  # Ubuntu 20.04
  if [[ "${PLAT}" == 'Alpine' ]]; then
    echo '::: Añadiendo unidad wg-quick'
    ${SUDO} install -m 0755 \
      "${pivpnFilesDir}/files/etc/init.d/wg-quick" \
      /etc/init.d/wg-quick
  else
    if ! grep -q 'ExecReload' /lib/systemd/system/wg-quick@.service; then
      local wireguard_service_path
      wireguard_service_path="${pivpnFilesDir}/files/etc/systemd/system"
      wireguard_service_path="${wireguard_service_path}/wg-quick@.service.d"
      wireguard_service_path="${wireguard_service_path}/override.conf"
      echo "::: Añadiendo tipo de trabajo de recarga adicional para la unidad wg-quick"
      ${SUDO} install -Dm 644 \
        "${wireguard_service_path}" \
        /etc/systemd/system/wg-quick@.service.d/override.conf
      ${SUDO} systemctl daemon-reload
    fi
  fi

  if [[ -d /etc/wireguard ]]; then
    if [[ -n "$(${SUDO} ls -A /etc/wireguard)" ]]; then
      # Hacer copia de seguridad de la carpeta wireguard
      WIREGUARD_BACKUP="wireguard_$(date +%Y-%m-%d-%H%M%S).tar.gz"
      echo "::: Generando respaldo de la configuración anterior en /etc/${WIREGUARD_BACKUP}..."
      CURRENT_UMASK="$(umask)"
      umask 0077
      ${SUDO} tar -czf "/etc/${WIREGUARD_BACKUP}" /etc/wireguard &> /dev/null
      umask "${CURRENT_UMASK}"
    fi

    if [[ -f /etc/wireguard/wg0.conf ]]; then
      ${SUDO} rm /etc/wireguard/wg0.conf
    fi
  else
    # Si se compiló desde el código fuente, la carpeta wireguard no se crea
    ${SUDO} mkdir /etc/wireguard
  fi

  # Asegurar que solo root pueda entrar a la carpeta wireguard
  ${SUDO} chown root:root /etc/wireguard
  ${SUDO} chmod 700 /etc/wireguard

  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: Se generarán ahora las claves del servidor."
  else
    whiptail \
      --title "Información del Servidor" --ok-button "Aceptar" \
      --msgbox "Se generarán ahora las claves del servidor." \
      "${r}" \
      "${c}"
  fi

  # Eliminar las carpetas de configuraciones y claves para hacer espacio para un nuevo servidor al
  # usar 'Reparar' o 'Reconfigurar' sobre una instalación existente
  ${SUDO} rm -rf /etc/wireguard/configs
  ${SUDO} rm -rf /etc/wireguard/keys

  ${SUDO} mkdir -p /etc/wireguard/configs
  ${SUDO} touch /etc/wireguard/configs/clients.txt
  ${SUDO} mkdir -p /etc/wireguard/keys

  # Generar clave privada y derivar la clave pública de ella
  wg genkey \
    | ${SUDO} tee /etc/wireguard/keys/server_priv &> /dev/null
  ${SUDO} cat /etc/wireguard/keys/server_priv \
    | wg pubkey \
    | ${SUDO} tee /etc/wireguard/keys/server_pub &> /dev/null

  echo "::: Se han generado las claves del servidor."

  {
    echo '[Interface]'
    echo "PrivateKey = $(${SUDO} cat /etc/wireguard/keys/server_priv)"
    echo -n "Address = ${vpnGw}/${subnetClass}"

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      echo ",${vpnGwv6}/${subnetClassv6}"
    else
      echo
    fi

    echo "MTU = ${pivpnMTU}"
    echo "ListenPort = ${pivpnPORT}"
  } | ${SUDO} tee /etc/wireguard/wg0.conf &> /dev/null

  echo "::: Configuración del servidor generada."
}

confNetwork() {
  # Habilitar el reenvío de tráfico de internet
  echo 'net.ipv4.ip_forward=1' \
    | ${SUDO} tee /etc/sysctl.d/99-pivpn.conf > /dev/null

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    {
      echo "net.ipv6.conf.all.forwarding=1"
      echo "net.ipv6.conf.${IPv6dev}.accept_ra=2"
    } | ${SUDO} tee -a /etc/sysctl.d/99-pivpn.conf > /dev/null
  fi

  ${SUDO} sysctl -p /etc/sysctl.d/99-pivpn.conf > /dev/null

  if [[ "${PLAT}" == 'Alpine' ]]; then
	${SUDO} rc-update add sysctl
  fi

  if [[ "${USING_UFW}" -eq 1 ]]; then
    echo "::: Se detectó que UFW está habilitado."
    echo "::: Añadiendo reglas de UFW..."

    ### Salvaguarda básica: si el archivo está vacío, algo raro ha estado
    ### pasando.
    ### Nota: no hay salvaguarda contra contenido incompleto como resultado de fallos
    ### previos.
    if [[ -s /etc/ufw/before.rules ]]; then
      ${SUDO} cp -f /etc/ufw/before.rules /etc/ufw/before.rules.pre-pivpn
    else
      err "${0}: ERR: Lo siento, no tocaré el archivo vacío \"/etc/ufw/before.rules\"."
      exit 1
    fi

    if [[ -s /etc/ufw/before6.rules ]]; then
      ${SUDO} cp -f /etc/ufw/before6.rules /etc/ufw/before6.rules.pre-pivpn
    else
      err "${0}: ERR: Lo siento, no tocaré el archivo vacío \"/etc/ufw/before6.rules\"."
      exit 1
    fi

    ### Si ya hay una sección "*nat", solo añadimos nuestro POSTROUTING MASQUERADE
    if ${SUDO} grep -q "*nat" /etc/ufw/before.rules; then
      local sed_pattern

      ### Solo añadir la regla NAT IPv4 si no está ya ahí
      if ! ${SUDO} grep -q "${VPN}-nat-rule" /etc/ufw/before.rules; then
        sed_pattern="/^*nat/{n;"
        sed_pattern="${sed_pattern}s/\(:POSTROUTING ACCEPT .*\)/"
        sed_pattern="${sed_pattern}\1\n-I POSTROUTING"
        sed_pattern="${sed_pattern} -s ${pivpnNET}\/${subnetClass}"
        sed_pattern="${sed_pattern} -o ${IPv4dev}"
        sed_pattern="${sed_pattern} -j MASQUERADE"
        sed_pattern="${sed_pattern} -m comment"
        sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule/"
        sed_pattern="${sed_pattern}}"
        ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before.rules
      fi
    else
      sed_pattern="/delete these required/i"
      sed_pattern="${sed_pattern} *nat\n:POSTROUTING ACCEPT [0:0]\n"
      sed_pattern="${sed_pattern}-I POSTROUTING"
      sed_pattern="${sed_pattern} -s ${pivpnNET}\/${subnetClass}"
      sed_pattern="${sed_pattern} -o ${IPv4dev}"
      sed_pattern="${sed_pattern} -j MASQUERADE"
      sed_pattern="${sed_pattern} -m comment"
      sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule\n"
      sed_pattern="${sed_pattern}COMMIT\n"
      ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before.rules
    fi

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      local sed_pattern

      if ${SUDO} grep -q "*nat" /etc/ufw/before6.rules; then
        ### Solo añadir la regla NAT IPv6 si no está ya ahí
        if ! ${SUDO} grep -q "${VPN}-nat-rule" /etc/ufw/before6.rules; then
          sed_pattern="/^*nat/{n;"
          sed_pattern="${sed_pattern}s/\(:POSTROUTING ACCEPT .*\)/"
          sed_pattern="${sed_pattern}\1\n-I POSTROUTING"
          sed_pattern="${sed_pattern} -s ${pivpnNETv6}\/${subnetClassv6}"
          sed_pattern="${sed_pattern} -o ${IPv6dev}"
          sed_pattern="${sed_pattern} -j MASQUERADE"
          sed_pattern="${sed_pattern} -m comment"
          sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule/"
          sed_pattern="${sed_pattern}}"
          ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before6.rules
        fi
      else
        sed_pattern="/delete these required/i"
        sed_pattern="${sed_pattern} *nat\n:POSTROUTING ACCEPT [0:0]\n"
        sed_pattern="${sed_pattern}-I POSTROUTING"
        sed_pattern="${sed_pattern} -s ${pivpnNETv6}\/${subnetClassv6}"
        sed_pattern="${sed_pattern} -o ${IPv6dev}"
        sed_pattern="${sed_pattern} -j MASQUERADE"
        sed_pattern="${sed_pattern} -m comment"
        sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule\n"
        sed_pattern="${sed_pattern}COMMIT\n"
        ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before6.rules
      fi
    fi

    # Comprueba si hay reglas UFW existentes e
    # inserta reglas al principio de la cadena
    # (en caso de que haya otras reglas que puedan descartar el tráfico)
    if ${SUDO} ufw status numbered | grep -E "\[.[0-9]{1}\]" > /dev/null; then
      ${SUDO} ufw insert 1 \
        allow "${pivpnPORT}/${pivpnPROTO}" \
        comment "allow-${VPN}" > /dev/null

      ${SUDO} ufw route insert 1 \
        allow in on "${pivpnDEV}" \
        from "${pivpnNET}/${subnetClass}" \
        out on "${IPv4dev}" to any > /dev/null

      if [[ "${pivpnenableipv6}" -eq 1 ]]; then
        ${SUDO} ufw route \
          allow in on "${pivpnDEV}" \
          from "${pivpnNETv6}/${subnetClassv6}" \
          out on "${IPv6dev}" to any > /dev/null
      fi
    fi

    ${SUDO} ufw reload > /dev/null
    echo "::: Configuración de UFW completada."
    return
  fi

  # Ahora algunas comprobaciones para detectar qué reglas necesitamos añadir.
  # En un sistema recién instalado, todas las políticas deberían ser ACCEPT,
  # por lo que la única regla requerida sería la de MASQUERADE.

  if ! ${SUDO} iptables -t nat -S \
    | grep -q "${VPN}-nat-rule"; then
    ${SUDO} iptables \
      -t nat \
      -I POSTROUTING \
      -s "${pivpnNET}/${subnetClass}" \
      -o "${IPv4dev}" \
      -j MASQUERADE \
      -m comment \
      --comment "${VPN}-nat-rule"
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if ! ${SUDO} ip6tables -t nat -S \
      | grep -q "${VPN}-nat-rule"; then
      ${SUDO} ip6tables \
        -t nat \
        -I POSTROUTING \
        -s "${pivpnNETv6}/${subnetClassv6}" \
        -o "${IPv6dev}" \
        -j MASQUERADE \
        -m comment \
        --comment "${VPN}-nat-rule"
    fi
  fi

  # Cuenta cuántas reglas hay en la cadena INPUT y FORWARD.
  # Al analizar la entrada de iptables -S, '^-P' omite las políticas
  # y 'ufw-' omite las cadenas ufw (en caso de que se encontrara ufw
  # instalado pero no habilitado).

  # Grep devuelve un código de salida distinto de 0 donde no hay coincidencias,
  # sin embargo, eso haría que el script saliera,
  # por estas razones usamos '|| true' para forzar el código de salida 0
  INPUT_RULES_COUNT="$(${SUDO} iptables -S INPUT \
    | grep -vcE '(^-P|ufw-)')"
  FORWARD_RULES_COUNT="$(${SUDO} iptables -S FORWARD \
    | grep -vcE '(^-P|ufw-)')"
  INPUT_POLICY="$(${SUDO} iptables -S INPUT \
    | grep '^-P' \
    | awk '{print $3}')"
  FORWARD_POLICY="$(${SUDO} iptables -S FORWARD \
    | grep '^-P' \
    | awk '{print $3}')"

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    INPUT_RULES_COUNTv6="$(${SUDO} ip6tables -S INPUT \
      | grep -vcE '(^-P|ufw-)')"
    FORWARD_RULES_COUNTv6="$(${SUDO} ip6tables -S FORWARD \
      | grep -vcE '(^-P|ufw-)')"
    INPUT_POLICYv6="$(${SUDO} ip6tables -S INPUT \
      | grep '^-P' \
      | awk '{print $3}')"
    FORWARD_POLICYv6="$(${SUDO} ip6tables -S FORWARD \
      | grep '^-P' \
      | awk '{print $3}')"
  fi

  # Si el recuento de reglas no es cero, asumimos que necesitamos permitir explícitamente el tráfico.
  # Misma conclusión si no hay reglas y la política no es ACCEPT.
  # Ten en cuenta que las reglas se añaden a la parte superior de la cadena (usando -I).

  if [[ "${INPUT_RULES_COUNT}" -ne 0 ]] \
    || [[ "${INPUT_POLICY}" != "ACCEPT" ]]; then
    if ! ${SUDO} iptables -S \
      | grep -q "${VPN}-input-rule"; then
      ${SUDO} iptables \
        -I INPUT 1 \
        -i "${IPv4dev}" \
        -p "${pivpnPROTO}" \
        --dport "${pivpnPORT}" \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-input-rule"
    fi

    INPUT_CHAIN_EDITED=1
  else
    INPUT_CHAIN_EDITED=0
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if [[ "${INPUT_RULES_COUNTv6}" -ne 0 ]] \
      || [[ "${INPUT_POLICYv6}" != "ACCEPT" ]]; then
      if ! ${SUDO} ip6tables -S \
        | grep -q "${VPN}-input-rule"; then
        ${SUDO} ip6tables \
          -I INPUT 1 \
          -i "${IPv6dev}" \
          -p "${pivpnPROTO}" \
          --dport "${pivpnPORT}" \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-input-rule"
      fi

      INPUT_CHAIN_EDITEDv6=1
    else
      INPUT_CHAIN_EDITEDv6=0
    fi
  fi

  if [[ "${FORWARD_RULES_COUNT}" -ne 0 ]] \
    || [[ "${FORWARD_POLICY}" != "ACCEPT" ]]; then
    if ! ${SUDO} iptables -S \
      | grep -q "${VPN}-forward-rule"; then
      ${SUDO} iptables \
        -I FORWARD 1 \
        -d "${pivpnNET}/${subnetClass}" \
        -i "${IPv4dev}" \
        -o "${pivpnDEV}" \
        -m conntrack \
        --ctstate RELATED,ESTABLISHED \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-forward-rule"
      ${SUDO} iptables \
        -I FORWARD 2 \
        -s "${pivpnNET}/${subnetClass}" \
        -i "${pivpnDEV}" \
        -o "${IPv4dev}" \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-forward-rule"
    fi

    FORWARD_CHAIN_EDITED=1
  else
    FORWARD_CHAIN_EDITED=0
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if [[ "${FORWARD_RULES_COUNTv6}" -ne 0 ]] \
      || [[ "${FORWARD_POLICYv6}" != "ACCEPT" ]]; then
      if ! ${SUDO} ip6tables -S \
        | grep -q "${VPN}-forward-rule"; then
        ${SUDO} ip6tables \
          -I FORWARD 1 \
          -d "${pivpnNETv6}/${subnetClassv6}" \
          -i "${IPv6dev}" \
          -o "${pivpnDEV}" \
          -m conntrack \
          --ctstate RELATED,ESTABLISHED \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-forward-rule"
        ${SUDO} ip6tables \
          -I FORWARD 2 \
          -s "${pivpnNETv6}/${subnetClassv6}" \
          -i "${pivpnDEV}" \
          -o "${IPv6dev}" \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-forward-rule"
      fi

      FORWARD_CHAIN_EDITEDv6=1
    else
      FORWARD_CHAIN_EDITEDv6=0
    fi
  fi

  case "${PLAT}" in
    Debian | Raspbian | Ubuntu)
      ${SUDO} iptables-save \
        | ${SUDO} tee /etc/iptables/rules.v4 > /dev/null
      ${SUDO} ip6tables-save \
        | ${SUDO} tee /etc/iptables/rules.v6 > /dev/null
      ;;
	Alpine)
	  ${SUDO} rc-service iptables save
	  ${SUDO} rc-service ip6tables save
	  ${SUDO} rc-update add iptables
	  ${SUDO} rc-update add ip6tables
	  ;;
  esac

  {
    echo "INPUT_CHAIN_EDITED=${INPUT_CHAIN_EDITED}"
    echo "FORWARD_CHAIN_EDITED=${FORWARD_CHAIN_EDITED}"
    echo "INPUT_CHAIN_EDITEDv6=${INPUT_CHAIN_EDITEDv6}"
    echo "FORWARD_CHAIN_EDITEDv6=${FORWARD_CHAIN_EDITEDv6}"
  } >> "${tempsetupVarsFile}"
}

confLogging() {
  # Pre-crear directorios de configuración de rsyslog/logrotate si faltan,
  # para asegurar que los registros se manejen como se espera cuando estos se
  # instalen en un momento posterior
  ${SUDO} mkdir -p /etc/{rsyslog,logrotate}.d

  echo "if \$programname == 'openvpn' then /var/log/openvpn.log
if \$programname == 'openvpn' then stop" | ${SUDO} tee /etc/rsyslog.d/30-openvpn.conf > /dev/null

  echo "/var/log/openvpn.log
{
    rotate 4
    weekly
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        invoke-rc.d rsyslog rotate >/dev/null 2>&1 || true
    endscript
}" | ${SUDO} tee /etc/logrotate.d/openvpn > /dev/null

  # Reiniciar el servicio de registro
  ${SUDO} rc-service -is rsyslog restart
  ${SUDO} rc-service -iN rsyslog start
}

restartServices() {
  # Iniciar servicios
  echo "::: Reiniciando servicios..."

  case "${PLAT}" in
    Debian | Raspbian | Ubuntu)
      if [[ "${VPN}" == "openvpn" ]]; then
        ${SUDO} systemctl enable openvpn.service &> /dev/null
        ${SUDO} systemctl restart openvpn.service
      elif [[ "${VPN}" == "wireguard" ]]; then
        ${SUDO} systemctl enable wg-quick@wg0.service &> /dev/null
        ${SUDO} systemctl restart wg-quick@wg0.service
      fi

      ;;
    Alpine)
      if [[ "${VPN}" == 'openvpn' ]]; then
        ${SUDO} rc-update add openvpn default &> /dev/null
        ${SUDO} rc-service -s openvpn restart
        ${SUDO} rc-service -N openvpn start
      elif [[ "${VPN}" == 'wireguard' ]]; then
        ${SUDO} rc-update add wg-quick default &> /dev/null
        ${SUDO} rc-service -s wg-quick restart
        ${SUDO} rc-service -N wg-quick start
      fi

      ;;
  esac
}

askUnattendedUpgrades() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${UNATTUPG}" ]]; then
      UNATTUPG=1
      echo "::: Sin preferencia sobre actualizaciones desatendidas, asumiendo que sí"
    else
      if [[ "${UNATTUPG}" -eq 1 ]]; then
        echo "::: Habilitando actualizaciones desatendidas"
      else
        echo "::: Omitiendo actualizaciones desatendidas"
      fi
    fi

    echo "UNATTUPG=${UNATTUPG}" >> "${tempsetupVarsFile}"
    return
  fi

  whiptail \
    --msgbox \
  --backtitle "Mantenimiento y Seguridad" \
  --title "Actualizaciones de Seguridad Automáticas" --ok-button "Entendido" \
  "Para proteger tu servidor frente a vulnerabilidades, el asistente configurará el servicio 'unattended-upgrades'.

Esta herramienta permite que el sistema instale automáticamente parches de seguridad críticos de forma diaria. 

Nota importante: 
• Este proceso solo aplica actualizaciones de seguridad y nunca forzará un reinicio del sistema.
• Te recomendamos reiniciar el servidor periódicamente para asegurar que todos los parches aplicados se carguen correctamente." "${r}" "${c}"

  if whiptail \
    --backtitle "Mantenimiento y Seguridad" \
  --title "Actualizaciones de Seguridad Automáticas" \
  --yes-button "Habilitar (Recomendado)" --no-button "Omitir" \
  --yesno "Mantener el servidor protegido es fundamental. Al habilitar esta opción, el sistema instalará diariamente, de forma desatendida y segura, los parches de seguridad críticos para tu sistema operativo.

Esta función no requiere intervención humana y ayuda a prevenir vulnerabilidades.

¿Deseas activar las actualizaciones automáticas de seguridad?" \
    "${r}" \
    "${c}"; then
    UNATTUPG=1
  else
    UNATTUPG=0
  fi

  echo "UNATTUPG=${UNATTUPG}" >> "${tempsetupVarsFile}"
}

confUnattendedUpgrades() {
  local PIVPN_DEPS periodic_file

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    PIVPN_DEPS=(unattended-upgrades)
    installDependentPackages PIVPN_DEPS[@]
    aptConfDir="/etc/apt/apt.conf.d"

    # El paquete unattended-upgrades de Raspbian descarga la configuración de Debian,
    # así que copiamos la configuración adecuada
    # https://github.com/mvo5/unattended-upgrades/blob/master/data/50unattended-upgrades.Raspbian
    # Añadir las configuraciones restantes para todas las demás distribuciones
    if [[ "${PLAT}" == "Raspbian" ]]; then
      ${SUDO} install -m 644 \
        "${pivpnFilesDir}/files${aptConfDir}/50unattended-upgrades.Raspbian" \
        "${aptConfDir}/50unattended-upgrades"
    fi

    if [[ "${PLAT}" == "Ubuntu" ]]; then
      periodic_file="${aptConfDir}/10periodic"
    else
      periodic_file="${aptConfDir}/02periodic"
    fi

    # 50unattended-upgrades en Ubuntu ya debería tener solo la seguridad habilitada
    # por lo que solo necesitamos configurar el archivo 10periodic
    {
      echo "APT::Periodic::Update-Package-Lists \"1\";"
      echo "APT::Periodic::Download-Upgradeable-Packages \"1\";"
      echo "APT::Periodic::Unattended-Upgrade \"1\";"

      if [[ "${PLAT}" == "Ubuntu" ]]; then
        echo "APT::Periodic::AutocleanInterval \"5\";"
      else
        echo "APT::Periodic::Enable \"1\";"
        echo "APT::Periodic::AutocleanInterval \"7\";"
        echo "APT::Periodic::Verbose \"0\";"
      fi
    } | ${SUDO} tee "${periodic_file}" > /dev/null

    # Habilitar actualizaciones automáticas a través del repositorio bullseye
    # al instalar desde el paquete debian
    if [[ "${VPN}" == "wireguard" ]]; then
      if [[ -f /etc/apt/sources.list.d/pivpn-bullseye-repo.list ]]; then
        if ! grep -q "\"o=${PLAT},n=bullseye\";" \
          "${aptConfDir}/50unattended-upgrades"; then
          local sed_pattern
          sed_pattern=" {/a\"o=${PLAT},n=bullseye\";"
          sed_pattern="${sed_pattern} {/a\"o=${PLAT},n=bullseye\";"
          ${SUDO} sed -i "${sed_pattern}" "${aptConfDir}/50unattended-upgrades"
        fi
      fi
    fi
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    local down_dir
    ## instalar dependencias
    # shellcheck disable=SC2086
    ${SUDO} ${PKG_INSTALL} unzip asciidoctor

    if ! down_dir="$(mktemp -d)"; then
      err "::: ¡Fallo al crear el directorio de descarga para apk-autoupdate!"
      exit 1
    fi

    ## descargar binarios
    curl -fLo "${down_dir}/master.zip" \
      https://github.com/jirutka/apk-autoupdate/archive/refs/heads/master.zip
    unzip -qd "${down_dir}" "${down_dir}/master.zip"

    (
      cd "${down_dir}/apk-autoupdate-master" || exi

      ## personalizar binarios
      sed -i -E -e 's/^(prefix\s*:=).*/\1 \/usr/' Makefile

      ## instalar
      ${SUDO} make install

      if ! command -v apk-autoupdate &> /dev/null; then
        err "::: ¡Fallo al compilar e instalar apk-autoupdate!"
        exit
      fi
    ) || exit 1

    ${SUDO} install -m 0755 \
      "${pivpnFilesDir}/files/etc/apk/personal_autoupdate.conf" \
      /etc/apk/personal_autoupdate.conf
    ${SUDO} apk-autoupdate /etc/apk/personal_autoupdate.conf
  fi
}

writeConfigFiles() {
  # Guardar la configuración de instalación en la ubicación final
  echo "INSTALLED_PACKAGES=(${INSTALLED_PACKAGES[*]})" >> "${tempsetupVarsFile}"
  echo "::: Archivos de configuración copiados a ${setupConfigDir}/${VPN}/${setupVarsFile}"
  ${SUDO} mkdir -p "${setupConfigDir}/${VPN}/"
  ${SUDO} cp "${tempsetupVarsFile}" "${setupConfigDir}/${VPN}/${setupVarsFile}"
}

installScripts() {
  # Asegurar que /opt exista (problema #607)
  ${SUDO} mkdir -p /opt

  if [[ "${VPN}" == 'wireguard' ]]; then
    othervpn='openvpn'
  else
    othervpn='wireguard'
  fi

  # Crear enlaces simbólicos de los scripts desde /usr/local/src/pivpn a sus diversas ubicaciones
  echo -e "::: Instalando scripts en ${pivpnScriptDir}..."

  # si el archivo del otro protocolo existe, se ha instalado
  if [[ -r "${setupConfigDir}/${othervpn}/${setupVarsFile}" ]]; then
    # Ambos están instalados, sin autocompletado de bash, desvincular si ya está ahí
    ${SUDO} unlink /etc/bash_completion.d/pivpn

    # Desvincular el script pivpn específico del protocolo y enlazar simbólicamente el script
    # común a la ubicación en su lugar
    ${SUDO} unlink /usr/local/bin/pivpn
    ${SUDO} ln -sfT "${pivpnFilesDir}/scripts/pivpn" /usr/local/bin/pivpn
  else
    # Comprobar si el directorio de scripts bash_completion existe y crearlo si no
    ${SUDO} mkdir -p /etc/bash_completion.d

    # Solo hay un protocolo instalado, enlazar simbólicamente el autocompletado de bash, el script pivpn
    # y el directorio de scripts
    ${SUDO} ln -sfT \
      "${pivpnFilesDir}/scripts/${VPN}/bash-completion" \
      /etc/bash_completion.d/pivpn
    ${SUDO} ln -sfT \
      "${pivpnFilesDir}/scripts/${VPN}/pivpn.sh" \
      /usr/local/bin/pivpn
    ${SUDO} ln -sf "${pivpnFilesDir}/scripts/" "${pivpnScriptDir}"
    # shellcheck disable=SC1091
    . /etc/bash_completion.d/pivpn
  fi

  echo " hecho."
}

displayFinalMessage() {
  # Asegurar que las escrituras en caché lleguen al almacenamiento persistente
  echo "::: Vaciando escrituras en el disco..."

  sync

  echo "::: hecho."

  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: ¡Instalación Completada!"
    echo "::: Ahora ejecuta 'pivpn add' para crear los perfiles de los clientes."
    echo "::: ¡Ejecuta 'pivpn help' para ver qué más puedes hacer!"
    echo
    echo -n "::: Si encuentras alguna dificultad, por favor consulta la documentación "
    echo "o abre un reporte detallado en nuestro repositorio."
    echo "::: (https://github.com/wfhgdev/pivpn_spanish)"
    echo
    echo "::: Gracias por utilizar este instalador en español."
    echo "::: Se recomienda encarecidamente reiniciar después de la instalación."
    return
  fi

  # Mensaje de finalización para el usuario
  whiptail \
    --backtitle "Finalizando Instalación" \
    --title "¡Configuración Exitosa!" --ok-button "Finalizar" \
    --msgbox "¡Enhorabuena! Tu servidor VPN ya está operativo.

Comandos útiles para empezar:
• pivpn add : Crea nuevos perfiles de usuario.
• pivpn help : Consulta todos los comandos disponibles.

¿Encontraste algún problema? 
Por favor, revisa nuestra documentación oficial antes de reportar un error. Esto nos ayuda a ofrecerte un mejor soporte y a mantener la comunidad organizada.

Gracias por confiar en PiVPN Spanish." "${r}" "${c}"

  if whiptail \
    --title "Reiniciar" \
    --defaultno --yes-button "Sí" --no-button "No" \
    --yesno "Se recomienda encarecidamente reiniciar después de la instalación. \
¿Te gustaría reiniciar ahora?" "${r}" "${c}"; then
    whiptail \
      --title "Reiniciando" \
      --msgbox "El sistema se reiniciará ahora." "${r}" "${c}"
    printf "\\nReiniciando el sistema...\\n"
    ${SUDO} sleep 3

    ${SUDO} reboot
  fi
}

main "$@"

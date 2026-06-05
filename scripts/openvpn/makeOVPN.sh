#!/bin/bash
# Crear cliente OpenVPN

### Constantes
setupVars="/etc/pivpn/openvpn/setupVars.conf"
DEFAULT="Default.txt"
FILEEXT=".ovpn"
CRT=".crt"
KEY=".key"
CA="ca.crt"
TA="ta.key"
TC_V2="tc-v2/server.key"
INDEX="/etc/openvpn/easy-rsa/pki/index.txt"
TC_V2_METADATA="/etc/pivpn/openvpn/tc-v2-metadata.txt"

# shellcheck disable=SC1090
source "${setupVars}"

if [ ! -r /opt/pivpn/ipaddr_utils.sh ]; then
  exit 1
fi
# shellcheck disable=SC1091
source /opt/pivpn/ipaddr_utils.sh

# shellcheck disable=SC2154
userGroup="${install_user}:${install_user}"

## Funciones
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

helpFunc() {
  echo "::: Crear un perfil ovpn de cliente, nopass opcional"
  echo ":::"
  echo -n "::: Uso: pivpn <-a|add> [-n|--name <arg>] "
  echo -n "[-p|--password <arg>]|[nopass] [-d|--days <numero>] "
  echo "[-b|--bitwarden] [-i|--iOS] [-o|--ovpn] [-h|--help]"
  echo ":::"
  echo "::: Comandos:"
  echo ":::  [ninguno]            Modo interactivo"
  echo ":::  nopass               Crear un cliente sin contraseña"
  echo -n ":::  -n,--name            Nombre para el Cliente "
  echo "(por defecto: \"$(hostname)\")"
  echo ":::  -p,--password        Contraseña para el Cliente (sin valor por defecto)"
  echo -n ":::  -d,--days            Expirar el certificado después del número "
  echo "especificado de días (por defecto: 1080)"
  echo ":::  -b,--bitwarden       Crear y guardar un cliente a través de Bitwarden"
  echo -n ":::  -i,--iOS             Generar un certificado que aprovecha el "
  echo "llavero de iOS"
  echo -n ":::  -o,--ovpn            Regenerar un archivo de configuración .ovpn para un "
  echo "cliente existente"
  echo ":::  -h,--help            Mostrar este diálogo de ayuda"
}

checkName() {
  # comprobar nombre
  if [[ "${NAME}" =~ [^a-zA-Z0-9.@_-] ]]; then
    err "El nombre solo puede contener caracteres alfanuméricos y estos símbolos (.-@_)."
    exit 1
  elif [[ "${NAME}" =~ ^[0-9]+$ ]]; then
    err "Los nombres no pueden ser números enteros."
    exit 1
  elif [[ "${NAME}" =~ \ |\' ]]; then
    err "Los nombres no pueden contener espacios."
    exit 1
  elif [[ "${NAME:0:1}" == "-" ]]; then
    err "El nombre no puede empezar con - (guion)"
    exit 1
  elif [[ "${NAME::1}" == "." ]]; then
    err "Los nombres no pueden empezar con un . (punto)."
    exit 1
  elif [[ -z "${NAME}" ]]; then
    err "::: No puedes dejar el nombre en blanco."
    exit 1
  fi
}

keynoPASS() {
  # Construir la clave del cliente
  export EASYRSA_CERT_EXPIRE="${DAYS}"
  ./easyrsa --batch build-client-full "${NAME}" nopass
  cd pki || exit
}

useBitwarden() {
  # iniciar sesión y desbloquear la bóveda
  printf "****Inicio de sesión en Bitwarden****"
  printf "\n"

  SESSION_KEY="$(bw login --raw)"
  export BW_SESSION="${SESSION_KEY}"

  printf "¡Inicio de sesión exitoso!"
  printf "\n"

  # pedir al usuario el nombre de usuario
  printf "Introduce el nombre de usuario:  "
  read -r NAME

  # comprobar nombre
  checkName

  # pedir al usuario la longitud de la contraseña
  printf "Por favor, introduce la longitud de caracteres que deseas para tu contraseña "
  printf "(mínimo 12): "
  read -r LENGTH

  # comprobar longitud
  until [[ "${LENGTH}" -gt 11 ]] && [[ "${LENGTH}" -lt 129 ]]; do
    echo "La contraseña debe tener entre 12 y 128 caracteres, por favor inténtalo de nuevo."
    # pedir al usuario la longitud de la contraseña
    printf "Por favor, introduce la longitud de caracteres que deseas para tu contraseña "
    printf "(mínimo 12): "
    read -r LENGTH
  done

  printf "Creando un elemento PiVPN para tu bóveda..."
  printf "\n"

  # crear un nuevo elemento para tu contraseña de PiVPN
  PASSWD="$(bw generate -usln --length "${LENGTH}")"
  bw get template item \
    | jq '.login.type = "1"' \
    | jq '.name = "PiVPN"' \
    | jq -r --arg NAME "${NAME}" '.login.username = $NAME' \
    | jq -r --arg PASSWD "${PASSWD}" '.login.password = $PASSWD' \
    | bw encode \
    | bw create item
  bw logout
}

keyPASS() {
  if [[ -z "${PASSWD}" ]]; then
    stty -echo

    while true; do
      printf "Introduce la contraseña para el cliente:  "
      read -r PASSWD
      printf "\n"
      printf "Introduce la contraseña de nuevo para verificar:  "
      read -r PASSWD2
      printf "\n"

      [[ "${PASSWD}" == "${PASSWD2}" ]] && break

      printf "¡Las contraseñas no coinciden! Por favor, inténtalo de nuevo.\n"
    done

    stty echo

    if [[ -z "${PASSWD}" ]]; then
      err "Dejaste la contraseña en blanco"
      err "Si no quieres una contraseña, por favor ejecuta:"
      err "pivpn add nopass"
      exit 1
    fi
  fi

  if [[ "${#PASSWD}" -lt 4 ]] || [[ "${#PASSWD}" -gt 1024 ]]; then
    err "La contraseña debe tener entre 4 y 1024 caracteres"
    exit 1
  fi

  export EASYRSA_CERT_EXPIRE="${DAYS}"
  ./easyrsa --batch --passin=pass:"${PASSWD}" \
    --passout=pass:"${PASSWD}" \
    build-client-full "${NAME}"

  cd pki || exit
}

### Script
if [[ ! -f "${setupVars}" ]]; then
  err "::: ¡Falta el archivo de variables de configuración!"
  exit 1
fi

if [[ -z "${HELP_SHOWN}" ]]; then
  helpFunc
  echo
  echo "HELP_SHOWN=1" >> "${setupVars}"
fi

# Analizar argumentos de entrada
while [[ "$#" -gt 0 ]]; do
  _key="${1}"

  case "${_key}" in
    -n | --name | --name=*)
      _val="${_key##--name=}"

      if [[ "${_val}" == "${_key}" ]]; then
        [[ "$#" -lt 2 ]] \
          && err "Falta el valor para el argumento opcional '${_key}'." \
          && exit 1

        _val="${2}"
        shift
      fi

      NAME="${_val}"
      checkName
      ;;
    -p | --password | --password=*)
      _val="${_key##--password=}"

      if [[ "${_val}" == "${_key}" ]]; then
        [[ "$#" -lt 2 ]] \
          && err "Falta el valor para el argumento opcional '${_key}'." \
          && exit 1

        _val="${2}"
        shift
      fi

      PASSWD="${_val}"
      ;;
    -d | --days | --days=*)
      _val="${_key##--days=}"

      if [[ "${_val}" == "${_key}" ]]; then
        [[ "$#" -lt 2 ]] \
          && err "Falta el valor para el argumento opcional '${_key}'." \
          && exit 1

        _val="${2}"
        shift
      fi

      DAYS="${_val}"
      ;;
    -i | --iOS)
      if [[ "${TWO_POINT_FIVE}" -ne 1 ]]; then
        iOS=1
      else
        err "Lo siento, no se pueden generar configuraciones específicas de iOS para certificados ECDSA"
        err "Genera certificados tradicionales usando 'pivpn -a' o reinstala PiVPN sin optar por las características de OpenVPN 2.4"
        exit 1
      fi
      ;;
    -h | --help)
      helpFunc
      exit 0
      ;;
    nopass)
      NO_PASS="1"
      ;;
    -b | --bitwarden)
      if command -v bw > /dev/null; then
        BITWARDEN="2"
      else
        echo 'Bitwarden no encontrado, por favor instala bitwarden'

        if [[ "${PLAT}" == 'Alpine' ]]; then
          echo 'Puedes descargarlo mediante los siguientes comandos:'
          echo -n $'\t''curl -fLo bitwarden.zip --no-cache https://github.com/'
          echo -n 'bitwarden/clients/releases/download/cli-v2022.6.2/'
          echo 'bw-linux-2022.6.2.zip'
          echo $'\t''apk --no-cache unzip'
          echo $'\t''unzip bitwarden.zip'
          echo $'\t''mv bw /opt/bw'
          echo $'\t''chmod 755 /opt/bw'
          echo $'\t''rm bitwarden.zip'
          echo $'\t''apk --no-cache --purge del -r unzip'
        fi

        exit 1
      fi

      ;;
    -o | --ovpn)
      GENOVPNONLY=1
      ;;
    *)
      err "Error: Se obtuvo un argumento inesperado '${1}'"
      helpFunc
      exit 1
      ;;
  esac

  shift
done

# asegurarse de que el directorio ovpns exista
# Deshabilitando advertencia para SC2154, variable obtenida externamente
# shellcheck disable=SC2154
if [[ ! -d "${install_home}/ovpns" ]]; then
  mkdir "${install_home}/ovpns"
  chown "${userGroup}" "${install_home}/ovpns"
  chmod 0750 "${install_home}/ovpns"
fi

# Excluir la primera, última y las direcciones del servidor
# shellcheck disable=SC2154
MAX_CLIENTS="$((2 ** (32 - subnetClass) - 3))"

# shellcheck disable=SC2154
FIRST_IPV4_DEC="$(dotIPv4FirstDec "${pivpnNET}" "${subnetClass}")"
LAST_IPV4_DEC="$(dotIPv4LastDec "${pivpnNET}" "${subnetClass}")"

if [ "$(find /etc/openvpn/ccd -type f | wc -l)" -ge "${MAX_CLIENTS}" ]; then
  echo "::: ¡No se pueden añadir más clientes (máx. ${MAX_CLIENTS})!"
  exit 1
fi

# Encontrar una dirección no utilizada para la IP del cliente
for ((ip = FIRST_IPV4_DEC + 2; ip <= LAST_IPV4_DEC - 1; ip++)); do
  # find devuelve 0 si la carpeta está vacía, así que creamos la excepción 'ls -A [...]'
  # para detenernos en la primera IP estática (10.8.0.2). De lo contrario, circularía
  # hasta el final sin encontrar un octeto disponible.
  # deshabilitando SC2514, variable obtenida externamente
  ip_dot="$(decIPv4ToDot "${ip}")"

  if [[ -z "$(ls -A /etc/openvpn/ccd)" ]] \
    || ! find /etc/openvpn/ccd -type f \
      -exec grep -q "${ip_dot}" {} +; then
    UNUSED_IPV4_DOT="${ip_dot}"
    break
  fi
done

#bitWarden
if [[ "${BITWARDEN}" =~ "2" ]]; then
  useBitwarden
fi

if [[ -z "${NAME}" ]]; then
  printf "Introduce un Nombre para el Cliente:  "
  read -r NAME
  checkName
else
  checkName
fi

if [[ "${GENOVPNONLY}" == 1 ]]; then
  # Generar archivo de configuración .ovpn
  cd /etc/openvpn/easy-rsa/pki || exit
else
  # Comprobar si el nombre ya está en uso
  while read -r line || [[ -n "${line}" ]]; do
    STATUS=$(echo "${line}" | awk '{print $1}')

    if [[ "${STATUS}" == "V" ]]; then
      # Deshabilitando SC2001 ya que ${variable//search/replace}
      # no va bien con expresiones regulares
      # shellcheck disable=SC2001
      CERT="$(echo "${line}" | sed -e 's:.*/CN=::')"

      if [[ "${CERT}" == "${NAME}" ]]; then
        INUSE="1"
        break
      fi
    fi
  done < "${INDEX}"

  if [[ "${INUSE}" == 1 ]]; then
    err "!! Este nombre ya está en uso por un Certificado Válido."
    err "Por favor, elige otro nombre o revoca este certificado primero."
    exit 1
  # Comprobar si el nombre está reservado
  elif [[ "${NAME}" == "ta" ]] \
    || [[ "${NAME}" == "server" ]] \
    || [[ "${NAME}" == "ca" ]]; then
    err "Lo siento, esto está en uso por el servidor y no puede ser utilizado por clientes."
    exit 1
  fi

  # A partir de EasyRSA 3.0.6, por defecto los certificados duran 1080 días,
  # ver https://github.com/OpenVPN/easy-rsa/blob/6b7b6bf1f0d3c9362b5618ad18c66677351cacd1/easyrsa3/vars.example
  if [[ -z "${DAYS}" ]]; then
    read -r -e -p "¿Cuántos días debería durar el certificado?  " -i 1080 DAYS
  fi

  if [[ ! "${DAYS}" =~ ^[0-9]+$ ]] \
    || [[ "${DAYS}" -lt 1 ]] \
    || [[ "${DAYS}" -gt 3650 ]]; then
    # El CRL dura 3650 días por lo que no tiene mucho sentido
    # que los certificados duren más
    err "Por favor introduce un número válido de días, entre 1 y 3650 inclusive."
    exit 1
  fi

  cd /etc/openvpn/easy-rsa || exit

  if [[ "${NO_PASS}" =~ "1" ]]; then
    if [[ -n "${PASSWD}" ]]; then
      err "Ambos argumentos, nopass y contraseña, se han pasado al script. Por favor, usa solo uno."
      exit 1
    else
      keynoPASS
    fi
  else
    keyPASS
  fi
fi

# 1ro Verificar que exista la Clave Pública del cliente
if [[ ! -f "issued/${NAME}${CRT}" ]]; then
  err "[ERROR]: No se encontró el Certificado de Clave Pública del Cliente: ${NAME}${CRT}"
  exit
fi

echo "Certificado del cliente encontrado: ${NAME}${CRT}"

# Luego, verificar que haya una clave privada para ese cliente
if [[ ! -f "private/${NAME}${KEY}" ]]; then
  err "[ERROR]: No se encontró la Clave Privada del Cliente: ${NAME}${KEY}"
  exit
fi

echo "Clave Privada del Cliente encontrada: ${NAME}${KEY}"

# Confirmar que la clave pública CA existe
if [[ ! -f "${CA}" ]]; then
  err "[ERROR]: No se encontró la Clave Pública de la CA: ${CA}"
  exit
fi

echo "Clave Pública de la CA encontrada: ${CA}"

if [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
  # Confirmar que el archivo de clave tls-crypt-v2 existe
  if [[ ! -f "${TC_V2}" ]]; then
    err "[ERROR]: No se encontró la clave de servidor TLS crypt: ${TC_V2}"
    exit
  fi

  echo "Clave de servidor TLS crypt encontrada: ${TC_V2}"

  # Generar y guardar un ID aleatorio de 128 bits para incrustar en la clave tls-crypt
  # para rechazar clientes revocados a nivel de tls-crypt
  metadata="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 22)"
  base64_metadata="$(echo -n "${metadata}" | base64 -w 0)"
  echo "${NAME} ${metadata}" >> "${TC_V2_METADATA}"

  # Generar clave tls-crypt-v2 específica del cliente basada en la del servidor
  openvpn --tls-crypt-v2 "${TC_V2}" --genkey tls-crypt-v2-client "tc-v2/${NAME}.key" "${base64_metadata}"
else
  # Confirmar que el archivo de clave tls-auth existe
  if [[ ! -f "${TA}" ]]; then
    err "[ERROR]: No se encontró la clave TLS auth: ${TA}"
    exit
  fi

  echo "Clave TLS auth encontrada: ${TA}"
fi

## Se añadió un nuevo paso para crear un archivo .ovpn12 que se puede almacenar en el llavero de iOS
## Este paso es un método más seguro y no requiere que el usuario final
## introduzca contraseñas, o almacenar el certificado privado del cliente donde puede ser fácilmente
## manipulado
## https://openvpn.net/faq/how-do-i-use-a-client-certificate-and-private-key-from-the-ios-keychain/

# Genera el archivo .ovpn SIN la clave privada del cliente
{
  # Comenzar llenando con el archivo por defecto
  cat "${DEFAULT}"

  # Ahora, adjuntar el Certificado Público de la CA
  echo "<ca>"
  cat "${CA}"
  echo "</ca>"

  # A continuación, adjuntar el Certificado Público del cliente
  echo "<cert>"
  sed -n \
    -e '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' \
    < "issued/${NAME}${CRT}"
  echo "</cert>"

  if [[ "${iOS}" != 1 ]]; then
    # Luego, adjuntar la Clave Privada del cliente
    echo "<key>"
    cat "private/${NAME}${KEY}"
    echo "</key>"
  fi

  # Finalmente, adjuntar la Clave Privada tls
  if [[ "${iOS}" != 1 ]] && [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
    echo "<tls-crypt-v2>"
    cat "tc-v2/${NAME}.key"
    echo "</tls-crypt-v2>"
  else
    echo "<tls-auth>"
    cat "${TA}"
    echo "</tls-auth>"
  fi
} > "${NAME}${FILEEXT}"

if [[ "${iOS}" == 1 ]]; then
  # Copiar el perfil .ovpn al directorio de inicio para un acceso remoto conveniente
  printf "========================================================\n"
  printf "Generando un archivo .ovpn12 para uso con dispositivos iOS\n"
  printf "Por favor, recuerda la contraseña de exportación\n"
  printf "ya que la necesitarás para importar el certificado en tu dispositivo iOS\n"
  printf "========================================================\n"

  openssl pkcs12 \
    -passin pass:"${PASSWD_UNESCAPED}" \
    -export \
    -in "issued/${NAME}${CRT}" \
    -inkey "private/${NAME}${KEY}" \
    -certfile "${CA}" \
    -name "${NAME}" \
    -out "${install_home}/ovpns/${NAME}.ovpn12"

  chown "${userGroup}" "${install_home}/ovpns/${NAME}.ovpn12"
  chmod 640 "${install_home}/ovpns/${NAME}.ovpn12"

  printf "========================================================\n"
  printf "\e[1m¡Hecho! ¡%s creado exitosamente!\e[0m \n" "${NAME}.ovpn12"
  printf "Necesitarás transferir tanto el archivo .ovpn como el .ovpn12\n"
  printf "a tu dispositivo iOS.\n"
  printf "========================================================\n\n"
fi

echo -n "ifconfig-push ${UNUSED_IPV4_DOT} " >> /etc/openvpn/ccd/"${NAME}"
# ¡El espacio después de ${UNUSED_IPV4_DOT} es importante!
cidrToMask "${subnetClass}" >> /etc/openvpn/ccd/"${NAME}"
# el resultado final debería ser una línea como:
# ifconfig-push ${UNUSED_IPV4_DOT} ${subnetClass}
# ifconfig-push 10.205.45.8 255.255.255.0

if [[ -f /etc/pivpn/hosts.openvpn ]]; then
  echo "${UNUSED_IPV4_DOT} ${NAME}.pivpn" >> /etc/pivpn/hosts.openvpn

  if killall -SIGHUP pihole-FTL; then
    echo "::: Archivo hosts actualizado para Pi-hole"
  else
    err "::: Falló al recargar la configuración de pihole-FTL"
  fi
fi

# Copiar el perfil .ovpn al directorio de inicio para un acceso remoto conveniente
dest_path="${install_home}/ovpns/${NAME}${FILEEXT}"
cp "/etc/openvpn/easy-rsa/pki/${NAME}${FILEEXT}" "${dest_path}"
chown "${install_user}:${install_user}" "${dest_path}"
chmod 640 "/etc/openvpn/easy-rsa/pki/${NAME}${FILEEXT}"
chmod 640 "${dest_path}"
unset dest_path

printf "\n\n"
printf "========================================================\n"
printf "\e[1m¡Hecho! ¡%s creado exitosamente!\e[0m \n" "${NAME}${FILEEXT}"
printf "%s fue copiado a:\n" "${NAME}${FILEEXT}"
printf "  %s/ovpns\n" "${install_home}"
printf "para una fácil transferencia. Por favor, usa este perfil solo en un\n"
printf "dispositivo y crea perfiles adicionales para otros dispositivos.\n"
printf "========================================================\n\n"

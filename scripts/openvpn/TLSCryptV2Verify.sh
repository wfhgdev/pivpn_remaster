#!/bin/bash
# PiVPN: verificar los metadatos de tls-crypt-v2 con la lista de permitidos
# shellcheck disable=SC2154

### Constantes
TC_V2_METADATA="/etc/pivpn/openvpn/tc-v2-metadata.txt"

if [ "${script_type}" != "tls-crypt-v2-verify" ]; then
    echo "Tipo de script no compatible, rechazando..."
    exit 1
fi

if [ "${metadata_type}" != "0" ]; then
    # No debería ser posible con nuestra configuración
    echo "Los metadatos no son proporcionados por el usuario, rechazando..."
    exit 1
fi

if ! metadata="$(head -c 22 "${metadata_file}")"; then
    echo "No se pudieron leer los metadatos, rechazando..."
    exit 1
fi

if [ "${#metadata}" -lt 22 ]; then
    # No debería ser posible con nuestra configuración
    echo "Metadatos menores de 22 caracteres, rechazando..."
    exit 1
fi

if grep -q ' '"${metadata}"'$' "${TC_V2_METADATA}"; then
    # Se permite continuar la autenticación
    exit 0
else
    # Rechazado
    exit 1
fi

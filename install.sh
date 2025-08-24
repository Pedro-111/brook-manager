#!/bin/bash

# Brook Server Manager - Instalador
# Script de instalación automática

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[+]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[√]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Verificar root
if [[ $EUID -ne 0 ]]; then
    print_error "Este script debe ejecutarse como root"
    echo "Uso: sudo bash install.sh"
    exit 1
fi

print_status "Instalando Brook Server Manager..."

# Crear directorio de instalación
INSTALL_DIR="/opt/brook-manager"
mkdir -p $INSTALL_DIR

# Descargar el script principal
print_status "Descargando Brook Manager..."
wget -O $INSTALL_DIR/brook-manager.sh https://raw.githubusercontent.com/Pedro-111/brook-manager/main/brook-manager.sh

if [ $? -ne 0 ]; then
    print_error "Error al descargar el script"
    exit 1
fi

# Hacer ejecutable
chmod +x $INSTALL_DIR/brook-manager.sh

# Crear enlace simbólico en /usr/local/bin
ln -sf $INSTALL_DIR/brook-manager.sh /usr/local/bin/brook-manager

# Instalar dependencias básicas
print_status "Instalando dependencias..."
apt-get update > /dev/null 2>&1
apt-get install -y wget curl jq qrencode iproute2 openssl > /dev/null 2>&1

print_success "Brook Server Manager instalado correctamente"
print_status "Puedes ejecutarlo con: brook-manager"
print_status "O directamente: /opt/brook-manager/brook-manager.sh"

echo
print_warning "Nota: Para usar Let's Encrypt, asegúrate de que tu dominio apunte a esta IP"
print_warning "y que los puertos 80 y 443 estén abiertos en tu firewall"

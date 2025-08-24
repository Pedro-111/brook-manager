#!/bin/bash

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Variables
BROOK_DIR="/usr/local/bin"
BROOK_BIN="$BROOK_DIR/brook"
SERVICE_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/brook"
SSL_DIR="$CONFIG_DIR/ssl"
LOG_DIR="/var/log/brook"

# Función para mostrar mensajes
print_status() {
    echo -e "${BLUE}[+]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[-]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[√]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1" >&2
}

print_info() {
    echo -e "${CYAN}[i]${NC} $1" >&2
}

print_header() {
    echo -e "${MAGENTA}$1${NC}" >&2
}

# Verificar root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Este script debe ejecutarse como root"
        exit 1
    fi
}

# Verificar dependencias
check_dependencies() {
    local deps=("wget" "jq" "qrencode" "ip")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "Instalando dependencias faltantes: ${missing_deps[*]}..."
        apt-get update
        apt-get install -y "${missing_deps[@]}"
    fi
}

# Verificar si un puerto está en uso por otro proceso (no Brook)
check_port() {
    local port=$1
    local brook_pids=$(pgrep -f "brook")
    
    # Obtener procesos usando el puerto
    local port_pids=$(ss -tuln | grep ":$port " | awk '{print $1}' | head -1)
    
    if [ -n "$port_pids" ]; then
        # Verificar si es un proceso de Brook
        for brook_pid in $brook_pids; do
            if netstat -tulnp 2>/dev/null | grep ":$port " | grep -q "$brook_pid"; then
                # Es un proceso Brook, permitir el uso
                return 1
            fi
        done
        # No es un proceso Brook
        return 0
    fi
    
    return 1
}

# Obtener IP privada
get_private_ip() {
    ip route get 1 | awk '{print $7;exit}'
}

# Pausar y volver al menú
pause() {
    echo
    read -n 1 -s -r -p "Presione cualquier tecla para continuar..."
    echo
}

# Reiniciar servicios activos después de cambios
restart_active_services() {
    print_status "Reiniciando servicios de Brook activos..."
    local restarted=false
    
    for service in brook_server.service brook_wsserver.service brook_wssserver.service; do
        if systemctl is-enabled --quiet $service 2>/dev/null; then
            print_status "Reiniciando $service..."
            systemctl restart $service
            sleep 2
            if systemctl is-active --quiet $service; then
                print_success "$service reiniciado correctamente"
                restarted=true
            else
                print_error "Error al reiniciar $service"
                journalctl -u $service --no-pager -l --lines=5
            fi
        fi
    done
    
    if [ "$restarted" = "false" ]; then
        print_info "No hay servicios activos para reiniciar"
    fi
}

# Instalar Brook
install_brook() {
    check_root
    print_header "=== INSTALACIÓN DE BROOK ==="
    
    if [ -f "$BROOK_BIN" ]; then
        print_warning "Brook ya está instalado en $BROOK_BIN"
        read -p "¿Desea reinstalarlo? (s/n): " reinstall
        if [[ ! $reinstall =~ ^[Ss]$ ]]; then
            return 0
        fi
    fi
    
    print_status "Instalando Brook..."
    
    check_dependencies
    
    # Obtener última versión
    print_status "Obteniendo última versión de Brook..."
    latest_version=$(wget -qO- https://api.github.com/repos/txthinking/brook/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$latest_version" ]; then
        print_error "No se pudo obtener la última versión de Brook"
        pause
        return 1
    fi
    
    download_url="https://github.com/txthinking/brook/releases/download/${latest_version}/brook_linux_amd64"
    
    # Descargar Brook
    print_status "Descargando Brook..."
    wget -O $BROOK_BIN $download_url
    
    if [ $? -ne 0 ]; then
        print_error "Error al descargar Brook"
        pause
        return 1
    fi
    
    # Hacer ejecutable
    chmod +x $BROOK_BIN
    
    # Crear directorios necesarios
    mkdir -p $CONFIG_DIR $SSL_DIR $LOG_DIR
    
    print_success "Brook $latest_version instalado en $BROOK_BIN"
    
    # Mostrar versión
    print_info "Versión instalada:"
    $BROOK_BIN --version 2>/dev/null || echo "No se pudo obtener la versión"
    
    pause
}

# Configurar certificados SSL
setup_ssl() {
    local domain=$1
    local use_le=$2
    
    mkdir -p $SSL_DIR
    
    if [ "$use_le" = "true" ]; then
        # Usar Let's Encrypt
        print_status "Configurando certificados Let's Encrypt para $domain..."
        
        # Verificar si certbot está instalado
        if ! command -v certbot &> /dev/null; then
            print_status "Instalando Certbot..."
            apt-get update
            apt-get install -y certbot
        fi
        
        # Obtener certificado
        if certbot certonly --standalone -d $domain --non-interactive --agree-tos --register-unsafely-without-email > /dev/null 2>&1; then
            cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
            key_path="/etc/letsencrypt/live/$domain/privkey.pem"
            
            # Verificar que los certificados existen
            if [ -f "$cert_path" ] && [ -f "$key_path" ]; then
                print_success "Certificados Let's Encrypt obtenidos correctamente"
                echo "$cert_path:$key_path"
                return 0
            else
                print_error "No se encontraron los certificados Let's Encrypt"
                return 1
            fi
        else
            print_error "Error al obtener certificados Let's Encrypt"
            print_info "Asegúrese de que:"
            print_info "1. El dominio $domain apunta a esta IP"
            print_info "2. El puerto 80 está accesible desde Internet"
            return 1
        fi
    else
        # Usar certificados auto-firmados
        print_status "Generando certificados auto-firmados para $domain..."
        
        # Generar certificados en el formato correcto
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout $SSL_DIR/server.key \
            -out $SSL_DIR/server.crt \
            -subj "/C=PE/ST=Cajamarca/L=Cajamarca/O=Brook/CN=$domain" > /dev/null 2>&1
        
        if [ -f "$SSL_DIR/server.crt" ] && [ -f "$SSL_DIR/server.key" ]; then
            print_success "Certificados auto-firmados generados correctamente"
            echo "$SSL_DIR/server.crt:$SSL_DIR/server.key"
            return 0
        else
            print_error "Error al generar certificados auto-firmados"
            return 1
        fi
    fi
}

# Configurar Brook
configure_brook() {
    check_root
    print_header "=== CONFIGURACIÓN DE BROOK ==="
    
    if [ ! -f "$BROOK_BIN" ]; then
        print_error "Brook no está instalado. Por favor, instálelo primero."
        pause
        return 1
    fi
    
    mkdir -p $CONFIG_DIR
    
    echo "Seleccione el modo de operación:"
    echo "1) server (SOCKS5 con autenticación)"
    echo "2) wsserver (WebSocket)"
    echo "3) wssserver (WebSocket + TLS)"
    echo "4) Volver al menú principal"
    read -p "Opción [1-4]: " mode_choice

    case $mode_choice in
        4) return 0;;
        1) mode="server";;
        2) mode="wsserver";;
        3) mode="wssserver";;
        *) print_error "Opción inválida"; pause; return 1;;
    esac

    case $mode in
        "server") default_port=1080;;
        "wsserver") default_port=8080;;
        "wssserver") default_port=443;;
    esac
    
    while true; do
        read -p "Puerto [$default_port]: " port
        port=${port:-$default_port}
        
        # Verificar si el puerto está en uso por otro proceso
        if check_port $port; then
            print_error "El puerto $port ya está en uso por otro proceso. Elija otro puerto."
        else
            break
        fi
    done
    
    read -p "Contraseña: " password
    if [ -z "$password" ]; then
        print_error "La contraseña no puede estar vacía"
        pause
        return 1
    fi
    
    read -p "Dirección de escucha [0.0.0.0]: " listen
    listen=${listen:-0.0.0.0}

    # Configuración adicional para wsserver y wssserver
    domain=""
    path=""
    if [ "$mode" = "wsserver" ] || [ "$mode" = "wssserver" ]; then
        # Obtener IP privada
        IP_PRIVADA=$(get_private_ip)
        print_info "Tu IP privada es: $IP_PRIVADA"
        
        read -p "Dominio o IP (Enter para usar la IP privada $IP_PRIVADA): " domain_input
        if [ -z "$domain_input" ]; then
            domain=$IP_PRIVADA
        else
            domain=$domain_input
        fi
        
        read -p "Path (ej: /brook, Enter para usar /ws por defecto): " path_input
        if [ -z "$path_input" ]; then
            path="/ws"
        else
            path=$path_input
        fi
    fi

    # Construir comando de ejecución con la sintaxis correcta
    exec_start=""
    cert_path=""
    key_path=""
    
    case $mode in
        "server")
            # Sintaxis correcta: brook server --listen :puerto --password password
            exec_start="$BROOK_BIN server --listen $listen:$port --password $password"
            ;;
        "wsserver")
            # Sintaxis correcta: brook wsserver --listen :puerto --password password --path /ws
            exec_start="$BROOK_BIN wsserver --listen $listen:$port --password $password --path $path"
            ;;
        "wssserver")
            print_status "Configurando servidor WebSocket con SSL..."
            echo "Seleccione el tipo de certificado SSL:"
            echo "1) Auto-firmado (para pruebas)"
            echo "2) Let's Encrypt (para producción)"
            echo "3) Volver al menú principal"
            read -p "Opción [1-3]: " cert_choice
            
            case $cert_choice in
                3) return 0;;
                1) use_le="false";;
                2) use_le="true";;
                *) print_error "Opción inválida"; pause; return 1;;
            esac
            
            # Configurar certificados
            ssl_paths=$(setup_ssl "$domain" "$use_le")
            if [ $? -ne 0 ]; then
                print_error "No se pudieron configurar los certificados SSL"
                pause
                return 1
            fi
            
            cert_path=$(echo $ssl_paths | cut -d: -f1)
            key_path=$(echo $ssl_paths | cut -d: -f2)
            
            # Sintaxis correcta: brook wssserver --domainaddress domain:port --password password --cert cert --certkey key --path /ws
            exec_start="$BROOK_BIN wssserver --domainaddress $domain:$port --password $password --cert $cert_path --certkey $key_path --path $path"
            ;;
    esac

    config_file="$CONFIG_DIR/brook_${mode}.conf"
    service_file="$SERVICE_DIR/brook_${mode}.service"

    # Crear config
    echo "mode=$mode" > $config_file
    echo "listen=$listen" >> $config_file
    echo "port=$port" >> $config_file
    echo "password=$password" >> $config_file
    echo "domain=$domain" >> $config_file
    echo "path=$path" >> $config_file
    echo "cert_path=$cert_path" >> $config_file
    echo "key_path=$key_path" >> $config_file
    echo "exec_start=$exec_start" >> $config_file

    # Crear servicio systemd
    cat > $service_file <<EOF
[Unit]
Description=Brook $mode Service
After=network.target

[Service]
Type=simple
ExecStart=$exec_start
Restart=always
RestartSec=5
User=root
Group=root
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    # Prueba del comando antes de habilitar el servicio
    print_status "Probando comando Brook antes de crear el servicio..."
    print_info "Comando: $exec_start"
    
    # Habilitar e iniciar servicio
    systemctl daemon-reload
    systemctl enable brook_${mode}.service
    
    if systemctl start brook_${mode}.service; then
        sleep 3
        if systemctl is-active --quiet brook_${mode}.service; then
            print_success "Servicio brook_${mode}.service iniciado correctamente"
        else
            print_error "El servicio no está corriendo. Logs:"
            journalctl -u brook_${mode}.service --no-pager -l --lines=10
            pause
            return 1
        fi
    else
        print_error "Error al iniciar el servicio. Logs:"
        journalctl -u brook_${mode}.service --no-pager -l --lines=10
        pause
        return 1
    fi
    
    # Reiniciar otros servicios activos
    restart_active_services
    
    print_status "Archivo de configuración: $config_file"
    print_status "Servicio: brook_${mode}.service"
    
    # Mostrar información de conexión
    case $mode in
        "server")
            print_info "Modo: SOCKS5 Server"
            print_info "Servidor: $listen:$port"
            print_info "Contraseña: $password"
            ;;
        "wsserver")
            print_info "Modo: WebSocket (WS)"
            print_info "URL de conexión: ws://$domain:$port$path"
            print_info "Contraseña: $password"
            ;;
        "wssserver")
            print_info "Modo: WebSocket + TLS (WSS)"
            print_info "URL de conexión: wss://$domain:$port$path"
            print_info "Contraseña: $password"
            print_info "Certificados SSL: $cert_path"
            if [ "$use_le" = "false" ]; then
                print_warning "Nota: Los certificados auto-firmados generarán advertencias en los clientes"
            fi
            ;;
    esac
    
    pause
}

# Generar QR y enlace
generate_qr() {
    check_root
    print_header "=== GENERAR CÓDIGO QR Y ENLACE ==="
    
    if [ ! -f "$BROOK_BIN" ]; then
        print_error "Brook no está instalado. Por favor, instálelo primero."
        pause
        return 1
    fi
    
    config_files=($CONFIG_DIR/*.conf)
    if [ ${#config_files[@]} -eq 0 ]; then
        print_error "No hay configuraciones existentes"
        pause
        return 1
    fi

    echo "Configuraciones disponibles:"
    for i in "${!config_files[@]}"; do
        echo "$((i+1))) ${config_files[$i]##*/}"
    done
    echo "$(( ${#config_files[@]} + 1 ))) Volver al menú principal"

    read -p "Seleccione configuración: " config_choice
    
    if [ "$config_choice" = "$(( ${#config_files[@]} + 1 ))" ]; then
        return 0
    fi
    
    if [ -z "$config_choice" ] || [ "$config_choice" -lt 1 ] || [ "$config_choice" -gt "${#config_files[@]}" ]; then
        print_error "Selección inválida"
        pause
        return 1
    fi
    
    selected_config="${config_files[$((config_choice-1))]}"

    # Leer configuración desde archivo de texto plano
    mode=$(grep "^mode=" "$selected_config" | cut -d= -f2)
    port=$(grep "^port=" "$selected_config" | cut -d= -f2)
    password=$(grep "^password=" "$selected_config" | cut -d= -f2)
    listen=$(grep "^listen=" "$selected_config" | cut -d= -f2)
    domain=$(grep "^domain=" "$selected_config" | cut -d= -f2)
    path=$(grep "^path=" "$selected_config" | cut -d= -f2)

    case $mode in
        "server")
            link="brook://server?server=${listen}:${port}&password=${password}"
            ;;
        "wsserver")
            link="brook://wsserver?wsserver=${domain}:${port}&password=${password}"
            if [ -n "$path" ] && [ "$path" != "/ws" ]; then
                link="${link}&path=${path}"
            fi
            ;;
        "wssserver")
            link="brook://wssserver?wssserver=${domain}:${port}&password=${password}"
            if [ -n "$path" ] && [ "$path" != "/ws" ]; then
                link="${link}&path=${path}"
            fi
            ;;
        *)
            print_error "Modo no soportado: $mode"
            pause
            return 1
            ;;
    esac

    echo -e "${GREEN}Enlace de configuración:${NC}"
    echo "$link"
    echo ""
    echo -e "${GREEN}Código QR:${NC}"
    
    # Limpiar el enlace para QR
    clean_link=$(echo "$link" | tr -d '\n' | tr -d '\r')
    if qrencode -t UTF8 "$clean_link"; then
        print_success "Código QR generado correctamente"
    else
        print_error "Error al generar código QR"
        print_info "Intente instalar qrencode: apt install qrencode"
    fi
    pause
}

# Mostrar estado del servicio
show_status() {
    check_root
    print_header "=== ESTADO DE LOS SERVICIOS BROOK ==="
    
    services=$(ls $SERVICE_DIR/brook_*.service 2>/dev/null | xargs -n1 basename 2>/dev/null)
    
    if [ -z "$services" ]; then
        print_error "No hay servicios de Brook configurados"
        pause
        return 1
    fi
    
    for service in $services; do
        echo -e "\n${CYAN}Servicio: $service${NC}"
        systemctl status $service --no-pager -l
        echo -e "\n${YELLOW}Logs recientes de $service:${NC}"
        journalctl -u $service --no-pager -l --lines=10
    done
    
    pause
}

# Reiniciar servicios
restart_services() {
    check_root
    print_header "=== REINICIAR SERVICIOS BROOK ==="
    
    services=$(ls $SERVICE_DIR/brook_*.service 2>/dev/null | xargs -n1 basename 2>/dev/null)
    
    if [ -z "$services" ]; then
        print_error "No hay servicios de Brook configurados"
        pause
        return 1
    fi
    
    for service in $services; do
        print_status "Reiniciando $service"
        systemctl restart $service
        sleep 3
        if systemctl is-active --quiet $service; then
            print_success "$service reiniciado correctamente"
        else
            print_error "Error al reiniciar $service"
            journalctl -u $service --no-pager -l --lines=5
        fi
    done
    
    pause
}

# Ver logs de servicios
show_logs() {
    check_root
    print_header "=== VER LOGS DE SERVICIOS BROOK ==="
    
    services=$(ls $SERVICE_DIR/brook_*.service 2>/dev/null | xargs -n1 basename 2>/dev/null)
    
    if [ -z "$services" ]; then
        print_error "No hay servicios de Brook configurados"
        pause
        return 1
    fi
    
    services_array=($services)
    
    echo "Seleccione el servicio para ver logs:"
    for i in "${!services_array[@]}"; do
        echo "$((i+1))) ${services_array[$i]}"
    done
    echo "$(( ${#services_array[@]} + 1 ))) Ver todos los logs"
    echo "$(( ${#services_array[@]} + 2 ))) Volver al menú principal"

    read -p "Seleccione opción: " log_choice
    
    if [ "$log_choice" = "$(( ${#services_array[@]} + 2 ))" ]; then
        return 0
    fi
    
    if [ "$log_choice" = "$(( ${#services_array[@]} + 1 ))" ]; then
        # Ver todos los logs
        for service in "${services_array[@]}"; do
            echo -e "\n${YELLOW}=== Logs de $service ===${NC}"
            journalctl -u $service --no-pager -l --lines=20
        done
    elif [ -n "$log_choice" ] && [ "$log_choice" -ge 1 ] && [ "$log_choice" -le "${#services_array[@]}" ]; then
        # Ver log específico
        selected_service="${services_array[$((log_choice-1))]}"
        echo -e "\n${YELLOW}=== Logs de $selected_service ===${NC}"
        journalctl -u $selected_service --no-pager -l --lines=50
    else
        print_error "Selección inválida"
        pause
        return 1
    fi
    
    pause
}

# Desinstalar Brook
uninstall_brook() {
    check_root
    print_header "=== DESINSTALAR BROOK ==="
    
    read -p "¿Está seguro de que desea desinstalar Brook? (s/n): " confirm
    if [[ ! $confirm =~ ^[Ss]$ ]]; then
        return 0
    fi
    
    print_status "Desinstalando Brook..."
    
    # Detener y deshabilitar servicios
    services=$(ls $SERVICE_DIR/brook_*.service 2>/dev/null | xargs -n1 basename 2>/dev/null)
    for service in $services; do
        systemctl stop $service 2>/dev/null
        systemctl disable $service 2>/dev/null
        print_status "Deteniendo y deshabilitando $service"
    done
    
    # Eliminar archivos
    rm -f $SERVICE_DIR/brook_*.service 2>/dev/null
    rm -rf $CONFIG_DIR 2>/dev/null
    rm -f $BROOK_BIN 2>/dev/null
    rm -rf $LOG_DIR 2>/dev/null
    
    # Recargar systemd
    systemctl daemon-reload
    
    print_success "Brook desinstalado completamente"
    pause
}

# Mostrar ayuda
show_help() {
    clear
    print_header "========================================"
    print_header "    GESTOR DE BROOK SERVER - MENÚ PRINCIPAL"
    print_header "========================================"
    echo
    echo "Opciones disponibles:"
    echo "1) Instalar Brook"
    echo "2) Configurar Brook"
    echo "3) Generar QR/Enlace"
    echo "4) Mostrar estado de servicios"
    echo "5) Reiniciar servicios"
    echo "6) Ver logs de servicios"
    echo "7) Desinstalar Brook"
    echo "8) Salir"
    echo
}

# Menú principal
main_menu() {
    while true; do
        show_help
        read -p "Seleccione una opción [1-8]: " option

        case $option in
            1) install_brook;;
            2) configure_brook;;
            3) generate_qr;;
            4) show_status;;
            5) restart_services;;
            6) show_logs;;
            7) uninstall_brook;;
            8) 
                print_status "Saliendo del gestor de Brook..."
                exit 0
                ;;
            *) 
                print_error "Opción inválida"
                pause
                ;;
        esac
    done
}

# Ejecución inicial
clear
check_root
check_dependencies
main_menu

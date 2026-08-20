#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== SSL Certificate Installer (Let's Encrypt) ===${NC}"

# Проверка root прав
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт от root${NC}"
    exit 1
fi

# 1. Запрос данных
read -p "Введите домен (например: example.ru): " DOMAIN
read -p "Введите email для уведомлений: " EMAIL
read -p "Использовать wildcard сертификат (*.example.ru)? [y/N]: " WILDCARD
WILDCARD=${WILDCARD:-N}

if [[ "$WILDCARD" =~ ^[Yy]$ ]]; then
    CERT_DOMAIN="*.$DOMAIN"
    echo -e "${YELLOW}Wildcard режим: $CERT_DOMAIN${NC}"
    echo -e "${YELLOW}ВНИМАНИЕ: Для wildcard нужен DNS challenge!${NC}"
    read -p "Какой DNS провайдер вы используете? (cloudflare/digitalocean/route53/other): " DNS_PROVIDER
else
    CERT_DOMAIN="$DOMAIN"
    echo -e "${YELLOW}Обычный сертификат для: $CERT_DOMAIN${NC}"
fi

read -p "Порт вашего веб-сервера (где работает hello-server): " WEB_PORT
WEB_PORT=${WEB_PORT:-80}

# 2. Установка зависимостей
echo -e "${GREEN}Установка необходимых пакетов...${NC}"

if command -v apt-get &> /dev/null; then
    apt-get update
    apt-get install -y certbot python3-certbot-nginx nginx
    if [[ "$WILDCARD" =~ ^[Yy]$ ]]; then
        apt-get install -y python3-certbot-dns-cloudflare python3-certbot-dns-digitalocean python3-certbot-dns-route53
    fi
elif command -v yum &> /dev/null; then
    yum install -y certbot python3-certbot-nginx nginx
    if [[ "$WILDCARD" =~ ^[Yy]$ ]]; then
        yum install -y python3-certbot-dns-cloudflare
    fi
elif command -v apk &> /dev/null; then
    apk add --no-cache certbot certbot-nginx nginx
    if [[ "$WILDCARD" =~ ^[Yy]$ ]]; then
        apk add --no-cache certbot-dns-cloudflare
    fi
else
    echo -e "${RED}Неподдерживаемая система${NC}"
    exit 1
fi

# 3. Настройка Nginx как reverse proxy
echo -e "${GREEN}Настройка Nginx...${NC}"

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$DOMAIN"

cat << EOF | tee "$NGINX_CONF" > /dev/null
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$CERT_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$CERT_DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        proxy_pass http://127.0.0.1:$WEB_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

# Создаем директорию для ACME challenges
mkdir -p /var/www/certbot

# Включаем сайт
if [ ! -L "$NGINX_LINK" ]; then
    ln -s "$NGINX_CONF" "$NGINX_LINK"
fi

# Тестируем конфигурацию nginx
nginx -t

# 4. Получение сертификата
echo -e "${GREEN}Получение SSL сертификата...${NC}"

if [[ "$WILDCARD" =~ ^[Yy]$ ]]; then
    # Wildcard сертификат через DNS challenge
    case "$DNS_PROVIDER" in
        cloudflare)
            read -p "Введите Cloudflare API Token: " -s CF_TOKEN
            echo
            export CF_DNS_API_TOKEN="$CF_TOKEN"
            
            certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials <(echo "dns_cloudflare_api_token = $CF_TOKEN") \
                -d "$CERT_DOMAIN" -d "$DOMAIN" \
                --email "$EMAIL" \
                --agree-tos \
                --non-interactive
            ;;
        digitalocean)
            read -p "Введите DigitalOcean API Token: " -s DO_TOKEN
            echo
            export DO_TOKEN
            
            certbot certonly \
                --dns-digitalocean \
                --dns-digitalocean-credentials <(echo "dns_digitalocean_token = $DO_TOKEN") \
                -d "$CERT_DOMAIN" -d "$DOMAIN" \
                --email "$EMAIL" \
                --agree-tos \
                --non-interactive
            ;;
        *)
            echo -e "${YELLOW}Для других DNS провайдеров настройте credentials файл вручную${NC}"
            echo "certbot certonly --manual --preferred-challenges dns -d $CERT_DOMAIN -d $DOMAIN --email $EMAIL --agree-tos"
            exit 1
            ;;
    esac
else
    # Обычный сертификат через HTTP challenge
    systemctl stop nginx 2>/dev/null || true
    
    certbot certonly \
        --standalone \
        -d "$CERT_DOMAIN" -d "www.$DOMAIN" \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive \
        --http-01-port 80
    
    systemctl start nginx
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}Не удалось получить сертификат!${NC}"
    exit 1
fi

# 5. Настройка автопродления
echo -e "${GREEN}Настройка автопродления...${NC}"

# Проверяем и настраиваем cron для certbot
if ! crontab -l | grep -q "certbot renew"; then
    (crontab -l 2>/dev/null; echo "0 0 1 * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    echo -e "${GREEN}Добавлено задание в cron для ежемесячной проверки${NC}"
fi

# Тестируем продление
echo -e "${YELLOW}Тестирование автопродления...${NC}"
certbot renew --dry-run

# 6. Перезапуск nginx
systemctl restart nginx
systemctl enable nginx

echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo -e "SSL сертификат установлен для: ${YELLOW}$CERT_DOMAIN${NC}"
echo -e "Сайт доступен: ${GREEN}https://$DOMAIN${NC}"
echo -e "Автопродление настроено (проверка 1-го числа каждого месяца)"
echo -e "${YELLOW}Срок действия сертификата: 90 дней${NC}"
echo ""
echo "Полезные команды:"
echo "  certbot certificates          - показать установленные сертификаты"
echo "  certbot renew                 - продлить сертификаты"
echo "  certbot delete --cert-name $DOMAIN - удалить сертификат"
echo "  systemctl status nginx        - статус nginx"
echo "  tail -f /var/log/nginx/error.log - логи nginx"

# Проверка SSL
echo ""
echo -e "${GREEN}Проверка SSL конфигурации:${NC}"
echo "Откройте: https://www.ssllabs.com/ssltest/analyze.html?d=$DOMAIN"

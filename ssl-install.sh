#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== SSL Certificate Installer (Let's Encrypt) ===${NC}"

# Проверка root прав
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт от root (sudo)${NC}"
    exit 1
fi

# 1. Запрос данных
read -p "Введите домен (например: example.ru): " DOMAIN
read -p "Введите email для уведомлений: " EMAIL

# Проверяем, что занимает порт 80
PORT_80_PID=$(sudo lsof -t -i:80 2>/dev/null | head -n 1)
if [ -n "$PORT_80_PID" ]; then
    echo -e "${YELLOW}Порт 80 занят процессом (PID: $PORT_80_PID).${NC}"
    echo -e "${YELLOW}Скрипт временно остановит его для получения сертификата, а затем настроит Nginx как прокси.${NC}"
    read -p "Введите внутренний порт для вашего приложения (hello-server), например 8080: " INTERNAL_PORT
    INTERNAL_PORT=${INTERNAL_PORT:-8080}
else
    INTERNAL_PORT=8080
fi

# 2. Установка зависимостей
echo -e "${GREEN}Установка необходимых пакетов...${NC}"
apt-get update -qq
apt-get install -y certbot python3-certbot-nginx nginx lsof

# 3. Временная остановка служб на 80 порту
if [ -n "$PORT_80_PID" ]; then
    echo -e "${YELLOW}Временная остановка службы на порту 80...${NC}"
    systemctl stop hello-server 2>/dev/null || true
    sleep 2
    # Если все еще занят, убиваем принудительно
    if sudo lsof -t -i:80 >/dev/null 2>&1; then
        sudo kill -9 $(sudo lsof -t -i:80) 2>/dev/null || true
    fi
fi

# 4. Получение сертификата (Standalone режим, так как порт 80 теперь свободен)
echo -e "${GREEN}Получение SSL сертификата...${NC}"
certbot certonly \
    --standalone \
    --preferred-challenges http \
    -d "$DOMAIN" -d "www.$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --http-01-port 80

if [ $? -ne 0 ]; then
    echo -e "${RED}Не удалось получить сертификат!${NC}"
    echo -e "${YELLOW}Проверьте, что домен $DOMAIN и www.$DOMAIN указывают на IP этого сервера.${NC}"
    echo -e "${YELLOW}Логи: /var/log/letsencrypt/letsencrypt.log${NC}"
    exit 1
fi

# 5. Настройка Nginx
echo -e "${GREEN}Настройка Nginx...${NC}"

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$DOMAIN"

# Удаляем старую конфигурацию если есть
rm -f "$NGINX_LINK"

cat << EOF | tee "$NGINX_CONF" > /dev/null
# HTTP -> HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        proxy_pass http://127.0.0.1:$INTERNAL_PORT;
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
ln -s "$NGINX_CONF" "$NGINX_LINK"

# Удаляем дефолтный сайт nginx, чтобы не мешал
rm -f /etc/nginx/sites-enabled/default

# Тестируем конфигурацию nginx
nginx -t
if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка в конфигурации Nginx!${NC}"
    exit 1
fi

# 6. Обновление hello-server на новый внутренний порт
if [ -f "/etc/systemd/system/hello-server.service" ]; then
    echo -e "${GREEN}Обновление hello-server на внутренний порт $INTERNAL_PORT...${NC}"
    sed -i -E "s/(ExecStart=.*server.py )[0-9]+/\1$INTERNAL_PORT/" /etc/systemd/system/hello-server.service
    systemctl daemon-reload
    systemctl restart hello-server
fi

# 7. Запуск Nginx
echo -e "${GREEN}Запуск Nginx...${NC}"
systemctl stop nginx 2>/dev/null || true
systemctl start nginx
systemctl enable nginx

# 8. Настройка автопродления
echo -e "${GREEN}Настройка автопродления...${NC}"
systemctl enable --now certbot.timer

# Добавляем хук для перезагрузки nginx после успешного продления
mkdir -p /etc/letsencrypt/renewal-hooks/deploy/
cat << 'EOF' | tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh > /dev/null
#!/bin/bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo -e "SSL сертификат установлен для: ${YELLOW}$DOMAIN${NC}"
echo -e "Сайт доступен: ${GREEN}https://$DOMAIN${NC}"
echo -e "Ваше приложение теперь работает на внутреннем порту: ${YELLOW}$INTERNAL_PORT${NC}"
echo -e "Nginx проксирует запросы с 80/443 на порт $INTERNAL_PORT."

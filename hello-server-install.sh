#!/bin/bash

# Цвета для красивого вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Hello Server Installer ===${NC}"

# 1. Проверяем наличие Python 3
if ! command -v python3 &> /dev/null; then
    echo -e "${YELLOW}Python 3 не найден. Пытаемся установить...${NC}"
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y python3
    elif command -v yum &> /dev/null; then
        sudo yum install -y python3
    else
        echo "Не удалось установить Python 3 автоматически. Установите его вручную."
        exit 1
    fi
fi

# 2. Запрашиваем данные у пользователя
read -p "Введите порт для веб-сервера [8080]: " PORT
PORT=${PORT:-8080}

read -p "Установить как системную службу (systemd) для автозапуска? [Y/n]: " INSTALL_SERVICE
INSTALL_SERVICE=${INSTALL_SERVICE:-Y}

# 3. Создаем директорию для сервера
INSTALL_DIR="/opt/hello-server"
sudo mkdir -p $INSTALL_DIR

# 4. Генерируем Python-скрипт
cat << 'EOF' | sudo tee $INSTALL_DIR/server.py > /dev/null
import http.server
import socketserver
import os
import platform
import socket
import sys
from datetime import datetime

# Забираем порт из аргументов или используем 8080
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

def get_sys_info():
    info = {}
    info['ОС'] = platform.platform()
    info['Hostname'] = socket.gethostname()
    info['Ядро'] = platform.release()
    info['CPU Cores'] = os.cpu_count()
    
    # RAM (Linux)
    try:
        with open('/proc/meminfo') as f:
            mem = {}
            for line in f:
                parts = line.split()
                if parts[0] in ('MemTotal:', 'MemAvailable:'):
                    mem[parts[0]] = int(parts[1]) * 1024
            total_gb = mem.get('MemTotal:', 0) / (1024**3)
            avail_gb = mem.get('MemAvailable:', 0) / (1024**3)
            info['RAM Total'] = f"{total_gb:.2f} GB"
            info['RAM Available'] = f"{avail_gb:.2f} GB ({avail_gb/total_gb*100:.1f}%)"
    except: info['RAM'] = 'N/A'

    # Disk
    try:
        st = os.statvfs('/')
        total_gb = (st.f_frsize * st.f_blocks) / (1024**3)
        free_gb = (st.f_frsize * st.f_bavail) / (1024**3)
        info['Disk Total'] = f"{total_gb:.2f} GB"
        info['Disk Free'] = f"{free_gb:.2f} GB ({free_gb/total_gb*100:.1f}%)"
    except: info['Disk'] = 'N/A'

    # Uptime
    try:
        with open('/proc/uptime') as f:
            uptime_sec = float(f.readline().split()[0])
            days = int(uptime_sec // 86400)
            hours = int((uptime_sec % 86400) // 3600)
            mins = int((uptime_sec % 3600) // 60)
            info['Uptime'] = f"{days}d {hours}h {mins}m"
    except: info['Uptime'] = 'N/A'

    return info

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'text/html; charset=utf-8')
        self.end_headers()
        
        info = get_sys_info()
        info_rows = "".join([f"<tr><td><b>{k}</b></td><td>{v}</td></tr>" for k, v in info.items()])
        
        html = f"""<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hello Server</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f4f7f6; color: #333; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }}
        .card {{ background: white; padding: 2rem; border-radius: 12px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); max-width: 500px; width: 90%; }}
        h1 {{ color: #2c3e50; margin-top: 0; text-align: center; }}
        table {{ width: 100%; border-collapse: collapse; margin-top: 1.5rem; }}
        td {{ padding: 8px 0; border-bottom: 1px solid #eee; }}
        td:first-child {{ color: #7f8c8d; width: 40%; }}
        .footer {{ text-align: center; margin-top: 1.5rem; font-size: 0.8rem; color: #95a5a6; }}
    </style>
</head>
<body>
    <div class="card">
        <h1>👋 Hello, World!</h1>
        <p style="text-align: center; color: #7f8c8d;">Сервер работает и чувствует себя отлично.</p>
        <table>{info_rows}</table>
        <div class="footer">Обновлено: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")} | Port: {PORT}</div>
    </div>
</body>
</html>"""
        self.wfile.write(html.encode('utf-8'))

    def log_message(self, format, *args):
        # Отключаем стандартный вывод логов в консоль, чтобы не мусорить
        return

if __name__ == '__main__':
    with socketserver.ThreadingTCPServer(("", PORT), Handler) as httpd:
        print(f"Server running on port {PORT}")
        httpd.serve_forever()
EOF

# 5. Настраиваем автозапуск (если пользователь согласился)
if [[ "$INSTALL_SERVICE" =~ ^[Yy]$ ]]; then
    SERVICE_FILE="/etc/systemd/system/hello-server.service"
    
    cat << EOF | sudo tee $SERVICE_FILE > /dev/null
[Unit]
Description=Hello Web Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 $INSTALL_DIR/server.py $PORT
Restart=always
User=root
WorkingDirectory=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable hello-server
    sudo systemctl restart hello-server
    echo -e "${GREEN}Служба установлена и запущена!${NC}"
else
    # Запуск просто в фоне (nohup)
    sudo pkill -f "python3 $INSTALL_DIR/server.py" 2>/dev/null
    sudo nohup python3 $INSTALL_DIR/server.py $PORT > /dev/null 2>&1 &
    echo -e "${GREEN}Сервер запущен в фоновом режиме.${NC}"
fi

echo -e "${GREEN}=== Готово! ===${NC}"
echo -e "Откройте в браузере: ${YELLOW}http://<ваш_IP>:$PORT${NC}"
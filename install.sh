#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 支持命令行传参指定 Reality 目标，不传则使用默认美西冷门高校节点
REALITY_DEST="${1:-www.ocf.berkeley.edu}"
ANYTLS_SNI="node-$(openssl rand -hex 3).us-west.net"

echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}   sing-box 抗封锁优化版 (VLESS-Reality + AnyTLS + BBR)        ${NC}"
echo -e "${GREEN}================================================================${NC}\n"

# 1. 交互式设置节点名称与订阅文件名（支持直接回车使用安全默认值）
read -p "请输入节点名称前缀 [默认: US-Node]: " NODE_PREFIX
NODE_PREFIX=${NODE_PREFIX:-US-Node}

read -p "请输入订阅文件名 (不含 .yaml 后缀，留空则生成32位随机安全名): " CUSTOM_SUB_NAME
if [ -z "$CUSTOM_SUB_NAME" ]; then
  SUB_FILE=$(openssl rand -hex 16)
else
  # 过滤非法字符，仅保留字母、数字、下划线和短横线
  SUB_FILE=$(echo "$CUSTOM_SUB_NAME" | tr -cd 'a-zA-Z0-9_-')
  [ -z "$SUB_FILE" ] && SUB_FILE=$(openssl rand -hex 16)
fi

echo -e "\n${YELLOW}[1/5] 开启系统 BBR 拥塞控制与网络内核调优...${NC}"
cat > /etc/sysctl.d/99-bbr.conf <<SYSCTL
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
SYSCTL
sysctl --system >/dev/null 2>&1
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control)
echo -e "当前拥塞控制算法: ${GREEN}${BBR_STATUS}${NC}"

echo -e "${YELLOW}[2/5] 清理旧服务并安装基础工具...${NC}"
systemctl stop nginx apache2 caddy sb-sub sing-box 2>/dev/null || true
apt-get update -qq && apt-get install -y -qq curl openssl python3

echo -e "${YELLOW}[3/5] 下载并安装 sing-box 核心...${NC}"
ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
SB_VER=${SB_VER:-1.11.4}

curl -sL -o /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"
tar -xzf /tmp/sb.tar.gz -C /tmp
mv /tmp/sing-box-${SB_VER}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/sb.tar.gz /tmp/sing-box-*

echo -e "${YELLOW}[4/5] 生成中性自签证书、随机密钥与订阅配置...${NC}"
mkdir -p /etc/sing-box/certs /etc/sing-box/sub
rm -f /etc/sing-box/sub/*.yaml

openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/certs/privkey.pem 2>/dev/null
openssl req -new -x509 -days 3650 -key /etc/sing-box/certs/privkey.pem \
  -out /etc/sing-box/certs/fullchain.pem \
  -subj "/C=US/ST=California/L=San Jose/O=Cloud Infrastructure/CN=${ANYTLS_SNI}" 2>/dev/null

UUID=$(sing-box generate uuid)
KEY_PAIR=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_PAIR" | awk '/PrivateKey/ {print $2}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | awk '/PublicKey/ {print $2}')
SHORT_ID=$(openssl rand -hex 8)
ANYTLS_PASSWORD=$(openssl rand -base64 16)
SERVER_IP=$(curl -s4 ifconfig.me)

VLESS_NAME="${NODE_PREFIX}-VLESS-443"
ANYTLS_NAME="${NODE_PREFIX}-AnyTLS-8443"

cat > /etc/sing-box/config.json <<CONF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
      "users": [{ "uuid": "${UUID}", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DEST}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_DEST}", "server_port": 443 },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [{ "name": "user1", "password": "${ANYTLS_PASSWORD}" }],
      "padding_scheme": [
        "stop=8", "0=30-30", "1=100-400",
        "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
        "3=9-9,500-1000", "4=500-1000", "5=500-1000", "6=500-1000", "7=500-1000"
      ],
      "tls": {
        "enabled": true,
        "server_name": "${ANYTLS_SNI}",
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
CONF

# 保存元数据，方便后续随时一键修改订阅名与节点名
cat > /etc/sing-box/meta.env <<META
SERVER_IP="${SERVER_IP}"
UUID="${UUID}"
REALITY_DEST="${REALITY_DEST}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
ANYTLS_PASSWORD="${ANYTLS_PASSWORD}"
ANYTLS_SNI="${ANYTLS_SNI}"
SUB_FILE="${SUB_FILE}"
VLESS_NAME="${VLESS_NAME}"
ANYTLS_NAME="${ANYTLS_NAME}"
META

# 生成 Clash 订阅文件函数写入快捷命令 /usr/local/bin/sb
cat > /usr/local/bin/sb <<'MANAGE'
#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

source /etc/sing-box/meta.env

render_sub() {
  rm -f /etc/sing-box/sub/*.yaml
  cat > /etc/sing-box/sub/${SUB_FILE}.yaml <<SUB
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
unified-delay: true
tcp-concurrent: true

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver: [223.5.5.5, 119.29.29.29]
  fallback: [https://1.1.1.1/dns-query, https://8.8.8.8/dns-query]

proxies:
  - name: "${VLESS_NAME}"
    type: vless
    server: ${SERVER_IP}
    port: 443
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_DEST}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome

  - name: "${ANYTLS_NAME}"
    type: anytls
    server: ${SERVER_IP}
    port: 8443
    password: ${ANYTLS_PASSWORD}
    client-fingerprint: chrome
    udp: true
    sni: ${ANYTLS_SNI}
    alpn: [h2, http/1.1]
    skip-cert-verify: true

proxy-groups:
  - name: "节点选择"
    type: select
    proxies: ["自动测速", "${VLESS_NAME}", "${ANYTLS_NAME}", DIRECT]
  - name: "自动测速"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies: ["${VLESS_NAME}", "${ANYTLS_NAME}"]

rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
SUB
}

if [ "$1" = "init" ]; then
  render_sub
  exit 0
fi

clear
echo -e "${GREEN}=== sing-box 订阅与节点管理面板 ===${NC}"
echo -e "当前订阅链接: ${CYAN}http://${SERVER_IP}/${SUB_FILE}.yaml${NC}"
echo -e "当前节点 1  : ${YELLOW}${VLESS_NAME}${NC}"
echo -e "当前节点 2  : ${YELLOW}${ANYTLS_NAME}${NC}\n"
echo "1. 修改订阅文件名"
echo "2. 修改节点显示名称"
echo "3. 查看服务运行状态"
echo "0. 退出"
read -p "请选择操作 [0-3]: " OPT

case $OPT in
  1)
    read -p "请输入新的订阅文件名 (不含 .yaml，留空则随机生成): " NEW_SUB
    if [ -z "$NEW_SUB" ]; then
      SUB_FILE=$(openssl rand -hex 16)
    else
      SUB_FILE=$(echo "$NEW_SUB" | tr -cd 'a-zA-Z0-9_-')
    fi
    sed -i "s|^SUB_FILE=.*|SUB_FILE=\"${SUB_FILE}\"|" /etc/sing-box/meta.env
    render_sub
    echo -e "\n${GREEN}修改成功！新订阅链接:${NC} ${CYAN}http://${SERVER_IP}/${SUB_FILE}.yaml${NC}"
    ;;
  2)
    read -p "请输入 VLESS 节点新名称 [当前: ${VLESS_NAME}]: " NEW_VLESS
    read -p "请输入 AnyTLS 节点新名称 [当前: ${ANYTLS_NAME}]: " NEW_ANYTLS
    [ -n "$NEW_VLESS" ] && VLESS_NAME="$NEW_VLESS"
    [ -n "$NEW_ANYTLS" ] && ANYTLS_NAME="$NEW_ANYTLS"
    sed -i "s|^VLESS_NAME=.*|VLESS_NAME=\"${VLESS_NAME}\"|" /etc/sing-box/meta.env
    sed -i "s|^ANYTLS_NAME=.*|ANYTLS_NAME=\"${ANYTLS_NAME}\"|" /etc/sing-box/meta.env
    render_sub
    echo -e "\n${GREEN}节点名称已更新！在 Clash 客户端点击【更新订阅】即可生效。${NC}"
    ;;
  3)
    systemctl status sing-box sb-sub --no-pager
    ;;
  *)
    exit 0
    ;;
esac
MANAGE

chmod +x /usr/local/bin/sb
/usr/local/bin/sb init

cat > /etc/systemd/system/sing-box.service <<SVC
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/sb-sub.service <<SUBSVC
[Unit]
Description=Clash Sub Server
After=network.target

[Service]
WorkingDirectory=/etc/sing-box/sub
ExecStart=/usr/bin/python3 -m http.server 80
Restart=always

[Install]
WantedBy=multi-user.target
SUBSVC

echo -e "${YELLOW}[5/5] 启动所有服务...${NC}"
systemctl daemon-reload
systemctl enable sing-box sb-sub >/dev/null 2>&1
systemctl restart sing-box sb-sub

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${YELLOW}【BBR 状态】${NC} ${BBR_STATUS} (已生效)"
echo -e "${YELLOW}【Reality 目标】${NC} ${REALITY_DEST}"
echo -e "${YELLOW}【Clash 订阅链接】${NC} ${CYAN}http://${SERVER_IP}/${SUB_FILE}.yaml${NC}\n"
echo -e "${YELLOW}【备用 VLESS 单节点】${NC}"
echo -e "vless://${UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DEST}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${VLESS_NAME}\n"
echo -e "${GREEN}提示: 以后在 SSH 中随时输入 ${CYAN}sb${GREEN} 即可一键修改订阅文件名或节点名字！${NC}"
echo -e "${GREEN}================================================================${NC}"

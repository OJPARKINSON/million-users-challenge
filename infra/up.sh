#!/usr/bin/env bash
# After `tofu apply`: copy this checkout to the boxes and set them up like box/ describes.
#   bash infra/up.sh [server dir, default examples/go]
# db: Postgres 18 + seed. app: box tuning + your server (systemd unit "challenge"). lg1: mload + test deps.
# Logs go to infra/logs/<box>.log. Ends by running the 42 checks from lg1 against the app box.
set -euo pipefail
cd "$(dirname "$0")"
APP=$(tofu output -raw app_ip) DB=$(tofu output -raw db_ip) LG=$(tofu output -raw lg1_ip)
SERVER=${1:-examples/go}
PW=$(openssl rand -hex 16)
# Offer only this key: an agent with many keys hits the server's auth-attempt limit first.
# With the 1Password agent, the .pub file is enough: the agent signs with the matching private key.
KEY=${KEY:-~/.ssh/hetzner.pub}
[ -f "$KEY" ] || { echo "no $KEY: save your SSH public key there (e.g. ssh-add -L, or op read \"op://<vault>/<item>/public key\")"; exit 1; }
SSH="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
mkdir -p logs
cd ..
[ -f "$SERVER/start.sh" ] || { echo "no $SERVER/start.sh"; exit 1; }

for ip in $APP $DB $LG; do
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true  # fresh boxes each session can reuse an IP with a new host key
  for i in $(seq 60); do $SSH root@$ip true 2>/dev/null && break; sleep 2; done
  $SSH root@$ip true || { echo "can't ssh to $ip"; exit 1; }
  # first boot: wait for cloud-init and let apt wait for the dpkg lock instead of failing
  $SSH root@$ip 'cloud-init status --wait >/dev/null; echo "DPkg::Lock::Timeout \"600\";" > /etc/apt/apt.conf.d/99lock'
  # Hetzner can attach the private network after first boot; cloud-init then never configures it
  $SSH root@$ip 'ip -4 addr show enp7s0 | grep -q inet || { printf "network:\n  version: 2\n  ethernets:\n    enp7s0:\n      dhcp4: true\n" > /etc/netplan/60-private.yaml; chmod 600 /etc/netplan/60-private.yaml; netplan apply; sleep 3; }; ip -4 -br addr show enp7s0 | grep -q 10.0.0. || { echo "no private IP on $(hostname)"; exit 1; }'
  # infra/ holds the token file and tofu state: never copy it to a box
  rsync -az -e "$SSH" --exclude .git --exclude infra --exclude bench/mload/mload ./ root@$ip:repo/
done
echo "copied repo to app $APP, db $DB, lg1 $LG"

$SSH root@$DB "cd repo && APP_BOX=10.0.0.2 FEED_PASSWORD=$PW bash box/setup-db-box.sh && sudo -u postgres psql -qX -c \"ALTER ROLE feed PASSWORD '$PW'\"" > infra/logs/db.log 2>&1 & db=$!

$SSH root@$APP "SERVER=$SERVER PW=$PW bash -s" > infra/logs/app.log 2>&1 <<'EOF' & app=$!
set -euo pipefail
cd repo && bash box/setup-app-box.sh
# setup-app-box.sh tunes the public NIC; the load arrives on the private one, so tune it the same way
NIC=$(ip -o route get 10.0.0.10 | grep -o 'dev [^ ]*' | cut -d' ' -f2)
printf '%x' $(( (1 << $(nproc)) - 1 )) > /sys/class/net/$NIC/queues/rx-0/rps_cpus
echo 65536 > /sys/class/net/$NIC/queues/rx-0/rps_flow_cnt
tc qdisc replace dev $NIC root fq limit 200000 flow_limit 1000 buckets 262144
echo "private NIC $NIC tuned"
# Hetzner routes the alias IPs (main.tf) to the box but doesn't configure them in the OS
for a in 10.0.0.3 10.0.0.4 10.0.0.5; do ip addr replace $a/32 dev $NIC; done
rm -rf /opt/challenge/current && cp -r "$SERVER" /opt/challenge/current && chown -R challenge: /opt/challenge
bash /opt/challenge/current/install.sh
sudo -u challenge bash /opt/challenge/current/build.sh
cat > /etc/challenge/env <<E
DATABASE_URL=postgres://feed:$PW@10.0.0.10:5432/feed
JWT_SECRET=million-users-challenge
HOST=0.0.0.0
PORT=80
EXTRA_PORT=81
E
EOF

$SSH root@$LG bash -s > infra/logs/lg1.log 2>&1 <<'EOF' & lg=$!
set -euo pipefail
apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq
bash repo/examples/go/install.sh
cd repo/bench/mload && PATH=/usr/local/go/bin:$PATH go build -o mload .
printf 'net.ipv4.ip_local_port_range = 1024 65535\nfs.nr_open = 4194304\n' > /etc/sysctl.d/90-lg.conf
sysctl -q --system
EOF

wait $db && echo "db ready" || { echo "db setup failed, see infra/logs/db.log"; exit 1; }
wait $app && echo "app built" || { echo "app setup failed, see infra/logs/app.log"; exit 1; }
wait $lg && echo "lg1 ready" || { echo "lg1 setup failed, see infra/logs/lg1.log"; exit 1; }

$SSH root@$APP 'systemctl restart challenge; for i in $(seq 60); do curl -fs localhost/health >/dev/null && exit 0; sleep 1; done; journalctl -u challenge -n 30; exit 1'
$SSH root@$LG 'cd repo && bash test/test.sh http://10.0.0.2:80'
# the checks wrote to the database: start the load test from a fresh copy
$SSH root@$DB 'bash repo/box/reset-db.sh' && $SSH root@$APP 'systemctl restart challenge'
echo "ready. load test: ssh -i $KEY -o IdentitiesOnly=yes root@$LG, then cd repo && ulimit -n 1048576 && ./bench/mload/mload -target 10.0.0.2,10.0.0.3,10.0.0.4,10.0.0.5 -ports 80,81 -users 20000 -ramp 60s -hold 2m -gzip -think-scale 2.5 -tokens seed/tokens.json -out run.json"

#!/bin/bash
# =============================================================================
# setup_client_machine.sh — Prepare Machine B as Dedicated Client
# =============================================================================
# Run ONCE from Machine A to install all required tools and scripts on
# Machine B. After this runs, Machine B is ready to accept measurement
# commands via SSH from run_workload.sh and run_cloud_workload.sh.
#
# Usage (from Machine A, project root):
#   bash scripts/utils/setup_client_machine.sh
# =============================================================================

set -euo pipefail

PROJECT_DIR="/home/dem/major_project/edge_cloud_study"
MEMORY_FILE="$PROJECT_DIR/AGENT_MEMORY.json"
UTILS_DIR="$PROJECT_DIR/scripts/utils"

# --- Read Machine B config from AGENT_MEMORY.json ---
CLIENT_IP=$(python3 -c "import json; m=json.load(open('$MEMORY_FILE')); print(m['environment']['client_machine_ip'])")
CLIENT_USER=$(python3 -c "import json; m=json.load(open('$MEMORY_FILE')); print(m['environment']['client_machine_user'])")
SSH_KEY=$(python3 -c "import json; m=json.load(open('$MEMORY_FILE')); print(m['environment']['client_machine_ssh_key'])")
RAPL=$(python3 -c "import json; m=json.load(open('$MEMORY_FILE')); print(str(m['environment'].get('client_machine_rapl_available', False)).lower())")

REMOTE="${CLIENT_USER}@${CLIENT_IP}"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i $SSH_KEY $REMOTE"
SCP_CMD="scp -o StrictHostKeyChecking=no -i $SSH_KEY"

echo "============================================"
echo "  Machine B Setup"
echo "============================================"
echo "  Target:   $REMOTE"
echo "  SSH Key:  $SSH_KEY"
echo "  RAPL:     $RAPL"
echo "============================================"

# === STEP 1: Verify SSH connectivity ===
echo "[0/7] Testing SSH connectivity to Machine B..."
if ! $SSH_CMD "echo OK" | grep -q OK; then
    echo "ERROR: Cannot reach Machine B at $CLIENT_IP"
    echo "  Check: ssh -i $SSH_KEY $REMOTE"
    exit 1
fi
echo "  SSH OK."

# === STEP 2: Create directory structure on Machine B ===
echo "[1/7] Creating directory structure on Machine B..."
$SSH_CMD "mkdir -p \
    ~/edge_cloud_study/logs/scaphandre \
    ~/edge_cloud_study/logs/powerstat \
    ~/edge_cloud_study/tmp"
echo "  Directories created."

# === STEP 3: Install system dependencies ===
echo "[2/7] Installing system dependencies on Machine B..."
$SSH_CMD "sudo apt-get update -qq"
$SSH_CMD "sudo apt-get install -y powerstat powertop python3 python3-pip iperf3"
# Try pip install; fall back to --break-system-packages for Ubuntu 23+
$SSH_CMD "pip3 install --quiet psutil pandas 2>/dev/null || \
          pip3 install --break-system-packages --quiet psutil pandas"
echo "  System dependencies installed."

# === STEP 4: Install Scaphandre ===
if [[ "$RAPL" == "true" ]]; then
    echo "[3/7] Installing Scaphandre on Machine B (RAPL available)..."
    SCAPH_LOCAL=$(which scaphandre 2>/dev/null || echo "")
    if [[ -n "$SCAPH_LOCAL" ]]; then
        echo "  Copying scaphandre binary from Machine A..."
        $SCP_CMD "$SCAPH_LOCAL" "$REMOTE:/tmp/scaphandre_bin"
        $SSH_CMD "sudo mv /tmp/scaphandre_bin /usr/local/bin/scaphandre && \
                  sudo chmod +x /usr/local/bin/scaphandre"
    else
        echo "  Downloading scaphandre v1.0.0 from GitHub..."
        $SSH_CMD "wget -q -O /tmp/scaphandre_bin \
            https://github.com/hubblo-org/scaphandre/releases/download/v1.0.0/scaphandre-x86_64-unknown-linux-musl \
            && sudo mv /tmp/scaphandre_bin /usr/local/bin/scaphandre \
            && sudo chmod +x /usr/local/bin/scaphandre"
    fi
    echo "  Scaphandre installed."
else
    echo "[3/7] Skipping Scaphandre (RAPL not available — PowerStat is primary tool)."
fi

# === STEP 5: Configure passwordless sudo for measurement tools ===
echo "[4/7] Configuring passwordless sudo for measurement tools..."
$SSH_CMD "echo '${CLIENT_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/scaphandre, /usr/bin/powerstat, /usr/bin/pkill' \
    | sudo tee /etc/sudoers.d/edge-cloud-measurement > /dev/null && \
    sudo chmod 440 /etc/sudoers.d/edge-cloud-measurement"
echo "  Sudoers configured."

# === STEP 6: Copy utility scripts to Machine B ===
echo "[5/7] Copying utility scripts to Machine B..."
$SCP_CMD "$UTILS_DIR/measure_client_energy.py"  "$REMOTE:~/edge_cloud_study/measure_client_energy.py"
$SCP_CMD "$UTILS_DIR/parse_scaphandre.py"        "$REMOTE:~/edge_cloud_study/parse_scaphandre.py"
$SCP_CMD "$UTILS_DIR/parse_powerstat.py"         "$REMOTE:~/edge_cloud_study/parse_powerstat.py"
$SCP_CMD "$UTILS_DIR/client_daemon.sh"           "$REMOTE:~/edge_cloud_study/client_daemon.sh"
$SSH_CMD "chmod +x ~/edge_cloud_study/client_daemon.sh"
echo "  Scripts copied."

# === STEP 7: Verify installation ===
echo "[6/7] Verifying installation on Machine B..."

echo -n "  scaphandre:  "
$SSH_CMD "scaphandre --version 2>&1 || echo SCAPH_UNAVAILABLE"

echo -n "  powerstat:   "
$SSH_CMD "powerstat -h 2>&1 | head -1"

echo -n "  python3:     "
$SSH_CMD "python3 --version"

echo -n "  psutil:      "
$SSH_CMD "python3 -c 'import psutil; print(\"OK\")'"

echo -n "  iperf3:      "
$SSH_CMD "iperf3 --version 2>&1 | head -1"

echo -n "  daemon:      "
$SSH_CMD "test -x ~/edge_cloud_study/client_daemon.sh && echo OK || echo MISSING"

# === STEP 8: Update AGENT_MEMORY.json ===
echo "[7/7] Updating AGENT_MEMORY.json..."
python3 - << PYEOF
import json
from datetime import datetime

with open("$MEMORY_FILE") as f:
    mem = json.load(f)

mem["environment"]["client_machine_tools_installed"] = True
mem["environment"]["client_machine_ready"] = True
mem["last_updated"] = datetime.now().isoformat()

step = "9.1 Machine B setup complete — tools installed, scripts copied, sudoers configured"
if step not in mem.get("completed_steps", []):
    mem.setdefault("completed_steps", []).append(step)

with open("$MEMORY_FILE", "w") as f:
    json.dump(mem, f, indent=2)

print("  AGENT_MEMORY.json: client_machine_ready = true, client_machine_tools_installed = true")
PYEOF

echo ""
echo "============================================"
echo "  Machine B setup complete!"
echo "  $REMOTE is ready for client measurement."
echo ""
echo "  Test connectivity:"
echo "    ssh -i $SSH_KEY $REMOTE 'bash ~/edge_cloud_study/client_daemon.sh'"
echo "============================================"

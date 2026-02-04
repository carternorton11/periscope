#!/bin/bash
set -e # Exit on error within the remote script

# --- SAFETY GUARD ---
# Ensure we strictly have a target job name so we don't affect other jobs.
if [[ -z "${SLURM_JOB_NAME}" ]]; then
    echo "❌ ERROR: SLURM_JOB_NAME is not set. Aborting to protect other jobs."
    exit 1
fi

# --- Helper Function: Clean up Remote Node ---
function cleanup_node() {
    local node=$1
    echo "   -> 🧹 Connecting to $node to kill orphaned VS Code processes..."
    # 1. 'vscode-server' & 'vscode-ipc': Standard remote server processes (match full command line)
    # 2. 'code': The binary itself (match EXACT name only to avoid killing scripts like 'my_code.py')
    ssh -o StrictHostKeyChecking=no -i "${CLUSTER_SSH_KEY}" "$node" \
        "pkill -u \$(whoami) -f 'vscode-server' || true; \
         pkill -u \$(whoami) -f 'vscode-ipc' || true; \
         pkill -u \$(whoami) -x 'code' || true" \
        || echo "      (Warning: Failed to connect to $node for cleanup. Skipping.)"
}

echo "🔎 Checking for existing '${SLURM_JOB_NAME}' jobs..."

# Get list of old job IDs strictly matching the specific Job Name
OLD_JOBS=$(squeue -u "${HPC_USER}" -h -o "%A" -n "${SLURM_JOB_NAME}")

if [[ -n "$OLD_JOBS" ]]; then
    for JOB_ID in $OLD_JOBS; do
        # 1. Identify the node the job is running on
        JOB_NODE=$(squeue -h -j "$JOB_ID" -o "%N")
        
        # 2. Attempt to clean up processes on that node BEFORE cancelling
        if [[ -n "$JOB_NODE" && "$JOB_NODE" != "Nodes_not_assigned" ]]; then
            cleanup_node "$JOB_NODE"
        fi

        # 3. Cancel the job
        echo "   -> 🚫 Cancelling old tunnel job $JOB_ID..."
        scancel "$JOB_ID"
    done
    
    echo "   -> 💤 Waiting for scheduler to process cancellations..."
    sleep 3 
else
    echo "   -> No old tunnel jobs found."
fi

# --- Shared Filesystem Cleanup ---
# Removes specific lock files that block reconnection
echo "🧹 Cleaning up stale lock files in ~/.vscode-server..."
find ~/.vscode-server -name "*lock*" -delete 2>/dev/null || true
find ~/.vscode-server -name "SingletonLock*" -delete 2>/dev/null || true

echo "🚀 Submitting new tunnel job to Slurm..."

# --- Submit New Job with Timeout Safety ---
JOB_ID=$(sbatch --parsable \
    --job-name="${SLURM_JOB_NAME}" \
    --nodes=1 \
    --ntasks-per-node=1 \
    --cpus-per-task=2 \
    --mem-per-cpu=4G \
    --partition="${PARTITION}" \
    --time=10:00:00 \
    --signal=B:SIGUSR1@90 \
    --output="${LOG_OUTPUT_PATH}" \
    << 'SBATCH_SCRIPT'
#!/bin/bash
echo "Tunnel job starting on node $(hostname)..."

# 1. Local Pre-flight Cleanup (cleans /tmp on the new node)
echo "Running pre-flight cleanup on $(hostname)..."
pkill -u $(whoami) -f "vscode-server" || true
pkill -u $(whoami) -x "code" || true
rm -rf /tmp/vscode-ipc* 2>/dev/null || true

# 2. Define Self-Destruct Handler (for timeouts)
cleanup_handler() {
    echo "⚠️ TIMEOUT IMMINENT. Performing clean shutdown..."
    if [[ -n "$SSHD_PID" ]]; then
        kill "$SSHD_PID" 2>/dev/null || true
    fi
    # Aggressive cleanup of all VS Code related processes
    pkill -u $(whoami) -f "vscode-server" || true
    pkill -u $(whoami) -f "vscode-ipc" || true
    pkill -u $(whoami) -x "code" || true
    
    # Clear locks
    find ~/.vscode-server -name "*lock*" -delete 2>/dev/null || true
    exit 0
}

# 3. Trap Signals (Timeout or Manual Cancel)
trap 'cleanup_handler' SIGUSR1 SIGTERM SIGINT

echo "Starting SSHD on port ${TUNNEL_PORT}..."

# 4. Start SSHD in Background & Wait
/usr/sbin/sshd -D -p ${TUNNEL_PORT} -f /dev/null -h ${CLUSTER_SSH_KEY} &
SSHD_PID=$!
echo "SSHD running (PID $SSHD_PID). Waiting..."
wait "$SSHD_PID"
SBATCH_SCRIPT
)

echo "✅ Job submitted with ID: $JOB_ID"

# --- Wait for Start ---
echo "⏳ Waiting for job to start..."
while true; do
    JOB_STATE=$(squeue -h -j "$JOB_ID" -o %T)
    if [[ "$JOB_STATE" == "RUNNING" ]]; then
        NODE=$(squeue -h -j "$JOB_ID" -o %N)
        echo "✅ Job $JOB_ID is now running on node: $NODE"
        break
    elif [[ "$JOB_STATE" == "" || "$JOB_STATE" == "COMPLETED" || "$JOB_STATE" == "FAILED" || "$JOB_STATE" == "CANCELLED" ]]; then
        echo "❌ Job failed to start (State: $JOB_STATE). Check logs."
        exit 1
    fi
    sleep 1
done

echo "🔗 Tunnel is active."
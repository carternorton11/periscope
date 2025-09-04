#!/bin/bash
set -e # Exit on error within the remote script

echo "🧹 Searching for and cancelling any old '${SLURM_JOB_NAME}' jobs..."
# Find any running jobs with the same name and cancel them
OLD_JOBS=$(squeue -u "${HPC_USER}" -h -o "%A" -n "${SLURM_JOB_NAME}")
if [[ -n "$OLD_JOBS" ]]; then
    for JOB_ID in $OLD_JOBS; do
        echo "   -> Cancelling old job $JOB_ID..."
        scancel "$JOB_ID"
    done
    sleep 2 # Give Slurm a moment to process the cancellations
else
    echo "   -> No old tunnels found."
fi

echo "Submitting new tunnel job to Slurm..."

# Use sbatch to submit the job. The script for the job is provided via a heredoc.
JOB_ID=$(sbatch --parsable \
    --job-name="${SLURM_JOB_NAME}" \
    --nodes=1 \
    --ntasks-per-node=1 \
    --cpus-per-task=2 \
    --mem-per-cpu=4G \
    --partition="${PARTITION}" \
    --time=10:00:00 \
    --output="${LOG_OUTPUT_PATH}" \
    << 'SBATCH_SCRIPT'
#!/bin/bash
echo "Tunnel job starting on node $(hostname)..."
echo "Starting SSHD on port ${TUNNEL_PORT}..."
# Start a new SSH daemon on the compute node, listening on the specified port.
# -D: Do not detach and become a daemon.
# -e: Log errors to stderr.
# -f /dev/null: Use a null config file for isolation.
# -p: Specify port number.
# -h: Use the provided SSH key for host authentication
/usr/sbin/sshd -D -p ${TUNNEL_PORT} -f /dev/null -h ${CLUSTER_SSH_KEY}
SBATCH_SCRIPT
)

echo "Job submitted with ID: $JOB_ID"

# --- Wait for the job to be in the Running state ---
echo "⏳ Waiting for job to start... (This may take a moment)"
while true; do
    # Query the state of our specific job.
    JOB_STATE=$(squeue -h -j "$JOB_ID" -o %T)
    if [[ "$JOB_STATE" == "RUNNING" ]]; then
        NODE=$(squeue -h -j "$JOB_ID" -o %N)
        echo "✅ Job $JOB_ID is now running on node: $NODE"
        break
    elif [[ "$JOB_STATE" == "" || "$JOB_STATE" == "COMPLETED" || "$JOB_STATE" == "FAILED" || "$JOB_STATE" == "CANCELLED" ]]; then
        echo "❌ Job $JOB_ID entered state '$JOB_STATE' unexpectedly. Aborting."
        echo "   Check the log for details: ${LOG_OUTPUT_PATH//\%j/$JOB_ID}"
        exit 1
    fi
    # Wait for 1 second before checking again to avoid spamming the scheduler.
    sleep 1
done

echo "🔗 Tunnel is active. Exiting login node."
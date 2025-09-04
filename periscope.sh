#!/bin/bash
#
# Periscope: A script to simplify creating and connecting to a VS Code tunnel on an HPC cluster.
# This script handles initial configuration, SSH setup, SLURM job submission, and VS Code launch.
#

# --- Global Constants and Configuration ---
# Set the configuration directory to the directory where this script is located.
CONFIG_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CONFIG_FILE="${CONFIG_DIR}/config.txt"

# Variables that must be present in the config file
REQUIRED_VARS=(
    HPC_USER
    HPC_LOGIN_NODE
    PARTITION
    REMOTE_WORKSPACE_PATH
    LOCAL_SSH_KEY
    CLUSTER_SSH_KEY
    TUNNEL_PORT
    TUNNEL_HOST_NAME
    SLURM_JOB_NAME
    LOG_OUTPUT_PATH
    SCHEDULER_SCRIPT_PATH
)

# --- Function Definitions ---

## -----------------------------------------------------------------------------
## Configuration and Setup Functions
## -----------------------------------------------------------------------------

# Creates a template configuration file for the user to fill out.
function create_config_template() {
    echo "--- Creating Configuration Template ---"
    # Use a here-document to write the template
    cat > "${CONFIG_FILE}" << EOF
# Periscope Configuration File
# Please fill in the values for the variables below.
# Do not leave any values blank.

# Your username on the HPC cluster.
# Example: HPC_USER=bsmith1
HPC_USER=

# The address of the HPC login node.
# Example: HPC_LOGIN_NODE=jhpce01.jhsph.edu
HPC_LOGIN_NODE=

# The SLURM partition to use for the tunnel job.
# This is typically a compute partition.
# Example: PARTITION=shared
PARTITION=

# The absolute path to your desired workspace directory on the HPC.
# This is where VS Code will open.
# Example: REMOTE_WORKSPACE_PATH=/dcs07/bill/data
REMOTE_WORKSPACE_PATH=

# The absolute local path to the private SSH key you use to access the HPC.
# Use '~' for your home directory.
# Example: LOCAL_SSH_KEY=~/.ssh/id_rsa
LOCAL_SSH_KEY=

# The absolute path to an SSH key on the cluster for node-to-node communication.
# This key must exist on the cluster. You can generate one with:
# ssh-keygen -t rsa -b 4096 -f ~/.ssh/cluster_key -N ""
# Example: CLUSTER_SSH_KEY=/users/bsmith1/.ssh/cluster_key
CLUSTER_SSH_KEY=

# The port to use for the SSH tunnel. Must be an unused port.
# A random port between 2000-8000 is suggested.
# Example: TUNNEL_PORT=4582
TUNNEL_PORT=

# --- Pre-filled Variables (Modify only if you know what you are doing) ---

# The hostname alias for the tunnel in your local SSH config.
TUNNEL_HOST_NAME=jhpce-vscode-tunnel

# The name for the SLURM job.
SLURM_JOB_NAME=vscode-tunnel-job

# The path for SLURM log files. %x is job name, %j is job ID.
# This path is relative to your REMOTE_WORKSPACE_PATH.
LOG_OUTPUT_PATH=\${REMOTE_WORKSPACE_PATH}/.periscope/logs/%x-%j.log

# The path to the scheduler script. This is set automatically.
SCHEDULER_SCRIPT_PATH=${CONFIG_DIR}/scheduler_scripts/slurm_script.sh
EOF
    echo "✅ Template created at ${CONFIG_FILE}"
}

# Checks if a config file exists. If not, creates one. If it exists, it loads and validates it.
function check_or_run_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "Welcome to Periscope!"
        echo "No configuration file found. A template will be created for you."
        create_config_template
        echo "Please edit the configuration file with your details and run this script again."
        exit 0
    fi

    echo "Found configuration at ${CONFIG_FILE}."
    echo "Loading and validating settings..."

    # Load the configuration into the script's environment
    set -a # Automatically export all variables
    # We source the file, but redirect output to null to hide it
    # and check the exit code to catch syntax errors.
    if ! source "${CONFIG_FILE}" >/dev/null 2>&1; then
        echo "❌ Error parsing ${CONFIG_FILE}. Please check for syntax errors."
        exit 1
    fi
    set +a

    # Check for missing variables
    local MISSING_VARS=()
    for var in "${REQUIRED_VARS[@]}"; do
        # Use indirect expansion to check if the variable is unset or empty
        if [[ -z "${!var}" ]]; then
            MISSING_VARS+=("$var")
        fi
    done

    if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
        echo "❌ Configuration is incomplete. The following variables are missing or empty in ${CONFIG_FILE}:"
        printf " - %s\n" "${MISSING_VARS[@]}"
        echo "Please fill them in and run the script again."
        exit 1
    fi

    echo "✅ Settings loaded and validated."
}

## -----------------------------------------------------------------------------
## Pre-flight Checks
## -----------------------------------------------------------------------------

# Runs checks that require a valid, loaded configuration.
function run_post_config_checks() {
    echo "--- Running Post-Configuration Checks ---"

    # Expand the tilde in the key path manually
    LOCAL_SSH_KEY_EXPANDED="${LOCAL_SSH_KEY/#\~/$HOME}"

    # 1. Test SSH connection to login node
    echo "Checking connection to HPC login node..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -i "${LOCAL_SSH_KEY_EXPANDED}" "${HPC_USER}@${HPC_LOGIN_NODE}" exit; then
        echo "❌ Connection failed with ${HPC_USER}@${HPC_LOGIN_NODE} using key ${LOCAL_SSH_KEY}."
        echo "Please check your HPC_USER, HPC_LOGIN_NODE, and LOCAL_SSH_KEY values in ${CONFIG_FILE}."
        exit 1
    fi
    echo "✅ Connection to login node successful."

    # 2. Verify the cluster-side SSH key exists
    echo "Verifying cluster-side SSH key..."
    if ! ssh -i "${LOCAL_SSH_KEY_EXPANDED}" "${HPC_USER}@${HPC_LOGIN_NODE}" "test -f ${CLUSTER_SSH_KEY}"; then
        echo "❌ The cluster-side SSH key was not found at '${CLUSTER_SSH_KEY}'."
        echo "Please ensure the path is correct in ${CONFIG_FILE}, or generate a new key on the cluster."
        exit 1
    fi
    echo "✅ Cluster-side key verified."

    # 3. Check if cluster-side public key is in authorized_keys
    echo "Verifying cluster-side key is authorized for SSH..."
    # This command gets the public key from the private key file and checks if it's in authorized_keys
    if ! ssh -i "${LOCAL_SSH_KEY_EXPANDED}" "${HPC_USER}@${HPC_LOGIN_NODE}" \
        "PUB_KEY=\$(ssh-keygen -y -f ${CLUSTER_SSH_KEY}) && grep -q -F -- \"\$PUB_KEY\" ~/.ssh/authorized_keys"; then
        
        echo "⚠️ The public key for '${CLUSTER_SSH_KEY}' is not in your ~/.ssh/authorized_keys file on the cluster."
        echo "This is required for the compute node to SSH back to the login node."
        read -p "Type 'y' to automatically add it: " -r
        echo # move to a new line

        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            echo "Adding public key to authorized_keys on the cluster..."
            # This command ensures the .ssh dir exists, then appends the public key to authorized_keys
            if ssh -i "${LOCAL_SSH_KEY_EXPANDED}" "${HPC_USER}@${HPC_LOGIN_NODE}" \
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -y -f ${CLUSTER_SSH_KEY} >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
                echo "✅ Public key added successfully."
            else
                echo "❌ Failed to add the public key automatically."
                echo "Please add the public key from '${CLUSTER_SSH_KEY}.pub' to your '~/.ssh/authorized_keys' file on the cluster manually."
                exit 1
            fi
        else
            echo "Aborting. Please add the public key from '${CLUSTER_SSH_KEY}.pub' to your '~/.ssh/authorized_keys' file on the cluster and run the script again."
            exit 1
        fi
    else
        echo "✅ Cluster-side key is authorized."
    fi

    # 4. Create remote log directory
    # The variable LOG_OUTPUT_PATH contains placeholders like %x, so we get the directory part.
    local log_dir
    log_dir=$(dirname "${LOG_OUTPUT_PATH}")
    echo "Ensuring remote log directory exists at '${log_dir}'..."
    ssh -i "${LOCAL_SSH_KEY_EXPANDED}" "${HPC_USER}@${HPC_LOGIN_NODE}" "mkdir -p ${log_dir}"
    echo "✅ Remote log directory is ready."
}

# Validates and manages the necessary SSH configuration block in ~/.ssh/config.
function manage_ssh_config() {
    echo "--- Checking Local SSH Configuration ---"
    local ssh_config_dir="${HOME}/.ssh"
    local ssh_config_file="${ssh_config_dir}/config"
    local local_ssh_key_expanded="${LOCAL_SSH_KEY/#\~/$HOME}"

    # Define the required format string using a standard here-document.
    local format_string
    format_string=$(cat <<'EOF'
### Periscope VSCode Tunnel Start ###
Host %s
    ProxyCommand ssh %s@%s "nc \\$(squeue --me --name=%s --states=R -h -O NodeList) %s"
    User %s
    IdentityFile %s
    IdentitiesOnly yes
    StrictHostKeyChecking no
    ForwardX11 yes
    UseKeychain yes
### Periscope VSCode Tunnel End ###
EOF
)

    # Populate the format string using standard printf.
    local desired_block
    desired_block=$(printf "$format_string" \
        "${TUNNEL_HOST_NAME}" \
        "${HPC_USER}" \
        "${HPC_LOGIN_NODE}" \
        "${SLURM_JOB_NAME}" \
        "${TUNNEL_PORT}" \
        "${HPC_USER}" \
        "${local_ssh_key_expanded}"
)

    # Ensure the config directory and file exist.
    mkdir -p "${ssh_config_dir}"
    touch "${ssh_config_file}"

    # Check for a conflicting, unmanaged host entry first. This is a hard stop.
    if ! grep -q "### Periscope VSCode Tunnel Start ###" "${ssh_config_file}" && grep -q -E "^\s*Host\s+${TUNNEL_HOST_NAME}\s*$" "${ssh_config_file}"; then
        echo "❌ ERROR: A conflicting, unmanaged SSH config for '${TUNNEL_HOST_NAME}' already exists." >&2
        echo "Please remove or rename that entry in '${ssh_config_file}' and run this script again." >&2
        exit 1
    fi

    local needs_update=0
    local action_message=""

    if grep -q "### Periscope VSCode Tunnel Start ###" "${ssh_config_file}"; then
        # Block exists, check if it's correct
        local existing_block
        existing_block=$(sed -n '/### Periscope VSCode Tunnel Start ###/,/### Periscope VSCode Tunnel End ###/p' "${ssh_config_file}")

        # Normalize whitespace for a reliable comparison
        local existing_block_cleaned
        local desired_block_cleaned
        existing_block_cleaned=$(echo "$existing_block" | tr -s '[:space:]' ' ')
        desired_block_cleaned=$(echo "$desired_block" | tr -s '[:space:]' ' ')

        if [[ "$existing_block_cleaned" != "$desired_block_cleaned" ]]; then
            needs_update=1
            action_message="Your existing Periscope SSH config block is outdated and needs to be replaced."
        else
            echo "✅ SSH config is already up-to-date."
            return 0
        fi
    else
        # Block does not exist
        needs_update=1
        action_message="The Periscope SSH config block is missing and needs to be added."
    fi

    if [[ $needs_update -eq 1 ]]; then
        echo "${action_message}"
        echo "The following block will be configured in '${ssh_config_file}':"
        echo "----------------------------------------------------"
        echo "${desired_block}"
        echo "----------------------------------------------------"
        read -p "Type 'y' to apply this change: " -r
        echo # move to a new line

        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            # If an old block exists, remove it. Use a temp file for safety.
            sed '/### Periscope VSCode Tunnel Start ###/,/### Periscope VSCode Tunnel End ###/d' "${ssh_config_file}" > "${ssh_config_file}.tmp"
            mv "${ssh_config_file}.tmp" "${ssh_config_file}"

            # Append the new block
            echo -e "\n${desired_block}" >> "${ssh_config_file}"
            echo "✅ SSH config has been updated."
        else
            echo "Aborting. Please manually update your SSH config and run the script again."
            exit 1
        fi
    fi
}

# Checks for required local command-line tools
function check_prerequisites() {
    echo "--- Verifying Prerequisites ---"
    if ! command -v code &> /dev/null; then
        echo "❌ 'code' command not found."
        echo "Please install VS Code and add 'code' to your shell's PATH."
        echo "In VS Code, open the Command Palette (Cmd+Shift+P) and run 'Shell Command: Install 'code' command in PATH'."
        exit 1
    fi
    if [[ ! -f "${SCHEDULER_SCRIPT_PATH}" ]]; then
        echo "❌ Remote script not found at ${SCHEDULER_SCRIPT_PATH}."
        echo "Please ensure the accompanying scheduler script (e.g., slurm_script.sh) is in the correct path."
        exit 1
    fi
    echo "✅ Prerequisites met."
}

## -----------------------------------------------------------------------------
## Core Logic
## -----------------------------------------------------------------------------

# Submits the SLURM job and launches VS Code
function run_tunnel_and_launch() {
    echo "--- Launching Tunnel on HPC ---"
    local local_ssh_key_expanded="${LOCAL_SSH_KEY/#\~/$HOME}"

    # Launch the SLURM job on the HPC login node
    ssh -i "${local_ssh_key_expanded}" "${HPC_USER}@${HPC_LOGIN_NODE}" \
        "SLURM_JOB_NAME='${SLURM_JOB_NAME}' \
         HPC_USER='${HPC_USER}' \
         PARTITION='${PARTITION}' \
         LOG_OUTPUT_PATH='${LOG_OUTPUT_PATH}' \
         TUNNEL_PORT='${TUNNEL_PORT}' \
         CLUSTER_SSH_KEY='${CLUSTER_SSH_KEY}' \
         bash -s" < "${SCHEDULER_SCRIPT_PATH}"

    if [ $? -ne 0 ]; then
        echo "❌ Failed to set up tunnel job on the HPC. Check the output above for errors."
        echo "You can review your variables in ${CONFIG_FILE}."
        exit 1
    fi

    echo "--- Launching VS Code ---"
    echo "🚀 Connecting to remote workspace..."

    # Use the 'vscode-remote://' URI to connect
    code --folder-uri "vscode-remote://ssh-remote+${TUNNEL_HOST_NAME}${REMOTE_WORKSPACE_PATH}"

    echo "🎉 VS Code connection initiated. This terminal window can now be closed."
}

## -----------------------------------------------------------------------------
## Main Execution
## -----------------------------------------------------------------------------

function main() {
    # Step 1: Handle configuration
    # This will create a template and exit if no config exists.
    # If a config does exist, it will be loaded and validated.
    check_or_run_config

    # Step 2: Run checks that depend on a valid config
    run_post_config_checks

    # Step 3: Set up local SSH config
    manage_ssh_config

    # Step 4: Check for local dependencies
    check_prerequisites

    # Step 5: Run the main process
    run_tunnel_and_launch
}

# Run the main function
main "$@"
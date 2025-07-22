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

# Prompts the user for all necessary configuration details and saves them.
function run_config_prompts() {
    echo "--- Starting Interactive Configuration ---"
    mkdir -p "$(dirname "${CONFIG_FILE}")"
    # Overwrite the old config file
    >"${CONFIG_FILE}"

    # Get HPC username
    while true; do
        read -p "Enter your HPC username (e.g., bsmith1): " HPC_USER
        read -p "Is '${HPC_USER}' correct? [y/n] " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then break; fi
    done
    echo "HPC_USER=${HPC_USER}" >> "${CONFIG_FILE}"

    # Get HPC login node
    while true; do
        read -p "Enter the HPC login node address (e.g., jhpce01.jhsph.edu): " HPC_LOGIN_NODE
        read -p "Is '${HPC_LOGIN_NODE}' correct? [y/n] " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then break; fi
    done
    echo "HPC_LOGIN_NODE=${HPC_LOGIN_NODE}" >> "${CONFIG_FILE}"

    # Get remote workspace path
    while true; do
        read -p "Enter your remote workspace path (e.g., /dcs07/scharpf/data/cnorton): " REMOTE_WORKSPACE_PATH
        read -p "Is '${REMOTE_WORKSPACE_PATH}' correct? [y/n] " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then break; fi
    done
    echo "REMOTE_WORKSPACE_PATH=${REMOTE_WORKSPACE_PATH}" >> "${CONFIG_FILE}"

    # Get local SSH key
    while true; do
        read -p "Enter the full path to your local SSH key for cluster access (e.g., ~/.ssh/id_rsa): " LOCAL_SSH_KEY
        read -p "Is '${LOCAL_SSH_KEY}' correct? [y/n] " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then break; fi
    done
    echo "LOCAL_SSH_KEY=${LOCAL_SSH_KEY}" >> "${CONFIG_FILE}"

    # Test SSH connection before proceeding
    echo "Checking connection to HPC login node..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -i "${LOCAL_SSH_KEY}" "${HPC_USER}@${HPC_LOGIN_NODE}" exit; then
        echo "❌ Connection failed with ${HPC_USER}@${HPC_LOGIN_NODE}. Please check your username, login node, and SSH key path."
        exit 1
    fi

    # Now that SSH connection works, make the log output path
    LOG_OUTPUT_PATH="${REMOTE_WORKSPACE_PATH}/.vscode-logs/"
    ssh -i "${LOCAL_SSH_KEY}" "${HPC_USER}@${HPC_LOGIN_NODE}" "mkdir -p ${LOG_OUTPUT_PATH}"
    echo "✅ Connection successful."

    # Set up cluster-side SSH key
    while true; do
        read -p $'\nHow do you want to set up the cluster-side SSH key?\n1) Create a new key on the cluster (~/.ssh/sshd_key)\n2) Use an existing key on the cluster\nEnter your choice [1/2]: ' choice
        case $choice in
            1)
                ssh -i "${LOCAL_SSH_KEY}" "${HPC_USER}@${HPC_LOGIN_NODE}" "mkdir -p ~/.ssh && ssh-keygen -t rsa -b 4096 -f ~/.ssh/sshd_key -N ''"
                echo "CLUSTER_SSH_KEY=/users/${HPC_USER}/.ssh/sshd_key" >> "${CONFIG_FILE}"
                break ;;
            2)
                read -p "Enter the path to your existing private key on the cluster: " CLUSTER_SSH_KEY
                if ssh -i "${LOCAL_SSH_KEY}" "${HPC_USER}@${HPC_LOGIN_NODE}" "test -f ${CLUSTER_SSH_KEY}"; then
                    echo "✅ Key verified."
                    echo "CLUSTER_SSH_KEY=${CLUSTER_SSH_KEY}" >> "${CONFIG_FILE}"
                    break
                else
                    echo "❌ Key not found on cluster. Please try again."
                fi ;;
            *) echo "Invalid choice." ;;
        esac
    done

    # Get tunnel port
    TUNNEL_PORT=$((RANDOM % 6000 + 2000))
    read -p "Use generated tunnel port ${TUNNEL_PORT}? [y/n] " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        read -p "Enter a port number (2000-8000): " TUNNEL_PORT
    fi
    echo "TUNNEL_PORT=${TUNNEL_PORT}" >> "${CONFIG_FILE}"

    # Add static variables to config
    echo "TUNNEL_HOST_NAME=jhpce-vscode-tunnel" >> "${CONFIG_FILE}"
    echo "SLURM_JOB_NAME=vscode-tunnel-job" >> "${CONFIG_FILE}"
    echo "LOG_OUTPUT_PATH=${REMOTE_WORKSPACE_PATH}/.periscope/logs/%x-%j.log" >> "${CONFIG_FILE}"
    echo "SCHEDULER_SCRIPT_PATH=${CONFIG_DIR}/scheduler_scripts/slurm_script.sh" >> "${CONFIG_FILE}"
    echo "✅ Configuration saved to ${CONFIG_FILE}"
}

# Checks if a config file exists and is valid. If not, prompts to create it.
function check_or_run_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        echo "Found configuration at ${CONFIG_FILE}."
        # Check for missing variables
        MISSING_VARS=()
        for var in "${REQUIRED_VARS[@]}"; do
            if ! grep -q "^${var}=" "${CONFIG_FILE}"; then
                MISSING_VARS+=("$var")
            fi
        done

        if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
            echo "⚠️  Config is incomplete. Missing: ${MISSING_VARS[*]}"
            read -p "Regenerate it now? [y/n] " -n 1 -r; echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                run_config_prompts
            else
                echo "Aborting. Please fix or delete ${CONFIG_FILE}."
                exit 1
            fi
        fi
    else
        echo "Welcome to Periscope!"
        read -p "No periscope config file found. Create one now? [y/n] " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            run_config_prompts
        else
            echo "Setup aborted."
            exit 0
        fi
    fi

    # Load the configuration into the script's environment
    echo "Loading settings..."
    set -a # Automatically export all variables
    source "${CONFIG_FILE}"
    set +a
    echo "✅ Settings loaded."
}

## -----------------------------------------------------------------------------
## Pre-flight Checks
## -----------------------------------------------------------------------------

# Validates the necessary SSH configuration block in ~/.ssh/config.
function manage_ssh_config() {
    echo "--- Checking Local SSH Configuration ---"
    local ssh_config_dir="${HOME}/.ssh"
    local ssh_config_file="${ssh_config_dir}/config"

    # Define the required format string using a standard here-document.
    # This is more portable than using 'read'.
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

    # Populate the format string using standard printf and command substitution.
    # This is more portable than 'printf -v'.
    local desired_block
    desired_block=$(printf "$format_string" \
        "${TUNNEL_HOST_NAME}" \
        "${HPC_USER}" \
        "${HPC_LOGIN_NODE}" \
        "${SLURM_JOB_NAME}" \
        "${TUNNEL_PORT}" \
        "${HPC_USER}" \
        "${LOCAL_SSH_KEY}"
)
    
    # Ensure the config directory exists.
    mkdir -p "${ssh_config_dir}"

    # If the config file doesn't exist, instruct user to create it and add the block.
    if [[ ! -f "${ssh_config_file}" ]]; then
        echo "❌ SSH config file not found at '${ssh_config_file}'." >&2
        echo "Please create the file and add the following block, then run this script again:" >&2
        echo "----------------------------------------------------"
        echo "${desired_block}"
        echo "----------------------------------------------------"
        exit 1
    fi

    # 1. Check if our managed block is present.
    if grep -q "### Periscope VSCode Tunnel Start ###" "${ssh_config_file}"; then
        local existing_block
        existing_block=$(sed -n '/### Periscope VSCode Tunnel Start ###/,/### Periscope VSCode Tunnel End ###/p' "${ssh_config_file}")

        # Normalize whitespace on both for a reliable comparison
        local existing_block_cleaned
        local desired_block_cleaned
        existing_block_cleaned=$(echo "$existing_block" | tr -s '[:space:]' ' ')
        desired_block_cleaned=$(echo "$desired_block" | tr -s '[:space:]' ' ')

        # Compare the blocks
        if [[ "$existing_block_cleaned" == "$desired_block_cleaned" ]]; then
            echo "✅ SSH config is already up-to-date."
            return 0
        else
            echo "❌ Your existing Periscope SSH config block is outdated." >&2
            echo "Please replace the existing block in '${ssh_config_file}' with this one:" >&2
            echo "----------------------------------------------------"
            echo "${desired_block}"
            echo "----------------------------------------------------"
            exit 1
        fi
        
    # 2. Check for a conflicting, unmanaged block for the same host.
    elif grep -q -E "^\s*Host\s+${TUNNEL_HOST_NAME}\s*$" "${ssh_config_file}"; then
        echo "❌ ERROR: A conflicting, unmanaged SSH config for '${TUNNEL_HOST_NAME}' already exists." >&2
        echo "Please remove or rename that entry in '${ssh_config_file}' and then add the required block:" >&2
        echo "----------------------------------------------------"
        echo "${desired_block}"
        echo "----------------------------------------------------"
        exit 1

    # 3. If no Periscope block is found at all, instruct the user to add it.
    else
        echo "Periscope SSH config block not found in '${ssh_config_file}'." >&2
        echo "Please add the following block to your SSH config and run this script again:" >&2
        echo "----------------------------------------------------"
        echo "${desired_block}"
        echo "----------------------------------------------------"
        exit 1
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
    # Ensure the remote script exists
    if [[ ! -f "${SCHEDULER_SCRIPT_PATH}" ]]; then
        echo "❌ Remote script not found at ${SCHEDULER_SCRIPT_PATH}."
        echo "Please ensure the accompanying 'slurm_script.sh' is in the same directory as this script."
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
    
    # Launch the SLURM job on the HPC login node
    # This pipes the remote script to the remote shell for execution
    # The original approach was to pipe a separate file:
    ssh -i "${LOCAL_SSH_KEY}" "${HPC_USER}@${HPC_LOGIN_NODE}" \
        "SLURM_JOB_NAME='${SLURM_JOB_NAME}' \
         HPC_USER='${HPC_USER}' \
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
    check_or_run_config

    # Step 2: Set up local SSH config
    manage_ssh_config

    # Step 3: Check for local dependencies
    check_prerequisites

    # Step 4: Run the main process
    run_tunnel_and_launch
}

# Run the main function
main "$@"
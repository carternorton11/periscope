```
                            88888
                            88 ( )
                            88888
                            888
~~~~~~~~~~~~~~~~~~~~~~~~~~~~888~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
~8888888b.                  d8b                                            ~
~888   Y88b                 Y8P                                            ~
~888    888                                                                ~
~888   d88P .d88b.  888d888 888 .d8888b   .d8888b .d88b.  88888b.   .d88b. ~
~8888888P" d8P  Y8b 888P"   888 88K      d88P"   d88""88b 888 "88b d8P  Y8b~
~888       88888888 888     888 "Y8888b. 888     888  888 888  888 88888888~
~888       Y8b.     888     888      X88 Y88b.   Y88..88P 888 d88P Y8b.    ~
~888        "Y8888  888     888  88888P'  "Y8888P "Y88P"  88888P"   "Y8888 ~
~                                                         888              ~
~                                                         888              ~
~                                                         888              ~
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

Periscope is a simple tool for opening a vscode session on a compute node of a SLURM HPC. 
It requires:
1. SSH keys to be set up between your local computer and HPC
2. vscode to be installed locally, with Remote-SSH extension
3. a mac, for now
4. a HPC that uses SLURM for job scheduling, for now

To run this tool, clone this repo, and then run:
`bash periscope.sh`

Periscope will:
1. generate a config.txt file in its own directory
2. update your .ssh/config to include a specific block for vscode tunnel
3. test your ssh connection
4. open a compute job and run vscode session on that job

Once config is complete, `bash periscope.sh` will directly open a compute job on HPC and open a vscode session there






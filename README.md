```
                            88888
                            88####)
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

Periscope is a simple tool for opening a vscode server on a compute node of a SLURM HPC. 
It requires:
1. SSH keys to be set up between your local computer and HPC
2. vscode to be installed locally, with Remote-SSH extension

To run this tool, clone this repo, and then run:
`bash periscope.sh`

1. periscope will generate a config.txt file in its own directory
2. periscope will test your ssh connection
3. once the config.txt file is generated and ssh connection works,  `bash periscope.sh` will automatically open a compute job, and run a vscode server on that job






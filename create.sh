#!/bin/bash

if test -t 1 -a -t 2; then
	OC_YELLOW="\e[1;33m"
	OC_PURPLE="\e[1;35m"
	OC_COMMON="\e[0m"
fi

function usage()
{
	echo -ne "$0 [<options>] <username> <nodes>

Important: options must be ahead of positional arguments

Positional arguments:
	username:		The username
	nodes:			Target nodes. E.g. 6,8,12-15 means nodes 6, 8, 12, 13, 14, 15

Options:
	-h  | --help           Show this help and exit.
	-r  | --root           Grant the account with sudo priviledge.
	-f  | --key-file       Use another SSH public key file instead of creating a new one.
	-a  | --auth-key-file  Add auth keys to authorized_keys.
	-bc | --bash-config    Copy current ~/.bashrc file to that account.
"
}


g_withroot=false
g_bashconfig=false
g_sshkeyfile=""
g_authkeyfile=""
declare -a targetnodes
nodes_list_str=""
g_username=""
g_rootfile=""
g_sshdir=""
function parse_args()
{
	# Handle optional arguments
	while test $# -gt 0; do
		local opt="$1"
		case "${opt}" in
			-h|--help)	usage; exit 0 ;;
			-r|--root)	g_withroot=true ;;
			-f|--key-file) g_sshkeyfile=$2; shift ;;
			-a|--auth-key-file) g_authkeyfile=$2; shift ;;
			-bc|--bash-config)	g_bashconfig=true;;
			-*) echo -e "${OC_PURPLE}Unknown option: ${opt}" ;;
			*)	break
		esac
		shift
	done
	
	# Handle positional arguments
	# Username
	g_username="$1"
	if [ ! "$g_username" ]; then 
		usage; exit 1
	fi
	shift

	# All nodes
	all_nodes="$1"
	if [ ! "$all_nodes" ]; then
		usage; exit 1
	fi
	oldifs="$IFS"
	IFS=","
	read -a noderanges <<< "$all_nodes"
	IFS=$oldifs
	for noderange in ${noderanges[@]}; do
		IFS="-"
		read -a anchors <<< "$noderange"
		len=${#anchors[@]} 
		if test $len -gt 2; then
			echo "Fatal: Unrecognized range: $noderange"
			exit 1
		elif test $len -eq 1; then
			targetnodes+=(${anchors[0]})
		else
			for i in $(seq ${anchors[0]} ${anchors[1]}); do
				targetnodes+=($i)
			done
		fi
		IFS=$oldifs
	done
	IFS=$oldifs
	shift
	nodes_list_str=""
	for node in ${targetnodes[@]}; do
		nodes_list_str="$nodes_list_str $node"
	done

	if test $# -gt 0; then
		echo -e "${OC_PURPLE}Warning: Ignored parameters: $*"
	fi

	# Show configurations
	echo -e "$OC_YELLOW
==================================
Target Nodes:      $OC_COMMON${nodes_list_str}$OC_YELLOW
Username:           $OC_COMMON${g_username}$OC_YELLOW
Sudo priviledge:    $OC_COMMON${g_withroot}$OC_YELLOW
SSH key file:	    $OC_COMMON${g_sshkeyfile}$OC_YELLOW
Auth key file:	    $OC_COMMON${g_authkeyfile}$OC_YELLOW
Copy Bash config:   $OC_COMMON${g_bashconfig}$OC_YELLOW
==================================

Press [Enter] to continue, or [Ctrl-C] to exit.
The process automatically starts in 60 seconds.$OC_COMMON
"
	read -t 60
	#echo "Start"
}

function prepare()
{
	# Specified SSH public key?
	if test ! -z "${g_sshkeyfile}"; then
		# Given but unreadable?
		if test ! -f ${g_sshkeyfile} -o ! -r ${g_sshkeyfile}; then
			>&2 echo "Fatal: SSH key file ${g_sshkeyfile} not available or readable"
			exit 2
		fi
	fi

	# Specified SSH authorized key file?
	if test ! -z "${g_authkeyfile}"; then
		# Given but unreadable?
		if test ! -f ${g_authkeyfile} -o ! -r ${g_authkeyfile}; then
			>&2 echo "Fatal: SSH AUTH key file ${g_authkeyfile} not available or readable"
			exit 2
		fi
	fi

	# Create SSH key
	g_sshdir=$(mktemp -d .ssh.XXXX)
	if test -z "${g_sshkeyfile}"; then
		echo -e "${OC_YELLOW}Generating local SSH key ...$OC_COMMON"
		ssh-keygen -q -t rsa -N "" -C "internal-shared-key" -f ${g_sshdir}/id_rsa
	else
		echo -e "${OC_YELLOW}Using given SSH key file ${g_sshkeyfile} ...$OC_COMMON"
		cp ${g_sshkeyfile} ${g_sshdir}/id_rsa
		chmod 0600 ${g_sshdir}/id_rsa
		if test -f ${g_sshkeyfile}.pub; then
			cp ${g_sshkeyfile}.pub ${g_sshdir}/id_rsa.pub
		else
			>&2 echo "Warning: public key file (${g_sshkeyfile}.pub) not found, skipped."
		fi
	fi

	# Generate authorization file
	touch ${g_sshdir}/authorized_keys
	chmod 0600 ${g_sshdir}/authorized_keys
	if test -f ${g_sshdir}/id_rsa.pub; then
		echo "# Internal shared key" >> ${g_sshdir}/authorized_keys
		cat ${g_sshdir}/id_rsa.pub >> ${g_sshdir}/authorized_keys
	fi
	echo -e "\n# Additional keys" >> ${g_sshdir}/authorized_keys
	if test ! -z "${g_authkeyfile}"; then
		cat ${g_authkeyfile} >> ${g_sshdir}/authorized_keys
	else
		if test ! -t 0; then
			echo -e "${OC_PURPLE}Stdin is not a terminal. You need to add your public key manually${OC_COMMON}"
		else
			echo -e "${OC_PURPLE}Enter your public key to be added to authorized_keys: (Ctrl-D to finish)${OC_COMMON}"
			cat >> ${g_sshdir}/authorized_keys
		fi
	fi

	# Root access?
	if [ ${g_withroot} == true ]; then
		g_rootfile=$(mktemp ${g_username}-sudoer-XXXX)
		echo -e "${g_username}\tALL = (root) NOPASSWD:ALL" > $g_rootfile
	fi
}

function single_node_create_account()
{
	nodeid="$1"

	# Create account
	echo -e "${OC_YELLOW}Creating user $g_username...$OC_COMMON"
	ssh n$nodeid sudo adduser $g_username

	# Copy keys
	echo -e "${OC_YELLOW}Copying SSH key files...$OC_COMMON"
	local remotesshdir=$(ssh n$nodeid mktemp -d .ssh.XXXX)
	scp -r ${g_sshdir} n$nodeid:${remotesshdir} &>/dev/null
	ssh n$nodeid sudo mv ${remotesshdir}/${g_sshdir} /home/$g_username/.ssh
	ssh n$nodeid sudo chown -R $g_username:$g_username /home/$g_username/.ssh
	ssh n$nodeid sudo chmod 0700 /home/$g_username/.ssh
	ssh n$nodeid rmdir ${remotesshdir}
	
	# Root access?
	if [ ${g_withroot} == true ]; then
		local remoterootfile=$(ssh n$nodeid mktemp ${g_username}-sudoer-XXXX)
		scp $g_rootfile n$nodeid:${remoterootfile} &>/dev/null
		ssh n$nodeid sudo chown root:root $remoterootfile
		ssh n$nodeid sudo chmod 0440 $remoterootfile
		ssh n$nodeid sudo mv $remoterootfile /etc/sudoers.d/${g_username}
	fi

	# Copy bash config file?
	if [ ${g_bashconfig} == true ]; then
		local remoteconfigfile=$(ssh n$nodeid mktemp .bc.XXXX)
		scp ~/.bashrc n$nodeid:${remoteconfigfile} &>/dev/null
		ssh n$nodeid sudo chown ${g_username}:${g_username} $remoteconfigfile
		ssh n$nodeid sudo chmod 0644 $remoteconfigfile
		ssh n$nodeid sudo mv $remoteconfigfile /home/${g_username}/.bashrc
	fi
}

function cleanup()
{
	rm -rf ${g_sshdir}
	rm -f ${g_rootfile}
}

# Parse arguments
parse_args $@

prepare

for nodeid in $nodes_list_str; do
	single_node_create_account $nodeid 2>&1 | sed "s/^/[node $nodeid] /" &
done
wait

cleanup

#!/bin/bash

# This macro defines the prefix of node names to resolve.
# E.g. in our cluster for example, we name 19 nodes with name "node1", "node2", etc.
# Therefore, we use the prefix "node" as well as the node number to connect to these nodes.
NODENAME_PREFIX=node

SUDO=
test $(id -u) -ne 0 && SUDO=sudo

if test -t 1 -a -t 2; then
	OC_YELLOW="\e[1;33m"
	OC_PURPLE="\e[1;35m"
	OC_NULL="\e[0m"
fi

function prompt()
{
	echo -e "${OC_YELLOW}$@${OC_NULL}"
}

function warn()
{
	echo -e "${OC_PURPLE}$@${OC_NULL}"
}

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
			-*) warn "Unknown option: ${opt}" ;;
			*)	break
		esac
		shift
	done
	
	# Handle positional arguments
	# Username
	g_username="$1"
	if [ ! "${g_username}" ]; then 
		usage; exit 1
	fi
	shift

	# All nodes
	all_nodes="$1"
	if [ ! "${all_nodes}" ]; then
		usage; exit 1
	fi
	oldifs="${IFS}"
	IFS=","
	read -a noderanges <<< "${all_nodes}"
	IFS=${oldifs}
	for noderange in ${noderanges[@]}; do
		IFS="-"
		read -a anchors <<< "${noderange}"
		len=${#anchors[@]} 
		if test ${len} -gt 2; then
			echo "Fatal: Unrecognized range: ${noderange}"
			exit 1
		elif test ${len} -eq 1; then
			targetnodes+=(${anchors[0]})
		else
			for i in $(seq ${anchors[0]} ${anchors[1]}); do
				targetnodes+=(${i})
			done
		fi
		IFS=${oldifs}
	done
	IFS=${oldifs}
	shift
	nodes_list_str=""
	for node in ${targetnodes[@]}; do
		nodes_list_str="${nodes_list_str} ${node}"
	done

	if test $# -gt 0; then
		warn "Warning: Ignored parameters: $*"
	fi

	# Show configurations
	echo -e "${OC_YELLOW}
==================================
Target Nodes:      ${OC_NULL}${nodes_list_str}${OC_YELLOW}
Username:           ${OC_NULL}${g_username}${OC_YELLOW}
Sudo priviledge:    ${OC_NULL}${g_withroot}${OC_YELLOW}
SSH key file:	    ${OC_NULL}${g_sshkeyfile}${OC_YELLOW}
Auth key file:	    ${OC_NULL}${g_authkeyfile}${OC_YELLOW}
Copy Bash config:   ${OC_NULL}${g_bashconfig}${OC_YELLOW}
==================================

Press [Enter] to continue, or [Ctrl-C] to exit.
The process automatically starts in 60 seconds.${OC_NULL}
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
		prompt "Generating local SSH key ..."
		ssh-keygen -q -t rsa -N "" -C "internal-shared-key" -f ${g_sshdir}/id_rsa
	else
		prompt "Using given SSH key file ${g_sshkeyfile} ..."
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
			warn "Stdin is not a terminal. You need to add your public key manually"
		else
			warn "Enter your public key to be added to authorized_keys: (Ctrl-D to finish)"
			cat >> ${g_sshdir}/authorized_keys
		fi
	fi

	# Root access?
	if [ ${g_withroot} == true ]; then
		g_rootfile=$(mktemp ${g_username}-sudoer-XXXX)
		echo -e "${g_username}\tALL = (root) NOPASSWD:ALL" > ${g_rootfile}
	fi
}

function single_node_create_account()
{
	nodeid="$1"

	# Create account
	prompt "Creating user ${g_username}..."
	ssh ${NODENAME_PREFIX}${nodeid} ${SUDO} adduser ${g_username}

	# Copy keys
	prompt "Copying SSH key files..."
	local remotesshdir=$(ssh ${NODENAME_PREFIX}${nodeid} mktemp -d .ssh.XXXX)
	scp -r ${g_sshdir} ${NODENAME_PREFIX}${nodeid}:${remotesshdir} &>/dev/null
	ssh ${NODENAME_PREFIX}${nodeid} ${SUDO} mv ${remotesshdir}/${g_sshdir} /home/${g_username}/.ssh
	ssh ${NODENAME_PREFIX}${nodeid} ${SUDO} chown -R ${g_username}:${g_username} /home/${g_username}/.ssh
	ssh ${NODENAME_PREFIX}${nodeid} ${SUDO} chmod 0700 /home/${g_username}/.ssh
	ssh ${NODENAME_PREFIX}${nodeid} rmdir ${remotesshdir}
	
	# Root access?
	if [ ${g_withroot} == true ]; then
		prompt "Granting ROOT access via SUDOER file /etc/sudoers.d/${g_username}..."
		local remoterootfile=$(ssh ${NODENAME_PREFIX}${nodeid} mktemp ${g_username}-sudoer-XXXX)
		scp ${g_rootfile} ${NODENAME_PREFIX}${nodeid}:${remoterootfile} &>/dev/null
		ssh ${NODENAME_PREFIX}${nodeid} ${SUDO} chown root:root ${remoterootfile}
		ssh ${NODENAME_PREFIX}${nodeid} ${SUDO} chmod 0440 ${remoterootfile}
		ssh ${NODENAME_PREFIX}${nodeid} ${SUDO} mv ${remoterootfile} /etc/sudoers.d/${g_username}
	fi

	# Copy bash config file?
	if [ ${g_bashconfig} == true ]; then
		prompt "Syncing local bash config file..."
		local remoteconfigfile=$(ssh ${NODENAME_PREFIX}${nodeid} mktemp .bc.XXXX)
		scp ~/.bashrc ${NODENAME_PREFIX}${nodeid}:${remoteconfigfile} &>/dev/null
		ssh ${NODENAME_PREFIX}${nodeid} ${SUDO} chown ${g_username}:${g_username} ${remoteconfigfile}
		ssh ${NODENAME_PREFIX}${nodeid} ${SUDO} chmod 0644 ${remoteconfigfile}
		ssh ${NODENAME_PREFIX}${nodeid} ${SUDO} mv ${remoteconfigfile} /home/${g_username}/.bashrc
	fi
}

function cleanup()
{
	prompt "Cleaning up local temporary files..."
	rm -rf ${g_sshdir}
	rm -f ${g_rootfile}
}

# Parse arguments
parse_args $@

prepare

for nodeid in ${targetnodes[@]}; do
	single_node_create_account ${nodeid} 2>&1 | sed "s/^/[${NODENAME_PREFIX} ${nodeid}] /" &
done
wait

cleanup

prompt "Done."

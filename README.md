# Batch creating user script

This script is used to create user on multiple nodes in a cluster. Run this command with no parameter or parameter `-h` to show help.

Commands including those requiring ROOT permissions are passed to other nodes via SSH connections. Make sure that SSH key of the node running this script is authorized by all other nodes, AND, the UID of the process should has full ROOT access either by `sudo` (with NOPASSWD priviledge configured), or is root itself.

We assume that all target nodes names to resolve have exactly the same name prefix "node" (e.g. "node1", "node2", etc.). If not, the first parameter `NODENAME_PREFIX` should be modified.

Enjoy!

#!/bin/bash

NUM_NS=${NUM_NS:-2}
VETH_MTU="${VETH_MTU:1480}"
NODES_MTU="${NODES_MTU:-1500}"

function cleanup {
	set +e
	sudo ip netns del sender0
	sudo ip netns del receiver0
	sudo ip link del br0
	sudo ip link del eth0
	sudo ip link del eth1
	for i in `seq "$NUM_NS"`; do
		sudo ip netns del ns${i}
	done
}

trap cleanup EXIT
set -x
set -e

# Create namespaces representing the node from which traffic will be mirrored and the node that will receiver the
# mirrored traffic
sudo ip netns add sender0
sudo ip netns add receiver0

# Setup pod network namespaces
for i in `seq "$NUM_NS"`; do
  # Create network namespace
	sudo ip netns add ns${i}
	# Create veth pair
	sudo ip -n sender0 link add veth${i} mtu ${VETH_MTU} type veth peer name veth${i}_ netns ns${i} mtu ${VETH_MTU}
	# Set veth pair end up
	sudo ip -n ns${i} link set dev veth${i}_ up
	sudo ip -n sender0 link set dev veth${i} up
	# Add address to the internal veth pair end
	sudo ip -n ns${i} addr add 10.0.0.${i} dev veth${i}_
	# Setup internal routes and arp proxy
	sudo ip -n ns${i} route add 169.254.1.1 dev veth${i}_
	sudo ip -n ns${i} route add default via 169.254.1.1
	sudo ip netns exec sender0 sh -c "echo 1 > /proc/sys/net/ipv4/conf/veth${i}/proxy_arp"
	# Setup external route
	sudo ip -n sender0 route add 10.0.0.${i} dev veth${i}
done

# Create infrastructure for connecting the sender with the receiver node (a bridge with two veth pairs representing the
# nodes devices)
sudo ip link add br0 type bridge
sudo ip link add eth0_ mtu ${NODES_MTU} master br0 type veth peer name eth0 netns sender0 mtu ${NODES_MTU}
sudo ip link add eth1_ mtu ${NODES_MTU} master br0 type veth peer name eth1 netns receiver0 mtu ${NODES_MTU}
# Set bridge and devices up
sudo ip link set dev br0 up
sudo ip link set dev eth0_ up
sudo ip link set dev eth1_ up
sudo ip -n sender0 link set dev eth0 up
sudo ip -n receiver0 link set dev eth1 up
# Configure addressses on nodes devices
sudo ip addr add 192.168.1.254/24 dev br0
sudo ip -n sender0 addr add 192.168.1.1/24 dev eth0
sudo ip -n receiver0 addr add 192.168.1.2/24 dev eth1
# Configure default routes on nodes (actually only the one configured on the sender node is required: without it, arp
# proxy doesn't work)
sudo ip -n sender0 route add default via 192.168.1.254
sudo ip -n receiver0 route add default via 192.168.1.254
# Configure gre tunnel
sudo ip -n sender0 link add tun0 type gretap local 192.168.1.1 remote 192.168.1.2 dev eth0
sudo ip -n receiver0 link add tun0 type gretap local 192.168.1.2 remote 192.168.1.1 dev eth1
# Set gre tunnel devices up
sudo ip -n sender0 link set dev tun0 up
sudo ip -n receiver0 link set dev tun0 up
# Configure addresses on gre tunnel devices for debugging purposes
sudo ip -n sender0 addr add 172.16.0.1/30 dev tun0
sudo ip -n receiver0 addr add 172.16.0.2/30 dev tun0


read -p "Press enter to remove configuration..."

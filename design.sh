#!/bin/bash

NUM_NS=${NUM_NS:-2}
VETH_MTU=${VETH_MTU:-1480}
NODES_MTU=${NODES_MTU:-1500}
TUN=${TUN:-"tun0"}
SENDER=${SENDER:-"sender0"}
RECEIVER=${RECEIVER:-"receiver0"}
SENDER_IF=${SENDER_IF:-"ens0"}
RECEIVER_IF=${RECEIVER_IF:-"ens1"}
FILTER=${FILTER:-"tcp"}

function cleanup {
  set +e
  for i in $(seq "$NUM_NS"); do
    sudo ip netns del ns"$i"
  done
  sudo ip -n "$RECEIVER" link del "$TUN"
  sudo ip -n "$SENDER" link del "$TUN"
  sudo ip link del "$RECEIVER_IF"_
  sudo ip link del "$SENDER_IF"_
  sudo ip link del br0
  sudo ip netns del "$RECEIVER"
  sudo ip netns del "$SENDER"
}

function compile_filter {
  sudo ip netns exec "$SENDER" tcpdump -i veth1 -ddd "$1" | tr '\n' ','
}

function add_filter {
  IF=$1
  FILTER=$2
  COMPILED_FILTER=$(compile_filter "$FILTER")
  sudo tc -n "$SENDER" qdisc add dev "$IF" handle 1: root prio
  sudo tc -n "$SENDER" filter add dev "$IF" parent 1: \
    bpf bytecode "$FILTER" \
    action mirred egress mirror dev "$TUN"
}

trap cleanup EXIT
set -x
set -e

# Create namespaces representing the node from which traffic will be mirrored and the node that will receiver the
# mirrored traffic
sudo ip netns add "$SENDER"
sudo ip netns add "$RECEIVER"
# Create infrastructure for connecting the sender with the receiver node (a bridge with two veth pairs representing the
# nodes devices)
sudo ip link add br0 type bridge
sudo ip link add "$SENDER_IF"_ mtu "$NODES_MTU" master br0 type veth peer \
  name "$SENDER_IF" netns "$SENDER" mtu "$NODES_MTU"
sudo ip link add "$RECEIVER_IF"_ mtu "$NODES_MTU" master br0 type veth peer \
  name "$RECEIVER_IF" netns "$RECEIVER" mtu "$NODES_MTU"
# Set bridge and devices up
sudo ip link set dev br0 up
sudo ip link set dev "$SENDER_IF"_ up
sudo ip link set dev "$RECEIVER_IF"_ up
sudo ip -n "$SENDER" link set dev "$SENDER_IF" up
sudo ip -n "$RECEIVER" link set dev "$RECEIVER_IF" up
# Configure addressses on nodes devices
sudo ip addr add 192.168.1.254/24 dev br0
sudo ip -n "$SENDER" addr add 192.168.1.1/24 dev "$SENDER_IF"
sudo ip -n "$RECEIVER" addr add 192.168.1.2/24 dev "$RECEIVER_IF"
# Configure default routes on nodes (actually only the one configured on the sender node is required: without it, arp
# proxy doesn't work)
sudo ip -n "$SENDER" route add default via 192.168.1.254
sudo ip -n "$RECEIVER" route add default via 192.168.1.254
# Configure gre tunnel
sudo ip -n "$SENDER" link add "$TUN" type gretap local 192.168.1.1 remote 192.168.1.2 dev "$SENDER_IF"
sudo ip -n "$RECEIVER" link add "$TUN" type gretap local 192.168.1.2 remote 192.168.1.1 dev "$RECEIVER_IF"
# Set gre tunnel devices up
sudo ip -n "$SENDER" link set dev "$TUN" up
sudo ip -n "$RECEIVER" link set dev "$TUN" up
# Configure addresses on gre tunnel devices for debugging purposes
sudo ip -n "$SENDER" addr add 172.16.0.1/30 dev "$TUN"
sudo ip -n "$RECEIVER" addr add 172.16.0.2/30 dev "$TUN"

# Compile traffic mirroring filter
COMPILED_FILTER=$(compile_filter "$FILTER")

# Setup pod network namespaces
for i in $(seq "$NUM_NS"); do
  # Create network namespace
  sudo ip netns add ns"$i"
  # Create veth pair
  sudo ip -n "$SENDER" link add veth"$i" mtu "$VETH_MTU" type veth peer \
    name veth"$i"_ netns ns"$i" mtu "$VETH_MTU"
  # Set veth pair end up
  sudo ip -n ns"$i" link set dev veth"$i"_ up
  sudo ip -n "$SENDER" link set dev veth"$i" up
  # Add address to the internal veth pair end
  sudo ip -n ns"$i" addr add 10.0.0."$i" dev veth"$i"_
  # Setup internal routes and arp proxy
  sudo ip -n ns"$i" route add 169.254.1.1 dev veth"$i"_
  sudo ip -n ns"$i" route add default via 169.254.1.1
  sudo ip netns exec "$SENDER" sh -c "echo 1 > /proc/sys/net/ipv4/conf/veth$i/proxy_arp"
  # Setup external route
  sudo ip -n "$SENDER" route add 10.0.0."$i" dev veth"$i"
  # Add qdiscs/filters for mirroring traffic to the GRE tunnel
  add_filter veth"$i" "$COMPILED_FILTER"
done

# shellcheck disable=SC2162
read -p "Press enter to remove configuration..."
#!/bin/bash

# Usage:
# ./hostbgp-config.sh [ASN] <VPC-SUBNET-NAME-1>:v=<VLAN>:i=<INTERFACE1>[:i=<INTERFACE2>...]:a=<ADDRESS1>[:a=<ADDRESS2>...] [<VPC-SUBNET-NAME-2>:...]

OUTPUT_FILE="/etc/frr/frr.conf"
DEFAULT_ASN=64999

# Validate ASN
function valid_asn() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 4294967295 ]
}

# Validate VLAN (0-4095)
function valid_vlan() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 0 ] && [ "$1" -le 4095 ]
}

# Validate interface
function valid_interface() {
  local iface="$1"
  # Must be non-empty
  [[ -n "$iface" ]] || return 1
  # Allow only alphanumeric characters, underscore, and dash
  [[ "$iface" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
  # Enforce typical Linux interface name length limit (15 characters)
  [[ "${#iface}" -le 15 ]]
}

# Validate IPv4 /32
function valid_ipv4_32() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || return 1
  IP="${1%/32}"
  IFS=. read -r a b c d <<< "$IP"
  for octet in $a $b $c $d; do
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
  return 0
}

# Validate VPC names (alphanumeric, hyphens, underscores)
function valid_vpc_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}

ASN="$DEFAULT_ASN"
if valid_asn "$1"; then
  ASN="$1"
  shift
fi

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 [ASN] <VPC-SUBNET-NAME-1>:v=<VLAN>:i=<INTERFACE1>[:i=<INTERFACE2>...]:a=<ADDRESS1>[:a=<ADDRESS2>...] [<VPC-SUBNET-NAME-2>:...]"
  echo "ASN will default to 64999 if not provided"
  echo "Addresses should be IPv4 /32"
  echo "VLAN 0 means untagged"
  echo "At least one VPC subnet is required, and at least one interface, VLAN and address per VPC; parameters (v=, i=, a=) can appear in any order"
  exit 1
fi

VIP_CONFIG=""
NETWORK_CONFIG=""
NEIGHBOR_CONFIG=""
ROUTE_MAP_CONFIG=""
declare -A VPC_NAMES_SEEN

for ARG in "$@"; do
  # Split on first colon to get VPC-SUBNET-NAME and the rest
  VPC_SUBNET_NAME="${ARG%%:*}"
  REST="${ARG#*:}"

  VLAN=""
  INTERFACES=()
  ADDRESSES=()

  # Parse the rest, split by colon
  IFS=':' read -ra PARTS <<< "$REST"
  for PART in "${PARTS[@]}"; do
    case "$PART" in
      v=*)
        VLAN="${PART#v=}"
        ;;
      i=*)
        INTERFACES+=("${PART#i=}")
        ;;
      a=*)
        ADDRESSES+=("${PART#a=}")
        ;;
      *)
        echo "Unknown parameter: $PART" >&2
        exit 1
        ;;
    esac
  done

  # Validation
  if [[ -z "$VPC_SUBNET_NAME" ]]; then
    echo "Missing VPC subnet name in argument: $ARG" >&2
    exit 1
  fi
  if ! valid_vpc_name "$VPC_SUBNET_NAME"; then
    echo "Invalid VPC subnet name: $VPC_SUBNET_NAME in argument: $ARG" >&2
    exit 1
  fi
  # Check for duplicate VPC_SUBNET_NAME
  if [[ -n "${VPC_NAMES_SEEN[$VPC_SUBNET_NAME]}" ]]; then
    echo "Duplicate VPC subnet name detected: $VPC_SUBNET_NAME" >&2
    exit 1
  fi
  VPC_NAMES_SEEN[$VPC_SUBNET_NAME]=1
  if [[ -z "$VLAN" ]] || ! valid_vlan "$VLAN"; then
    echo "Invalid or missing VLAN in argument: $ARG" >&2
    exit 1
  fi
  if [[ "${#INTERFACES[@]}" -eq 0 ]]; then
    echo "At least one interface is required in argument: $ARG" >&2
    exit 1
  fi
  for IFACE in "${INTERFACES[@]}"; do
    if ! valid_interface "$IFACE"; then
      echo "Invalid interface: $IFACE in argument: $ARG" >&2
      exit 1
    fi
    IFACE_NAME="${IFACE}"
    if [ "${VLAN}" -ne 0 ] ; then
        IFACE_NAME="${IFACE}.${VLAN}"
        if ! ip link show "${IFACE_NAME}" >/dev/null 2>&1 ; then
            ip l a link "${IFACE}" name "${IFACE_NAME}" type vlan id "${VLAN}" || echo "warning: could not create vlan interface ${IFACE_NAME}" >&2
        fi
    fi
    NEIGHBOR_CONFIG+=" neighbor ${IFACE_NAME} interface remote-as external
 neighbor ${IFACE_NAME} capability link-local
 neighbor ${IFACE_NAME} route-map ${VPC_SUBNET_NAME} out
"
  done
  if [[ "${#ADDRESSES[@]}" -eq 0 ]]; then
    echo "At least one address is required in argument: $ARG" >&2
    exit 1
  fi
  ROUTE_MAP_CONFIG+="route-map ${VPC_SUBNET_NAME} permit 10
 match ip address prefix-list ${VPC_SUBNET_NAME}
!
"
  for ADDR in "${ADDRESSES[@]}"; do
    if ! valid_ipv4_32 "$ADDR"; then
      echo "Invalid address: $ADDR in argument: $ARG (hint: must be IPv4 /32)" >&2
      exit 1
    fi
    VIP_CONFIG+=" ip address ${ADDR}
"
    NETWORK_CONFIG+="  network ${ADDR}
"
    ROUTE_MAP_CONFIG+="ip prefix-list ${VPC_SUBNET_NAME} permit ${ADDR}
"
  done
  ROUTE_MAP_CONFIG+="!
"
done


cat <<EOF > "${OUTPUT_FILE}"
${ROUTE_MAP_CONFIG}!
interface lo
${VIP_CONFIG}!
router bgp ${ASN}
 no bgp ebgp-requires-policy
 bgp bestpath as-path multipath-relax
 timers bgp 3 9
${NEIGHBOR_CONFIG} address-family ipv4 unicast
  maximum-paths 4
${NETWORK_CONFIG} !
!
EOF

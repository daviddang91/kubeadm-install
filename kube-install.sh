#!/bin/bash
#description : This script will help to install k8s cluster (master / worker) and gpu operator
#author	     : David Dang
#date        : 27/01/2024
#version     : 1.0
#usage       : Please make sure to run this script as ROOT or with ROOT permissions
#notes       : supports ubuntu OS 18.04/20.04/22.04
#==============================================================================
NC='\033[0m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'

# Default values
crisock="unix:/run/containerd/containerd.sock"
kubeadmyaml="/etc/kubernetes/kubeadm.yaml"
# kubeadm API version - in a single var so easy to update
kubeadmVersion="kubeadm.k8s.io/v1beta3"
# Default kubeadmn
k8sVersion="1.29.1"
# Use netbird
netbird="false"
# Default node ip and node name
nodeIp=$(hostname -I | awk '{ print $1 }')
nodeName=$(hostname)
advertiseAddress=$nodeIp
bindPort=6443
curlinstall="curl https://raw.githubusercontent.com/daviddang91/kubeadm-install/main/kube-install.sh"

# Disable Swap
function disable-swap {
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
}

# load kernel modules for support containerd 
function load-kernel-modules {
    tee /etc/modules-load.d/containerd.conf <<EOF
    overlay
    br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter
}

# Setup K8s Networking
function network {
    tee /etc/sysctl.d/kubernetes.conf <<EOF
    net.bridge.bridge-nf-call-ip6tables = 1
    net.bridge.bridge-nf-call-iptables = 1
    net.ipv4.ip_forward = 1
EOF
echo 1 > /proc/sys/net/ipv4/ip_forward
sudo sysctl --system
}

# Install containerd
function install-containerd {
    if [ -x "$(command -v containerd)" ]
    then
        echo -e "${GREEN}containerd already installed${NC}"
    else
        echo  -e "${GREEN} installing containerd...${NC}"
        apt install -y curl gpgv gpgsm gnupg-l10n gnupg dirmngr software-properties-common apt-transport-https ca-certificates
        rm -rf /etc/apt/trusted.gpg.d/docker.gpg
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        sudo apt update
        sudo apt install -y containerd.io
        containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
        sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
        systemctl restart containerd
        systemctl enable containerd
    fi
}

# Install kubeadm
function install-kubeadm {
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl
    # If the folder `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below.
    sudo mkdir -p -m 755 /etc/apt/keyrings
    rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    
    # This overwrites any existing configuration in /etc/apt/sources.list.d/kubernetes.list
    rm -rf /etc/apt/sources.list.d/kubernetes.list
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${packageVersion}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    echo "package version set to ${packageVersion}"

    sudo apt-get update
    echo -e "${GREEN} installing kubectl kubeadm kubelet...${NC}"
    sudo apt-get install -y kubelet="${k8sVersion}-1.1" kubeadm="${k8sVersion}-1.1" kubectl="${k8sVersion}-1.1"
}

# Init K8s
function k8s-init {
	echo -e "${GREEN} init k8s...${NC}"
    mkdir -p /etc/kubernetes/pki

    # if no certsKey provided, create a new one
    if [ -z "$certsKey" ]; then
        certsKey=$(kubeadm certs certificate-key)
    fi

    # kubeadm automatically will create the CA key and cert if ca.key and ca.crt are empty;
    # If only one is provided, kubeadm will error out. So we need do nothing except populate
    # whatever we were passed.

    if [ -n "$caKey" ]; then
        echo -n "$caKey" | base64 -d > /etc/kubernetes/pki/ca.key
    fi
    if [ -n "$caCert" ]; then
        echo -n "$caCert" | base64 -d > /etc/kubernetes/pki/ca.crt
    fi
    if [ -n "$caKeyFile" -a "$caKeyFile" != /etc/kubernetes/pki/ca.key ]; then
        cp $caKeyFile /etc/kubernetes/pki/ca.key
    fi
    if [ -n "$caCertFile" -a "$caCertFile" != /etc/kubernetes/pki/ca.crt ]; then
        cp $caCertFile /etc/kubernetes/pki/ca.crt
    fi

# Generate init configuration file
# Read more: https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta3/
cat > $kubeadmyaml <<EOF
apiVersion: ${kubeadmVersion}
kind: InitConfiguration
nodeRegistration:
  name: "$nodeName"
  criSocket: "$crisock"
  kubeletExtraArgs:
    cloud-provider: "external"
    node-ip: "$nodeIp"
localAPIEndpoint:
  advertiseAddress: ${nodeIp}
  bindPort: ${bindPort}
certificateKey: ${certsKey}
---
apiVersion: ${kubeadmVersion}
kind: ClusterConfiguration
featureGates:
  EtcdLearnerMode: true
kubernetesVersion: ${k8sVersion}
controlPlaneEndpoint: ${advertiseAddress}:${bindPort}
apiServer:
  extraArgs:
    cloud-provider: "external"
controllerManager:
  extraArgs:
    cloud-provider: "external"
networking:
  podSubnet: "10.244.0.0/16"
EOF
    # do we need to add the advertiseAddress to our local host?
    ping -c 3 -q ${advertiseAddress} && echo OK || ip addr add ${advertiseAddress}/32 dev lo
    kubeadm init --config=$kubeadmyaml --upload-certs
    
    export KUBECONFIG=/etc/kubernetes/admin.conf
    mkdir -p ${HOME}/.kube
    sudo cp -i /etc/kubernetes/admin.conf ${HOME}/.kube/config
    sudo chown $(id -u):$(id -g) .kube/config
}

function k8s-join() {
    if [ -z "$bootstrap" ]; then
        echo "mode join had no valid bootstrap token" >&2
        usage
    fi
    if [ -z "$certsha" ]; then
        echo "mode join had no valid CA certs shas" >&2
        usage
    fi
    if [ -z "$certsKey" ]; then
        echo "mode join had no valid certs encryption key" >&2
        usage
    fi
cat > $kubeadmyaml <<EOF
apiVersion: ${kubeadmVersion}
kind: JoinConfiguration
nodeRegistration:
  name: "$nodeName"
  criSocket: "$crisock"
  kubeletExtraArgs:
    cloud-provider: "external"
    node-ip: "$nodeIp"
discovery:
  bootstrapToken:
    apiServerEndpoint: ${advertiseAddress}:${bindPort}
    token: ${bootstrap}
    caCertHashes:
    - ${certsha}
controlPlane:
  localAPIEndpoint:
    advertiseAddress: ${nodeIp}
    bindPort: ${bindPort}
  certificateKey: ${certsKey}
EOF
    kubeadm join --config=$kubeadmyaml --ignore-preflight-errors=all
    echo "Done."
}

# Install cni
function install-cni {
    echo  -e "${GREEN} Deploying the Flannel Network Plugin..${NC}"
    kubectl apply -f https://raw.githubusercontent.com/daviddang91/kubeadm-install/main/flannel-netbird.yml
    sleep 120
    kubectl wait pods -n kube-flannel  -l app=flannel --for condition=Ready --timeout=180s
}

# Install Helm
function install-helm {
	if [ -x "$(command -v helm)" ]
    then
        echo -e "${GREEN} Helm already installed ${NC}"
    else
		echo -e "${GREEN} Installing Helm ${NC}"
        wget https://get.helm.sh/helm-v3.9.3-linux-amd64.tar.gz
        tar -zxvf helm-v3.9.3-linux-amd64.tar.gz
        sudo mv linux-amd64/helm /usr/local/bin/helm
	fi	
}

# Preinstall kubeadm
function preinstall_kubeadm() {
    echo -e "${GREEN} *** Please make sure inbound ports 6443,443,8080 are allowed *** ${NC}"
    sleep 3
    disable-swap
    load-kernel-modules
    network
    install-containerd
    if pgrep -x "containerd" >/dev/null 
    then
        echo -e "${GREEN}containerd is up and running${NC}"
    else
        echo -e "${RED}containerd is not running${NC}"
        echo -e "${RED}Please check the logs and re-run this script${NC}"
        exit
    fi
}

# Install K8s master
function install-k8s-master() {
    preinstall_kubeadm
    install-kubeadm
    k8s-init
    install-cni
    install-helm
    echo -e "${GREEN}Now you can join the other nodes to the cluster with the join command below:${NC}"
    echo
    echo "To get the bootstrap information and CA cert hashes for another node, run:"
    echo "   kubeadm token create --print-join-command"
    echo
    echo "Here are join commands:"
    joincmd=$(kubeadm token create --print-join-command "$bootstrap")
    if [ -z "$bootstrap" ]; then
        bootstrap=$(echo ${joincmd} | awk '{print $5}')
    fi
    certsha=$(echo ${joincmd} | awk '{print $7}')
    echo "control plane: ${curlinstall} "'|'" sh -s join -a ${advertiseAddress} -v ${k8sVersion} -b ${bootstrap} -s ${certsha} -e ${certsKey}"
    echo "worker       : ${curlinstall} "'|'" sh -s worker -a ${advertiseAddress} -v ${k8sVersion} -b ${bootstrap} -s ${certsha}"
}

# Join k8s master
function join-k8s-master() {
    preinstall_kubeadm
    install-kubeadm
    k8s-join
}

# Reset K8s
function reset-k8s {
    # reset kubeadm
    echo -e "${YELLOW}Reset kubernetes cluster...${NC}"
    kubeadm reset -f
    rm -rf /etc/cni /etc/kubernetes /var/lib/dockershim /var/lib/etcd /var/lib/kubelet /var/run/kubernetes ~/.kube/*
    iptables -F && iptables -X
    iptables -t nat -F && iptables -t nat -X
    iptables -t raw -F && iptables -t raw -X
    iptables -t mangle -F && iptables -t mangle -X
    systemctl restart containerd
    if [ $? == 0 ]
    then 
        echo -e "${GREEN} OK! ${NC}"
    else
        echo -e "${RED}Something went wrong!${NC}"
    fi

    # remove kubeadm packages
    echo -e "${YELLOW}Removing kubeadm kubectl kubelet kubernetes-cni...${NC}"
    sudo apt-get purge -y kubeadm kubectl kubelet kubernetes-cni
    if [ $? == 0 ]
    then 
        echo -e "${GREEN} OK! ${NC}"
    else
        echo -e "${RED}Something went wrong!${NC}"
    fi

    # remove docker & containerd
    sudo apt-get purge -y docker* containerd*
	if [ $? == 0 ]
	then
		echo -e "${GREEN} OK! ${NC}"
	else
		echo -e "${RED}Something went wrong!${NC}"
	fi
}

# Guideline
function usage() {
    echo "Usage:" >&2
    echo "$0 <mode> -r <runtime> -a <advertise address> [opts...]" >&2
    echo -n "where <mode> is one of: " >&2
    echo "$modes" >&2
    echo -n "where <runtime> is one of: ">&2
    echo "$runtimes" >&2
    echo "where <advertise address> is the advertising address for init mode, e.g. 147.75.78.157:6443">&2
    echo >&2
    echo "where" >&2
    echo "  -b <bootstrap> is the bootstrap token, e.g. 36ah6j.nv8myy52hpyy5gso" >&2
    echo "  -s <ca certs hash> is the CA cert hashes, e.g. sha256:c9f1621ec77ed9053cd4a76f85d609791b20fab337537df309d3d8f6ac340732" >&2
    echo "  -e <ca certs encryption key> is the CA cert keys, e.g. b98b6165eafb91dd690bb693a8e2f57f6043865fcf75da68abc251a7f3dba437" >&2
    echo "  -k <ca private key> is the CA private key, PEM format and base64 encoded; may also be provided in a PEM file" >&2
    echo "  -c <ca cert> is the CA certificate, PEM format and base64 encoded; may also be provided in a PEM file" >&2
    echo "  -i <ip> is the local address of the host to use for the API endpoint; defaults to whatever kubeadm discovers" >&2
    echo "  -o <os full> is the OS name and version to install for, e.g. ubuntu_16_04; defaults to discovery from /etc/os-release" >&2
    echo "  -n kubernetes version, defaults to ${default_kubernetes_version} (because -k and -v were taken)" >&2
    echo "  -v verbose" >&2
    echo "  -d to dry-run and exit" >&2
    echo "  -h to show usage and exit" >&2
    exit 10
}

###START HERE###
mode="$1"
shift

while getopts ":h?:a:b:e:k:c:s:i:v:n:g:f:" opt; do
  case $opt in
    h|\?)
        usage
        ;;
    a)
        advertiseAddress=$OPTARG
        ;;
    v)
        k8sVersion=$OPTARG
        ;;
    b)
        bootstrap=$OPTARG
        ;;
    e)
        certsKey=$OPTARG
        ;;
    k)
        caKey=$OPTARG
        ;;
    c)
        caCert=$OPTARG
        ;;
    f)
        caKeyFile=$OPTARG
        ;;
    g)
        caCertFile=$OPTARG
        ;;
    s)
        certsha=$OPTARG
        ;;
    i)
        nodeIp=$OPTARG
        ;;
    n)
        nodeName=$OPTARG
        ;;
  esac
done

packageVersion=${k8sVersion%.*}

# supported modes
modes="init join worker reset"

if [ "$mode" = "" ]; then
    echo "mode required" >&2
    usage
    exit 1
else
    found=$(echo $modes | grep -w $mode 2>/dev/null)
    if [ -z "$found" ]; then
        echo "unsupported mode $mode" >&2
        exit 1
    fi
fi

case $mode in
    "init")
        install-k8s-master
    ;;
    "join")
        join-k8s-master
    ;;
    "worker")
        echo "Hello 3"
    ;;
    "reset")
        reset-k8s
    ;;
esac

#!/bin/bash

export PATH=${PWD}/bin:${PWD}:$PATH
export FABRIC_CFG_PATH=${PWD}
export VERBOSE=false

# Print the usage message
function printHelp() {
  echo "Usage: "
  echo "  network.sh <mode> [-c <channel name>] [-t <timeout>] [-d <delay>] [-f <docker-compose-file>] [-s <dbtype>] [-l <language>] [-o <consensus-type>] [-i <imagetag>] [-v]"
  echo "    <mode> - one of 'up', 'down', 'restart', 'retry', 'install', 'update' or 'generate'"
  echo "      - 'up' - bring up the network with docker-compose up"
  echo "      - 'down' - clear the network with docker-compose down"
  echo "      - 'restart' - restart the network"
  echo "      - 'retry' - retry bootstrapping the network"
  echo "      - 'install' - install and instantiate a specific version of chaincode"
  echo "      - 'update' - update chaincode to a new version"
  echo "      - 'generate' - generate required certificates and genesis block"
  echo "    -c <channel name> - channel name to use (defaults to \"deliverychannel\")"
  echo "    -t <timeout> - CLI timeout duration in seconds (defaults to 20)"
  echo "    -d <delay> - delay duration in seconds (defaults to 20)"
  echo "    -f <docker-compose-file> - specify which docker-compose file use (defaults to docker-compose-e2e.yaml)"
  echo "    -s <dbtype> - the database backend to use: couchdb (default)"
  echo "    -l <language> - the chaincode language: node (default)"
  echo "    -i <imagetag> - the tag to be used to launch the network (defaults to \"latest\")"
  echo "    -v new version of updated chaincode to install on all endorsers"
  echo "  network.sh -h (print this message)"
  echo
  echo "Typically, one would first generate the required certificates and "
  echo "genesis block, then bring up the network. e.g.:"
  echo
  echo "	fabricNetwork.sh generate -c deliverychannel"
  echo "	fabricNetwork up -c deliverychannel -s couchdb"
  echo "        fabricNetwork up -c deliverychannel -s couchdb -i 1.4.0"
  echo "	fabricNetwork up -l node"
  echo "	fabricNetwork down -c deliverychannel"
  echo
  echo "Taking all defaults:"
  echo "	fabricNetwork generate"
  echo "	fabricNetwork up"
  echo "	fabricNetwork install"
  echo "	fabricNetwork down"
}

# Ask user for confirmation to proceed
function askProceed() {
  read -p "Continue? [Y/n] " ans
  case "$ans" in
  y | Y | "")
    echo "proceeding ..."
    ;;
  n | N)
    echo "exiting..."
    exit 1
    ;;
  *)
    echo "invalid response"
    askProceed
    ;;
  esac
}

# Obtain CONTAINER_IDS and remove them
# TODO Might want to make this optional - could clear other containers
function clearContainers() {
  CONTAINER_IDS=$(docker ps -a | awk '($2 ~ /dev-peer.*.mycc.*/) {print $1}')
  if [ -z "$CONTAINER_IDS" -o "$CONTAINER_IDS" == " " ]; then
    echo "---- No containers available for deletion ----"
  else
    docker rm -f "$CONTAINER_IDS"
  fi
}

# Delete any images that were generated as a part of this setup
# specifically the following images are often left behind:
# TODO list generated image naming patterns
function removeUnwantedImages() {
  DOCKER_IMAGE_IDS=$(docker images | awk '($1 ~ /dev-peer.*.mycc.*/) {print $3}')
  if [ -z "$DOCKER_IMAGE_IDS" -o "$DOCKER_IMAGE_IDS" == " " ]; then
    echo "---- No images available for deletion ----"
  else
    docker rmi -f "$DOCKER_IMAGE_IDS"
  fi
}

# Versions of fabric known not to work with this release of first-network
BLACKLISTED_VERSIONS="^1\.0\. ^1\.1\.0-preview ^1\.1\.0-alpha"

# Do some basic sanity checking to make sure that the appropriate versions of fabric
# binaries/images are available.  In the future, additional checking for the presence
# of go or other items could be added.
function checkPrereqs() {
  # Note, we check configtxlator externally because it does not require a config file, and peer in the
  # docker image because of FAB-8551 that makes configtxlator return 'development version' in docker
  LOCAL_VERSION=$(configtxlator version | sed -ne 's/ Version: //p')
  DOCKER_IMAGE_VERSION=$(docker run --rm hyperledger/fabric-tools:"$IMAGETAG" peer version | sed -ne 's/ Version: //p' | head -1)

  echo "LOCAL_VERSION=$LOCAL_VERSION"
  echo "DOCKER_IMAGE_VERSION=$DOCKER_IMAGE_VERSION"

  if [ "$LOCAL_VERSION" != "$DOCKER_IMAGE_VERSION" ]; then
    echo "=================== WARNING ==================="
    echo "  Local fabric binaries and docker images are  "
    echo "  out of  sync. This may cause problems.       "
    echo "==============================================="
  fi

  for UNSUPPORTED_VERSION in $BLACKLISTED_VERSIONS; do
    echo "$LOCAL_VERSION" | grep -q "$UNSUPPORTED_VERSION"
    if [ $? -eq 0 ]; then
      echo "ERROR! Local Fabric binary version of $LOCAL_VERSION does not match this newer version of registration-network and is unsupported. Either move to a later version of Fabric or checkout an earlier version of registration-network."
      exit 1
    fi

    echo "$DOCKER_IMAGE_VERSION" | grep -q "$UNSUPPORTED_VERSION"
    if [ $? -eq 0 ]; then
      echo "ERROR! Fabric Docker image version of $DOCKER_IMAGE_VERSION does not match this newer version of registration-network and is unsupported. Either move to a later version of Fabric or checkout an earlier version of registration-network."
      exit 1
    fi
  done
}

# Generate the needed certificates, the genesis block and start the network.
function networkUp() {
  checkPrereqs
  # generate artifacts if they don't exist
  if [ ! -d "crypto-config" ]; then
    generateCerts
    # replacePrivateKey
    generateChannelArtifacts
  fi
  # Start the docker containers using compose file
  IMAGE_TAG=$IMAGETAG docker-compose -f "$COMPOSE_FILE" up -d 2>&1
  docker ps -a
  if [ $? -ne 0 ]; then
    echo "ERROR !!!! Unable to start network"
    exit 1
  fi
  # Wait for 10 seconds to allow the docker network to stabilise
  sleep 1
  echo "Sleeping 10s to allow cluster to complete booting"
  sleep 9

  # now run the bootstrap script
   chmod 777 /home/rohit/workspace/delivery-network/network/scripts/bootstrap.sh
  docker exec cli scripts/bootstrap.sh "$CHANNEL_NAME" "$CLI_DELAY" "$LANGUAGE" "$CLI_TIMEOUT" "$VERBOSE"
  if [ $? -ne 0 ]; then
    echo "ERROR !!!! Test failed"
    exit 1
  fi
}

# Generate the needed certificates, the genesis block and start the network.
function bootstrapRetry() {
  checkPrereqs
  # now run the bootstrap script
  docker exec cli scripts/bootstrap.sh "$CHANNEL_NAME" "$CLI_DELAY" "$LANGUAGE" "$CLI_TIMEOUT" "$VERBOSE"
}

function updateChaincode() {
  checkPrereqs
  docker exec cli scripts/updateChaincode.sh "$CHANNEL_NAME" "$CLI_DELAY" "$LANGUAGE" "$VERSION_NO" "$TYPE"
}

function installChaincode() {
  checkPrereqs
  chmod 777 /home/rohit/workspace/delivery-network/network/scripts/installChaincode.sh
  docker exec cli scripts/installChaincode.sh "$CHANNEL_NAME" "$CLI_DELAY" "$LANGUAGE" "$VERSION_NO" "$TYPE"
}

# Tear down running network
function networkDown() {
  # stop all containers
  # stop kafka and zookeeper containers in case we're running with kafka consensus-type
  docker-compose -f "$COMPOSE_FILE" down --volumes --remove-orphans

  # Don't remove the generated artifacts -- note, the ledgers are always removed
  if [ "$MODE" != "restart" ]; then
    # Bring down the network, deleting the volumes
    # Delete any ledger backups
    docker run -v "$PWD":/tmp/deliverychannel --rm hyperledger/fabric-tools:"$IMAGETAG" rm -Rf /tmp/deliverychannel/ledgers-backup
    #Cleanup the chaincode containers
    clearContainers
    #Cleanup images
    removeUnwantedImages
    # remove orderer block and other channel configuration transactions and certs
    rm -rf channel-artifacts/*.block channel-artifacts/*.tx crypto-config
  fi
}


# Generates Org certs using cryptogen tool
function generateCerts() {
  chmod 777 /home/rohit/workspace/delivery-network/network/bin/cryptogen
  which cryptogen
  if [ "$?" -ne 0 ]; then
    echo "cryptogen tool not found. exiting"
    exit 1
  fi
  echo
  echo "##########################################################"
  echo "##### Generate certificates using cryptogen tool #########"
  echo "##########################################################"

  if [ -d "crypto-config" ]; then
    rm -Rf crypto-config
  fi
  set -x
  cryptogen generate --config=./crypto-config.yaml
  res=$?
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate certificates..."
    exit 1
  fi
  echo
}

# Generate orderer genesis block, channel configuration transaction and
# anchor peer update transactions

#UPDATE required
function generateChannelArtifacts() {
  chmod 777 /home/rohit/workspace/delivery-network/network/bin/configtxgen
  which configtxgen
  if [ "$?" -ne 0 ]; then
    echo "configtxgen tool not found. exiting"
    exit 1
  fi

  echo "##########################################################"
  echo "#########  Generating Orderer Genesis block ##############"
  echo "##########################################################"
  # Note: For some unknown reason (at least for now) the block file can't be
  # named orderer.genesis.block or the orderer will fail to launch!
  set -x
  chmod 777 /home/rohit/workspace/delivery-network/network/channel-artifacts/genesis.block
  configtxgen -profile OrdererGenesis -channelID delivery-sys-channel -outputBlock ./channel-artifacts/genesis.block
  res=0
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate orderer genesis block..."
    exit 1
  fi
  echo
  echo "#################################################################"
  echo "### Generating channel configuration transaction 'channel.tx' ###"
  echo "#################################################################"
  set -x
  chmod 777 /home/rohit/workspace/delivery-network/network/channel-artifacts
  configtxgen -profile DeliveryChannel -outputCreateChannelTx ./channel-artifacts/channel.tx -channelID "$CHANNEL_NAME"
  res=0
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate channel configuration transaction..."
    exit 1
  fi

  echo
  echo "#################################################################"
  echo "#######    Generating anchor peer update for restaurantMSP   ####"
  echo "#################################################################"
  set -x
  configtxgen -profile DeliveryChannel -outputAnchorPeersUpdate ./channel-artifacts/restaurantMSPanchors.tx -channelID "$CHANNEL_NAME" -asOrg restaurantMSP
  res=0
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate anchor peer update for registrar..."
    exit 1
  fi

  echo
  echo "#################################################################"
  echo "#######    Generating anchor peer update for squadMSP   #########"
  echo "#################################################################"
  set -x
  configtxgen -profile DeliveryChannel -outputAnchorPeersUpdate ./channel-artifacts/squadors.tx -channelID "$CHANNEL_NAME" -asOrg squadMSP
  res=0
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate anchor peer update for users..."
    exit 1
  fi
  echo

  echo
  echo "#################################################################"
  echo "#######    Generating anchor peer update for customerMSP   ######"
  echo "#################################################################"
  set -x
  configtxgen -profile DeliveryChannel -outputAnchorPeersUpdate ./channel-artifacts/customerMSPanchors.tx -channelID "$CHANNEL_NAME" -asOrg customerMSP
  res=0
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate anchor peer update for Consumer..."
    exit 1
  fi
  echo
  

}

# timeout duration - the duration the CLI should wait for a response from
# another container before giving up
CLI_TIMEOUT=15
# default for delay between commands
CLI_DELAY=5
# channel name defaults to "deliverychannel"
CHANNEL_NAME="deliverychannel"
# version for updating chaincode
VERSION_NO=1.1
# type of chaincode to be installed
TYPE="basic"
# use this as the default docker-compose yaml definition
COMPOSE_FILE=docker-compose-e2e.yml
# use node as the default language for chaincode
LANGUAGE="node"
# default image tag
IMAGETAG="latest"
# Parse commandline args
if [ "$1" = "-m" ]; then # supports old usage, muscle memory is powerful!
  shift
fi
MODE=$1
shift
# Determine which command to run
if [ "$MODE" == "up" ]; then
  EXPMODE="Starting"
elif [ "$MODE" == "down" ]; then
  EXPMODE="Stopping"
elif [ "$MODE" == "restart" ]; then
  EXPMODE="Restarting"
elif [ "$MODE" == "retry" ]; then
  EXPMODE="Retrying network bootstrap"
elif [ "$MODE" == "update" ]; then
  EXPMODE="Updating chaincode"
elif [ "$MODE" == "install" ]; then
  EXPMODE="Installing chaincode"
elif [ "$MODE" == "generate" ]; then
  EXPMODE="Generating certs and genesis block"
else
  printHelp
  exit 1
fi

while getopts "h?c:t:d:f:l:i:v:m:" opt; do
  case "$opt" in
  h | \?)
    printHelp
    exit 0
    ;;
  c)
    CHANNEL_NAME=$OPTARG
    ;;
  t)
    CLI_TIMEOUT=$OPTARG
    ;;
  d)
    CLI_DELAY=$OPTARG
    ;;
  f)
    COMPOSE_FILE=$OPTARG
    ;;
  l)
    LANGUAGE=$OPTARG
    ;;
  v)
    VERSION_NO=$OPTARG
    ;;
  m)
    TYPE=$OPTARG
    ;;
  i)
    IMAGETAG=$(go env GOARCH)"-"$OPTARG
    ;;
  esac
done

# Announce what was requested
echo "${EXPMODE} for channel '${CHANNEL_NAME}' with CLI timeout of '${CLI_TIMEOUT}' seconds and CLI delay of '${CLI_DELAY}' seconds and chaincode version '${VERSION_NO}' "
# ask for confirmation to proceed
askProceed

#Create the network using docker compose
if [ "${MODE}" == "up" ]; then
  networkUp
elif [ "${MODE}" == "down" ]; then ## Clear the network
  networkDown
elif [ "${MODE}" == "generate" ]; then ## Generate Artifacts
  generateCerts
  # replacePrivateKey
  generateChannelArtifacts
elif [ "${MODE}" == "restart" ]; then ## Restart the network
  networkDown
  networkUp
elif [ "${MODE}" == "retry" ]; then ## Retry bootstrapping the network
  bootstrapRetry
elif [ "${MODE}" == "update" ]; then ## Run the composer setup commands
  updateChaincode
elif [ "${MODE}" == "install" ]; then ## Run the composer setup commands
  installChaincode
else
  printHelp
  exit 1
fi

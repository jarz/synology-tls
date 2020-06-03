#!/bin/sh

#======================================================================================================================
# Title         : syno_docker_update.sh
# Description   : Updates or restores Docker Engine and Docker Compose on Synology to target version
# Author        : Mark Dumay
# Date          : June 3rd, 2020
# Version       : 0.1
# Usage         : sudo ./syno_docker_update.sh [OPTIONS] COMMAND
# Repository    : https://github.com/markdumay/synology-tls.git
# Comments      : Inspired by https://gist.github.com/Mikado8231/bf207a019373f9e539af4d511ae15e0d
#======================================================================================================================

#======================================================================================================================
# Constants
#======================================================================================================================
DSM_SUPPORTED_VERSION=6
DOWNLOAD_DOCKER=https://download.docker.com/linux/static/stable/x86_64
DOWNLOAD_GITHUB=https://github.com/docker/compose
GITHUB_RELEASES=/docker/compose/releases/tag
SYNO_DOCKER_SERV_NAME=pkgctl-Docker
SYNO_DOCKER_DIR=/var/packages/Docker
SYNO_DOCKER_BIN_PATH=$SYNO_DOCKER_DIR/target/usr
SYNO_DOCKER_BIN=$SYNO_DOCKER_BIN_PATH/bin
SYNO_DOCKER_JSON_PATH=$SYNO_DOCKER_DIR/etc
SYNO_DOCKER_JSON=$SYNO_DOCKER_JSON_PATH/dockerd.json
SYNO_DOCKER_JSON_CONFIG="
{
    ""data-root"" : ""$SYNO_DOCKER_DIR/target/docker"",
    ""log-driver"" : ""json-file"",
    ""registry-mirrors"" : [],
    ""group"": ""administrators""
}"


#======================================================================================================================
# Variables
#======================================================================================================================
WORKING_DIR="/tmp/docker_update"
DOCKER_BACKUP_FILENAME="$WORKING_DIR/docker_backup_$(date +%Y%m%d_%H%M%S).tgz"
SKIP_DOCKER_UPDATE='false'
SKIP_COMPOSE_UPDATE='false'
FORCE='false'
# TODO: TEMP setting for debugging
# STAGE='false'
STAGE='true'
COMMAND=''
TARGET_DOCKER_VERSION=''
TARGET_COMPOSE_VERSION=''
BACKUP_FILENAME_FLAG='false'
STEP=1
TOTAL_STEPS=8


#======================================================================================================================
# Helper Functions
#======================================================================================================================

# Display usage message
usage() { 
    echo "Usage: $0 [OPTIONS] COMMAND" 
    echo
    echo "Options:"
    echo "  -b, --backup NAME      Path and name of the backup (defaults to "
    echo "                         '$WORKING_DIR/docker_backup_YYMMDDHHMMSS.tgz')"
    echo "  -c, --compose VERSION  Docker Compose target version (defaults to latest)"
    echo "  -d, --docker VERSION   Docker target version (defaults to latest)"
    echo "  -f, --force            Force update (bypass compatibility check)"
    echo "  -s, --stage            Stage only, do not actually replace binaries or configuration of log driver"
    echo
    echo "Commands:"
    echo "  backup                 Create a backup of Docker and Docker Compose binaries and dockerd configuration"
    echo "  download [PATH]        Download Docker and Docker Compose binaries to PATH"
    echo "  install [PATH]         Update Docker and Docker Compose from files on PATH"
    echo "  restore                Restore Docker and Docker Compose from backup"
    echo "  update                 Update Docker and Docker Compose to target version (creates backup first)"
    echo
}

# Display error message and terminate with non-zero error
terminate() {
    echo "ERROR: $1"
    echo
    exit 1
}

# Prints current progress to the console
print_status () {
    echo "Step $((STEP++)) from $TOTAL_STEPS: $1"
}

# Detects current versions for DSM, Docker, and Docker Compose
detect_current_versions() {
    # Detect current DSM version
    DSM_VERSION=$(cat /etc.defaults/VERSION 2> /dev/null | grep '^productversion' | cut -d'=' -f2 | sed "s/\"//g")
    DSM_MAJOR_VERSION=$(cat /etc.defaults/VERSION 2> /dev/null | grep '^majorversion' | cut -d'=' -f2 | sed "s/\"//g")
    DSM_BUILD=$(cat /etc.defaults/VERSION 2> /dev/null | grep '^buildnumber' | cut -d'=' -f2 | sed "s/\"//g")

    # Detect current Docker version
    DOCKER_VERSION=$(docker -v | egrep -o "[0-9]*.[0-9]*.[0-9]*," | cut -d',' -f 1)

    # Detect current Docker Compose version
    COMPOSE_VERSION=$(docker-compose -v | egrep -o "[0-9]*.[0-9]*.[0-9]*," | cut -d',' -f 1)

    echo "Current DSM version: $(printf ${DSM_VERSION:-Unknown})"
    echo "Current Docker version: $(printf ${DOCKER_VERSION:-Unknown})"
    echo "Current Docker Compose version: $(printf ${COMPOSE_VERSION:-Unknown})"
    if [ "$FORCE" != 'true' ] ; then
        validate_current_version
    fi
}

# Validates current versions for DSM, Docker, and Docker Compose
validate_current_version() {
    # Test if host is DSM 6, exit otherwise
    if [ "$DSM_MAJOR_VERSION" != "$DSM_SUPPORTED_VERSION" ] ; then
        terminate "This script supports DSM 6.x only, use --force to override"
    fi

    # Test Docker version is present, exit otherwise
    if [ -z "$DOCKER_VERSION" ] ; then
        terminate "Could not detect current Docker version, use --force to override"
    fi

    # Test Docker Compose version is present, exit otherwise
    if [ -z "$COMPOSE_VERSION" ] ; then
        terminate "Could not detect current Docker Compose version, use --force to override"
    fi
}

# Detects downloaded Docker versions
detect_available_downloads() {
    if [ -z "$TARGET_DOCKER_VERSION" ] ; then
        echo "find $WORKING_DIR/ | cut -c 4- | egrep -o 'docker-[0-9]*.[0-9]*.[0-9]*(-ce)?.tgz'"
        DOWNLOADS=$(find "$WORKING_DIR/" -maxdepth 1 -type f | cut -c 4- | egrep -o 'docker-[0-9]*.[0-9]*.[0-9]*(-ce)?.tgz')
        LATEST_DOWNLOAD=$(echo "$DOWNLOADS" | sort -bt. -k1,1 -k2,2n -k3,3n -k4,4n -k5,5n | tail -1)
        TARGET_DOCKER_VERSION=$(echo "$LATEST_DOWNLOAD" | sed "s/docker-//g" | sed "s/.tgz//g")
    fi
}

# Detects available versions for Docker and Docker Compose
detect_available_versions() {
    # Detect latest available Docker version
    if [ -z "$TARGET_DOCKER_VERSION" ] ; then
        DOCKER_BIN_FILES=$(curl -s "$DOWNLOAD_DOCKER/" | egrep -o '>docker-[0-9]*.[0-9]*.[0-9]*(-ce)?.tgz' | cut -c 2-)
        LATEST_DOCKER_BIN=$(echo "$DOCKER_BIN_FILES" | sort -bt. -k1,1 -k2,2n -k3,3n -k4,4n -k5,5n | tail -1)
        LATEST_DOCKER_VERSION=$(echo "$LATEST_DOCKER_BIN" | sed "s/docker-//g" | sed "s/.tgz//g" )
        TARGET_DOCKER_VERSION=$LATEST_DOCKER_VERSION
    fi

    # Detect latest available stable Docker Compose version (ignores release candidates)
    if [ -z "$TARGET_COMPOSE_VERSION" ] ; then
        COMPOSE_TAGS=$(curl -s "$DOWNLOAD_GITHUB/tags" | egrep "a href=\"$GITHUB_RELEASES/[0-9]+.[0-9]+.[0-9]+\"")
        LATEST_COMPOSE_VERSION=$(echo "$COMPOSE_TAGS" | head -1 | cut -c 45- | sed "s/\">//g")
        TARGET_COMPOSE_VERSION=$LATEST_COMPOSE_VERSION
    fi
}

# Validates available updates for Docker and Docker Compose
validate_available_versions() {
    # Test Docker is available for download, exit otherwise
    if [ -z "$TARGET_DOCKER_VERSION" ] ; then
        terminate "Could not find Docker binaries for downloading"
    fi

    # Test Docker Compose is available for download, exit otherwise
    if [ -z "$TARGET_COMPOSE_VERSION" ] ; then
        terminate "Could not find Docker Compose binaries for downloading"
    fi
}

# Validates downloads for Docker and Docker Compose
validate_downloaded_versions() {
    TARGET_DOCKER_BIN="docker-$TARGET_DOCKER_VERSION.tgz"
    # Test Docker archive is available on path
    if [ ! -f "$WORKING_DIR/$TARGET_DOCKER_BIN" ] ; then
        terminate "Could not find Docker archive ($WORKING_DIR/$TARGET_DOCKER_BIN)"
    fi

    if [ ! -f "$WORKING_DIR/docker-compose" ] ; then 
        terminate "Could not find Docker compose binary ($WORKING_DIR/docker-compose)"
    fi
}

# Validates user input conforms to expected version pattern
validate_version_input() {
    VALIDATION=$(echo "$1" | egrep -o "^[0-9]+.[0-9]+.[0-9]+")
    if [ "$VALIDATION" != "$1" ] ; then
        usage
        terminate "$2"
    fi
}

# Validates provided backup filename
validate_backup_filename() {
    # check filename is provided
    if [ -z "$DOCKER_BACKUP_FILENAME" ] || [ "${DOCKER_BACKUP_FILENAME:0:1}" == "-" ] ; then
        usage
        terminate "$1"
    fi
}

# Validates working directory is available
validate_working_dir() {
    # check PATH is provided
    if [ -z "$WORKING_DIR" ] || [ "${WORKING_DIR:0:1}" == "-" ] ; then
        usage
        terminate "$1"
    fi

    # cut trailing '/'
    if [ "${WORKING_DIR:0-1}" == "/" ] ; then
        WORKING_DIR="${WORKING_DIR%?}"
    fi

    # check PATH exists
    if [ ! -d "$WORKING_DIR" ] ; then
        usage
        terminate "$2"
    fi
}

# Defines update strategy for Docker and Docker Compose
define_update() {
    if [ "$FORCE" != 'true' ] ; then
        # Confirm update is necessary
        if [ "$DOCKER_VERSION" = "$TARGET_DOCKER_VERSION" ] && [ "$COMPOSE_VERSION" = "$TARGET_COMPOSE_VERSION" ] ; then
            terminate "Already on target version for Docker and Docker Compose"
        fi
        if [ "$DOCKER_VERSION" = "$TARGET_DOCKER_VERSION" ] ; then
            SKIP_DOCKER_UPDATE='true'
            TOTAL_STEPS=$((TOTAL_STEPS-1))
        fi
        if [ "$COMPOSE_VERSION" = "$TARGET_COMPOSE_VERSION" ] ; then
            SKIP_COMPOSE_UPDATE='true'
            TOTAL_STEPS=$((TOTAL_STEPS-1))
        fi
    fi
}

define_restore() {
    if [ "$BACKUP_FILENAME_FLAG" != 'true' ]; then
        terminate "Please specify backup filename (--backup NAME)"
    fi

    WORKING_DIR=$(dirname "$DOCKER_BACKUP_FILENAME")
}

define_target_version() {
    detect_available_versions
    echo "Target Docker version: $(printf ${TARGET_DOCKER_VERSION:-Unknown})"
    echo "Target Docker Compose version: $(printf ${TARGET_COMPOSE_VERSION:-Unknown})"
    validate_available_versions
}

define_target_download() {
    detect_available_downloads
    echo "Target Docker version: $(printf ${TARGET_DOCKER_VERSION:-Unknown})"
    echo "Target Docker Compose version: Unknown"
    validate_downloaded_versions
}


#======================================================================================================================
# Workflow Functions
#======================================================================================================================

# Stop Docker service if running
execute_stop_syno() {
    print_status "Stopping Docker service"
    SYNO_STATUS=$(synoservicectl --status "$SYNO_DOCKER_SERV_NAME" | grep running -o)
    if [ SYNO_STATUS == 'running' ] ; then
        synoservicectl --stop $SYNO_DOCKER_SERV_NAME
    fi
}

# Prepare working environment
execute_prepare() {
    print_status "Preparing working environment ($WORKING_DIR)"
    mkdir -p "$WORKING_DIR"
    execute_clean 'silent'
}

# Backup current Docker binaries
execute_backup() {
    print_status "Backing up current Docker binaries ($DOCKER_BACKUP_FILENAME)"
    BASEPATH=$(dirname "$DOCKER_BACKUP_FILENAME")
    FILENAME=$(basename "$DOCKER_BACKUP_FILENAME") 
    cd "$BASEPATH"
    tar -czf "$FILENAME" -C "$SYNO_DOCKER_BIN_PATH" bin -C "$SYNO_DOCKER_JSON_PATH" "dockerd.json"
    echo "tar -czf $FILENAME -C $SYNO_DOCKER_BIN_PATH bin -C $SYNO_DOCKER_JSON_PATH dockerd.json"
    if [ ! -f "$DOCKER_BACKUP_FILENAME" ] ; then
        terminate "Backup issue"
    fi
}

# Download target Docker binary
execute_download_bin() {
    if [ "$SKIP_DOCKER_UPDATE" == 'false' ] ; then
        TARGET_DOCKER_BIN="docker-$TARGET_DOCKER_VERSION.tgz"
        print_status "Downloading target Docker binary ($DOWNLOAD_DOCKER/$TARGET_DOCKER_BIN)"
        curl "$DOWNLOAD_DOCKER/$TARGET_DOCKER_BIN" -o "$WORKING_DIR/$TARGET_DOCKER_BIN"
        if [ ! -f "$WORKING_DIR/$TARGET_DOCKER_BIN" ] ; then 
            terminate "Binary could not be downloaded"
        fi
    fi
}

# Extract target Docker binary
execute_extract_bin() {
    if [ "$SKIP_DOCKER_UPDATE" == 'false' ] ; then
        TARGET_DOCKER_BIN="docker-$TARGET_DOCKER_VERSION.tgz"
        print_status "Extracting target Docker binary ($WORKING_DIR/$TARGET_DOCKER_BIN)"
        tar -zxvf "$WORKING_DIR/$TARGET_DOCKER_BIN" -C "$WORKING_DIR"
        if [ ! -d "$WORKING_DIR/docker" ] ; then 
            terminate "Files could not be extracted from archive"
        fi
    fi
}

# Extract target Docker binary
execute_extract_backup() {
    print_status "Extracting Docker backup ($WORKING_DIR/$DOCKER_BACKUP_FILENAME)"
    BASEPATH=$(dirname "$DOCKER_BACKUP_FILENAME")
    FILENAME=$(basename "$DOCKER_BACKUP_FILENAME") 
    cd "$BASEPATH"
    tar -zxvf "$FILENAME"
    mv bin docker

    if [ ! -d "$WORKING_DIR/docker" ] ; then 
        terminate "Docker binaries could not be extracted from archive"
    fi
    if [ ! -f "$WORKING_DIR/docker/docker-compose" ] ; then 
        terminate "Docker compose binary could not be extracted from archive"
    fi
    if [ ! -f "$WORKING_DIR/dockerd.json" ] ; then 
        terminate "log driver configuration could not be extracted from archive"
    fi
}

# Download target Docker Compose binary
execute_download_compose() {
    if [ "$SKIP_COMPOSE_UPDATE" == 'false' ] ; then
        COMPOSE_BIN="$DOWNLOAD_GITHUB/releases/download/$TARGET_COMPOSE_VERSION/docker-compose-Linux-x86_64"
        print_status "Downloading target Docker Compose binary ($COMPOSE_BIN)"
        curl -L "$COMPOSE_BIN" -o "$WORKING_DIR/docker-compose"
        if [ ! -f "$WORKING_DIR/docker-compose" ] ; then 
            terminate "Binary could not be downloaded"
        fi
    fi
}

# Install binaries
execute_install_bin() {
    print_status "Installing binaries"
    if [ STAGE == 'false' ] ; then
        echo "TODO: implement"
        # TODO: implement
        echo "mv $WORKING_DIR/docker/* $SYNO_DOCKER_BIN/"
        echo "mv $WORKING_DIR/docker-compose $SYNO_DOCKER_BIN/docker-compose"
        echo "chmod +x $SYNO_DOCKER_BIN/*"
        #mv "$WORKING_DIR/docker/* $SYNO_DOCKER_BIN/"
        #mv "$WORKING_DIR/docker-compose $SYNO_DOCKER_BIN/docker-compose"
        #chmod +x "$SYNO_DOCKER_BIN/*"
    else
        echo "Skipping installation in STAGE mode"
    fi
}

# Restore binaries
execute_restore_bin() {
    print_status "Restoring binaries"
    if [ STAGE == 'false' ] ; then
        echo "TODO: implement"
        # TODO: implement
        echo "mv $WORKING_DIR/docker/* $SYNO_DOCKER_BIN/"
        echo "chmod +x $SYNO_DOCKER_BIN/*"
        #mv "$WORKING_DIR/docker/* $SYNO_DOCKER_BIN/"
        #chmod +x "$SYNO_DOCKER_BIN/*"
    else
        echo "Skipping restoring in STAGE mode"
    fi
}

# Configure log driver
execute_update_log() {
    print_status "Configuring log driver"
    if [ STAGE == 'false' ] ; then
        if [ ! -f "$SYNO_DOCKER_JSON" ] || grep "json-file" "$SYNO_DOCKER_JSON" -q ; then
            mkdir -p "$SYNO_DOCKER_DIR/etc/"
            printf "$SYNO_DOCKER_JSON_CONFIG" > "$SYNO_DOCKER_JSON"
        fi
    else
        echo "Skipping configuration in STAGE mode"
    fi
}

# Restore log driver
execute_restore_log() {
    print_status "Restoring log driver"
    if [ STAGE == 'false' ] ; then
        echo "TODO: implement"
        echo "mv $WORKING_DIR/dockerd.json $SYNO_DOCKER_JSON"
        #mv "$WORKING_DIR/docker/dockerd.json $SYNO_DOCKER_JSON"
    else
        echo "Skipping restoring in STAGE mode"
    fi
}

# Start Docker service
execute_start_syno() {
    print_status "Starting Docker service"
    synoservicectl --start "$SYNO_DOCKER_SERV_NAME"

    SYNO_STATUS=$(synoservicectl --status "$SYNO_DOCKER_SERV_NAME" | grep running -o)
    if [ SYNO_STATUS != 'running' ] ; then
        if [ "$FORCE" != 'true' ] ; then
            terminate "Could not bring Docker Engine back online"
        else
            echo "ERROR: Could not bring Docker Engine back online"
        fi
    fi
}

# Clean the working folder
execute_clean() {
    if [ "$1" != 'silent' ] ; then
        print_status "Cleaning the working folder"
    fi
    rm -rf "$WORKING_DIR/docker"
}

#======================================================================================================================
# Main Script
#======================================================================================================================

# Show header
echo "Update Docker Engine and Docker Compose on Synology to target version"
echo 

# Test if script has root privileges, exit otherwise
if [[ $(id -u) -ne 0 ]]; then 
    usage
    terminate "You need to be root to run this script"
fi

# Process and validate command-line arguments
while [ "$1" != "" ]; do
    case "$1" in
        -b | --backup )
            shift
            DOCKER_BACKUP_FILENAME="$1"
            BACKUP_FILENAME_FLAG='true'
            validate_backup_filename "Filename not provided"
            ;;
        -c | --compose )
            shift
            TARGET_COMPOSE_VERSION="$1"
            validate_version_input "$TARGET_COMPOSE_VERSION" "Unrecognized target Docker Compose version"
            ;;
        -d | --docker )
            shift
            TARGET_DOCKER_VERSION="$1"
            validate_version_input "$TARGET_DOCKER_VERSION" "Unrecognized target Docker version"
            ;;
        -f | --force )
            FORCE='true'
            ;;
        -h | --help )
            usage
            exit
            ;;
        -s | --stage )
            STAGE='true'
            ;;
        backup | restore | update )
            COMMAND="$1"
            ;;
        download | install )
            COMMAND="$1"
            shift
            WORKING_DIR="$1"
            validate_working_dir "Path not specified" "Path not found"
            ;;
        * )
            usage
            terminate "Unrecognized parameter ($1)"
    esac
    shift
done

# Execute workflows
case "$COMMAND" in
    backup )
        TOTAL_STEPS=4
        detect_current_versions
        execute_stop_syno
        execute_prepare
        execute_backup
        execute_start_syno
        ;;
    download )
        TOTAL_STEPS=3
        detect_current_versions
        define_target_version
        execute_prepare
        execute_download_bin
        execute_download_compose
        ;;
    install )
        TOTAL_STEPS=7
        detect_current_versions
        define_target_download
        execute_stop_syno
        execute_prepare
        execute_backup
        execute_extract_bin
        execute_install_bin
        execute_update_log
        execute_start_syno
        ;;
    restore )
        TOTAL_STEPS=5
        detect_current_versions
        define_restore
        execute_stop_syno
        execute_extract_backup
        execute_restore_bin
        execute_restore_log
        execute_start_syno
        ;;
    update )
        TOTAL_STEPS=10
        detect_current_versions
        define_target_version
        define_update
        execute_stop_syno
        execute_prepare
        execute_backup
        execute_download_bin
        execute_extract_bin
        execute_download_compose
        execute_install_bin
        execute_update_log
        execute_start_syno
        execute_clean
        ;;
    * )
        usage
        terminate "No command specified"
esac

echo "Done."
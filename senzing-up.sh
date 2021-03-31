#!/usr/bin/env bash

# Turn on pipefail. Check rc of commands piping output to other commands, e.g. the tar command to find project name
set -o pipefail

SCRIPT_VERSION=1.3

# Usage / help
USAGE="
Usage:
    $(basename "$0") --project_dir <path> [--action <action> --collection <collection>]

Where:
    -p | --project-dir = Path to new or existing Senzing-Up project directory (Required)
                         Value: Path to create or existing to update
                         Default: None

    -a | --action      = Action to perform (Optional)
                         Values: Create, Package, Deploy 
                         Default: Create

    -c | --collection  = One or more collection of Docker assets can be specified (Optional)
                         Values: ALL, WEBAPPDEMO, REST
                         Default: WEBAPPDEMO

    -o | --output-dir  = Directory to write a packaged project to or deploy a previous packaged project to (Optional)
                         Value: Path to write to
                         Default: Root of --project-dir

Examples:
    $(basename "$0") --help (-h)
        Show extended help

    $(basename "$0") --version (-v)
        Show version

    $(basename "$0") -p ~/senzupProj1
        Create a project in the users home named senzupProj1 with the default WEBAPPDEMO collection

    $(basename "$0") -p ~/senzupProj1 -a CREATE ALL
        Create a project in the users home named senzupProj1, install all docker images for Senzing-Up

"            

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

help() {
    cat <<EOF

Senzing-Up uses Docker assets from the Senzing community to expidite evaluating the Senzing APIs.
By default, Senzing-Up will pull a minimum collection of Docker images to deploy the Senzing Web
App demonstration. Once a Senzing-Up project has been created, additional scripts are available to
pull and install additional Docker images and capabilities. 

Senzing-Up can also be used to package up a working project and deploy the project and associated
Docker images to another machine. This can be useful in air gapped environments. 

Additional information:
    https://github.com/Senzing/senzing-up

${USAGE}

Version: ${SCRIPT_VERSION}

EOF
}


# Given a relative path, find the fully qualified path.
find_realpath() {
    # Directory
    if [ -d "$1" ]; then
        # dir
        (cd "$1"; pwd)
    # File
    elif [ -f "$1" ]; then
        if [[ $1 = /* ]]; then
            echo "$1"
        elif [[ $1 == */* ]]; then
            echo "$(cd "${1%/*}"; pwd)/${1##*/}"
        else
            echo "$(pwd)/$1"
        fi
    # Current path and add basename, catches path being a period for current 
    else
        echo "$PWD/$(basename "$1")"
    fi
}


# Get the list of Docker image names for a collection such as ALL, WEBAPPDEMO, etc
get_image_names() {

    # Unset incase previously used - global array for returning
    unset get_image_names_return

    # Assigned passed in array to be used in the function
    COLLECTIONS=("$@")

    if [[ ! -e ${SENZING_DOCKER_BIN_DIR} ]]; then
        # This is first install and we don't have a full project setup yet
        # Fetch the env script to parse the images that belong to a collections
        SENZING_TMP_ENV=$(curl -X GET ${SENZING_ENVIRONMENT_URL})
    else
        SENZING_TMP_ENV=$(< "${SENZING_PROJECT_DIR_REALPATH}/docker-bin/senzing-environment.py")
    fi


    # Loop through each -c argument from the command line that built the collections array
    # There could be multiple: -c WEBAPPDEMO -c POSTGRES
    for COLLECTION in "${COLLECTIONS[@]}";
    do
        # Extract the block from the env file that lists the images, add the lines returned to array
        # Use tr to remove null bytes from grep -z and prevent warning message
        COLLECTION_ENV_IMAGES=$(grep -oPz "(?s)export DOCKER_IMAGE_NAMES_${COLLECTION}=\(.*?\)" <<< "$SENZING_TMP_ENV" | tr -d '\000')
        get_image_names_return_ARRAY+=(${COLLECTION_ENV_IMAGES})
    done

    
    # Make array unique, if specifying multiple -c args there could be overlapping images to pull
    get_image_names_return_UNIQUE=($(printf "%s\n" "${get_image_names_return_ARRAY[@]}" | sort -u | tr '\n' ' '))
    
    # Replace the double braces used in the env file to make the string usable in bash evaluation for the version details
    get_image_names_return_UNIQUE_FIXED=($(printf "%s\n" "${get_image_names_return_UNIQUE[@]}" | sed -e 's/{{/{/' -e 's/}}/}/'))

    # Collect only entries that are the image version records, i.e. remove the junk, export xxxx (...)
    for DOCKER_IMAGE_NAME in ${get_image_names_return_UNIQUE_FIXED[@]};
    do
        if [[ ${DOCKER_IMAGE_NAME} == *'SENZING_DOCKER_IMAGE_VERSION_'* ]]; then
            # Each image looks like: senzing/init-container:${SENZING_DOCKER_IMAGE_VERSION_INIT_CONTAINER}
            # Evaluate to convert the version variable to string value from docker_versions_latest.py
            get_image_names_return+=($(eval "echo "${DOCKER_IMAGE_NAME}""))
        fi
    done
}


# Pull images
docker_pull() {

    # Assigned passed in array to be used in the function
    IMAGES=("$@")

    printf_tty "\n${SCRIPT_OUTPUT} Checking for and pulling any required Docker images...\n\n"
    
    for IMAGE in ${IMAGES[@]};
    do
        sudo docker pull ${IMAGE}
        printf_tty "..."
    done
}


# Package up a new or existing project for deployment to another system, e.g. air gapped
package() {

    # Check the project to package is a project and looks complete
    if [[    ! -d "${SENZING_PROJECT_DIR_REALPATH}/g2" \
          || ! -d "${SENZING_PROJECT_DIR_REALPATH}/data" \
          || ! -d "${SENZING_PROJECT_DIR_REALPATH}/docker-bin" \
          || ! -d "${SENZING_PROJECT_DIR_REALPATH}/docker-etc" \
          || ! -d "${SENZING_PROJECT_DIR_REALPATH}/.senzing" \
       ]]; then
        printf_tty "\nERROR: Project ${SENZING_PROJECT_NAME} at ${SENZING_PROJECT_DIR_REALPATH} isn't a valid or complete Senzing-Up project!\n"
        exit 1
    fi

    # Source the latest docker assets versions. Any time we are here this should already exist in the project
    source ${SENZING_DOCKER_VERSIONS_LATEST_BIN}

    PACKAGE_OUTPUT_PATH=$([[ ! -z ${OUTPUT_DIR} ]] && echo ${OUTPUT_DIR} || echo ${SCRIPT_DIR})
    PACKAGE_OUTPUT_FILE="SenzingUp-"${SENZING_PROJECT_NAME}"-"$(date -d "today" +"%d%b%Y-%H%M%S")".tgz"

    [[ ! -d ${DOCKER_IMAGES_OUTPUT_PATH} ]] && mkdir -p ${DOCKER_IMAGES_OUTPUT_PATH}

    # Create array of current Docker images on the system
    DOCKER_IMAGES_CURRENT=($(docker images --format "{{.Repository}}:{{.Tag}}" | sort -u | tr '\n' ' '))
    generic_error_check $? "package->docker"

    # What images do we need to pull based on the collections arg
    if [[ -z ${SENZING_UP_COLLECTIONS_SET} ]] && [[ -z ${FIRST_TIME_INSTALL} ]]; then
        printf "\n${SCRIPT_OUTPUT} A collection wasn't specified and project exists, packaging existing project..."
        
        # Build the get_image_names_return array to intersect with the currently installed images
        COLLECTION_ARRAY=(ALL)
        get_image_names ${COLLECTION_ARRAY[@]}

    elif [[ ! -z ${SENZING_UP_COLLECTIONS_SET} ]] && [[ -z ${FIRST_TIME_INSTALL} ]]; then
        printf "\n${SCRIPT_OUTPUT} A collection was specified and project exists, pulling collection set images to ensure have everything to package..."
        get_image_names ${SENZING_UP_COLLECTIONS[@]}
    else
        printf "\n${SCRIPT_OUTPUT} New project creation, already pulled everything for the project..."
        get_image_names ${SENZING_UP_COLLECTIONS[@]}
    fi

    # Get intersect of current images and collection array from get_image_names
    IMAGES_INTERSECT=($(comm -12 <(printf '%s\n' "${get_image_names_return[@]}" | sort) <(printf '%s\n' "${DOCKER_IMAGES_CURRENT[@]}" | sort)))
    
    # If there are no images on the local machine, set the intersect to be the collection that was specified
    if [[ ${#IMAGES_INTERSECT[@]} -eq 0 ]]; then
        IMAGES_INTERSECT=${get_image_names_return[@]}
    fi

    printf_tty "\n${SCRIPT_OUTPUT} Packaging project: ${SENZING_PROJECT_NAME}\n"
    printf_tty "\n${SCRIPT_OUTPUT} The next steps will take many minutes, please be patient!"

    # Pull to ensure have everything we need
    docker_pull ${IMAGES_INTERSECT[@]}

    printf_tty "\n\n${SCRIPT_OUTPUT} Saving Docker images to: ${DOCKER_IMAGES_OUTPUT_PATH}/${DOCKER_IMAGES_OUTPUT_FILE}...\n" 
    sudo docker save ${IMAGES_INTERSECT[@]} --output ${DOCKER_IMAGES_OUTPUT_PATH}"/"${DOCKER_IMAGES_OUTPUT_FILE}

    # Change permissions fo tar to read the docker images
    sudo chown -R $(id -u):$(id -g) ${DOCKER_IMAGES_OUTPUT_PATH}/${DOCKER_IMAGES_OUTPUT_FILE}

    printf_tty "\n${SCRIPT_OUTPUT} Archiving entire project to: ${PACKAGE_OUTPUT_PATH}/${PACKAGE_OUTPUT_FILE}...\n"
    tar czf ${PACKAGE_OUTPUT_PATH}"/"${PACKAGE_OUTPUT_FILE} ${SENZING_PROJECT_DIR} -C ${SCRIPT_DIR} $(basename "$0")

    printf_tty "\n${SCRIPT_OUTPUT} Packaging complete, move ${PACKAGE_OUTPUT_PATH}/${PACKAGE_OUTPUT_FILE} to the target machine"
    printf_tty "\n${SCRIPT_OUTPUT} Run the following commands with the package to deploy on the target machine:\n"
    printf_tty "\n\ttar xvf ${PACKAGE_OUTPUT_FILE} senzing-up.sh"
    printf_tty "\n\t./senzing-up.sh -p <path_to_deploy_to> -a deploy -i ${PACKAGE_OUTPUT_FILE}\n"
}


# Deploy a packaged project
deploy() {

    # Get the project name from the package
    # See comment on return code 141 in generic_error_check()
    PROJ_NAME=$(tar tf ${INPUT_PROJ} | sed -n '1p;1q' | sed s'/\///')
    generic_error_check $? "deploy()->tar tf"

    NEW_PROJ_PATH=${SENZING_PROJECT_DIR_REALPATH}"/"${PROJ_NAME}

    # Don't need the senzing-up.sh script, already have that extracted to deploy from package instructions
    printf_tty "\n${SCRIPT_OUTPUT} Extracting project ${PROJ_NAME} package to: ${SENZING_PROJECT_DIR_REALPATH}..."
    tar xzf ${INPUT_PROJ} -C ${SENZING_PROJECT_DIR_REALPATH} --exclude='senzing-up.sh'
    generic_error_check $? "deploy->tar xzf"

    # Add the docker images
    PATH_TO_IMAGES=${NEW_PROJ_PATH}"/var/docker_save"/${DOCKER_IMAGES_OUTPUT_FILE}
    printf_tty "\n${SCRIPT_OUTPUT} Loading docker images from ${PATH_TO_IMAGES}\n\n"
    sudo docker load --input ${PATH_TO_IMAGES}
    generic_error_check $? "deploy()->docker load"

    # Correct docker-environment-vars
    DEPLOY_ENV_VARS=${NEW_PROJ_PATH}"/docker-bin/docker-environment-vars.sh"

    # Attempt to work out ip address
    IP=$(get_ip_addr)

    printf_tty "\n${SCRIPT_OUTPUT} Correcting docker-environment-vars.sh for deployed project..."
    # Use ! as delimiter, vars have / in 
    sed -i \
        -e "s!export SENZING_PROJECT_DIR=.*!export SENZING_PROJECT_DIR=${NEW_PROJ_PATH}!" \
        -e "s!export SENZING_DOCKER_HOST_IP_ADDR=.*!export SENZING_DOCKER_HOST_IP_ADDR=${IP}!" \
        ${DEPLOY_ENV_VARS}

    printf_tty "\n\n${SCRIPT_OUTPUT} IP address was detected and modified to ${IP} in docker-environment-vars.sh"
    printf_tty "\n${SCRIPT_OUTPUT} The IP address detected could be incorrect! Please check and modify /docker-bin/docker-environment-vars.sh if incorrect"
    printf_tty "\n\t${SCRIPT_OUTPUT} Correct the line that reads: export SENZING_DOCKER_HOST_IP_ADDR=\n\n"

    # Once deployed set project path to new deployment to start web app demo
    source ${NEW_PROJ_PATH}"/docker-bin/docker-environment-vars.sh"
    SENZING_PROJECT_DIR_REALPATH=${SENZING_PROJECT_DIR}

    printf_tty "\n${SCRIPT_OUTPUT} Would you like to start the Senzing Web App Demo now?  [Y/n]"
    input_start_webapp_demo

    # Append temp deploying logging to real project logging file
    cat ${SENZING_HISTORY_FILE} >> ${SENZING_PROJECT_DIR_REALPATH}"/.senzing/history.log"
    rm -rf ${SENZING_HISTORY_FILE}
}


# Check to start demo
input_start_webapp_demo() {

    read -r START
    case "${START:=Y}" in
        [Yy]* ) start_webapp_demo;;
        * ) exit 0;;
    esac

}
# Run web-app Docker container
start_webapp_demo() {
    printf_tty "\n\n${SCRIPT_OUTPUT} Starting Senzing Web App demo...\n\n"
    if [[ -z ${LOG_TO_TERMINAL} ]]; then
        ${SENZING_PROJECT_DIR_REALPATH}/docker-bin/senzing-webapp-demo.sh init | tee ${TERMINAL_TTY}
    else
        ${SENZING_PROJECT_DIR_REALPATH}/docker-bin/senzing-webapp-demo.sh init
    fi
    
    printf_tty "${SCRIPT_OUTPUT} Senzing Up project location: ${SENZING_PROJECT_DIR_REALPATH}"
    printf_tty "\n${SCRIPT_OUTPUT}"
    printf_tty "\n${SCRIPT_OUTPUT} To stop docker formation, run:"
    printf_tty "\n${SCRIPT_OUTPUT}     ${SENZING_PROJECT_DIR_REALPATH}/docker-bin/senzing-webapp-demo.sh down"
    printf_tty "\n${SCRIPT_OUTPUT}"
    printf_tty "\n${SCRIPT_OUTPUT} To restart docker formation, run:"
    printf_tty "\n${SCRIPT_OUTPUT}     ${SENZING_PROJECT_DIR_REALPATH}/docker-bin/senzing-webapp-demo.sh up"
    printf_tty "\n${SCRIPT_OUTPUT}"
    printf_tty "\n${SCRIPT_OUTPUT} For more information:"
    printf_tty "\n${SCRIPT_OUTPUT}     https://senzing.github.io/senzing-up"
    printf_tty "\n${SCRIPT_OUTPUT}"
    printf_tty "\n\n${SCRIPT_OUTPUT} Completed at: $(date)\n"
}


# It's not easy to get primary IP address across platforms, try a few ways
get_ip_addr() {

    IP_TRY=$(ip route get 1 2>/dev/null | awk '{print $(NF-2);exit}' 2>/dev/null)

    if [[ -z ${IP_TRY} ]]; then
        IP_TRY=$(ifconfig 2>/dev/null | grep "inet " | grep -Fv 127.0.0.1 | awk '{print $2}')
    fi

    if [[ -z ${IP_TRY} ]]; then
        IP_TRY=$(hostname -I  2>/dev/null)
    fi

    if [[ -z ${IP_TRY} ]]; then
        IP_TRY="<UNKNOWN>"
    fi

    echo ${IP_TRY}
}


# Generic error checker for bash commands, $1 is exit code to check from a command
generic_error_check() {

    # Check for rc = 141 and ignore it. This happens on tar tf and piping to other commands to efficiently extract the first line
    # to get the project name to use when deploying. 141 is returned becuase head, sed, awk etc close the pipe.

    if [[ $1 != "0" && $1 != "141" ]]; then
        printf_tty "\nERROR: Generic error, unable to continue! If the error details are not visable above check the logfile:"
        printf_tty "\n       ${SENZING_HISTORY_FILE}"
        printf_tty "\n       Exit code: $1\n"
        if [[ ! -z $2 ]]; then
            printf_tty "       Error location: $2"
        fi
        printf_tty "\n"
        exit 1
    fi
}

####
# Can't use ${var^^} for uppercase, Apple purging more GPL and reverted to bash V3. Thanks Apple!
upper_case() {
    echo $1 | tr "[:lower:]" "[:upper:]"
}


# Check if non-verbose was set, if so print to both file (normal) and to screen
printf_tty() {

    # Verbose logging in terminal wasn't requested, still print normally (redirected to file) and also to tty
    if [[ -z ${LOG_TO_TERMINAL} ]]; then
        printf "${1}" | tee ${TERMINAL_TTY}
    else
        # Otherwise print it for normal redirect based on LOG_TO_TERMINAL
        printf "${1}"
    fi
}


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# Parse positional input parameters and uppercase any
while [[ ${1} != "" ]]; do
    case ${1} in
        -h | --help )
            help
            exit 0
        ;;
        -v | --version )
            printf "\nVersion: %s\n" $SCRIPT_VERSION
            exit 0
        ;;
        -p | --project-dir )
            shift
            SENZING_PROJECT_DIR=$1
        ;;
        -a | --action )
            shift
            ####SENZING_UP_ACTION=${1^^}
            SENZING_UP_ACTION=$(upper_case $1)
        ;;
        -c | --collection )
            shift
            ####SENZING_UP_COLLECTIONS+=${1^^}" "
            SENZING_UP_COLLECTIONS+=$(upper_case $1)" "
            SENZING_UP_COLLECTIONS_SET=1
        ;;
        -o | --output-dir )
            shift
            OUTPUT_DIR=$1
        ;;
        -i | --input-project )
            shift
            INPUT_PROJ=$1
        ;;
        * )
            printf "\nERROR: Unrecognised command line argument(s): %s" $1
            printf "\n${USAGE}"
            exit 1
    esac
    shift
done

if [[ -z ${SENZING_PROJECT_DIR} ]]; then
    printf "\nERROR: Missing project directory, please specify --project-dir (-p)\n%s"
    printf "\n${USAGE}"
    exit 1
fi

if [[ ! -z ${SENZING_UP_ACTION} ]]; then
    case ${SENZING_UP_ACTION} in
        CREATE | PACKAGE | DEPLOY );;
        * )
            printf "\nERROR: Valid action values are create, package or deploy"
            printf "\n${USAGE}"
            exit 1
    esac
else
    SENZING_UP_ACTION="CREATE"
fi

if [[ ! -z ${SENZING_UP_COLLECTIONS} ]]; then
    for COLLECTION in ${SENZING_UP_COLLECTIONS[@]};
    do
        case ${COLLECTION} in
            #### Make dynamic
            ALL | WEBAPPDEMO | REST );;
            #### | DEBUG | DB2 | POSTGRESQL | POSTGRESQLCLIENT | RABBITMQ | SQLITEWEB | DB2DRVIER | \
            #### ENTITYSEARCHWEBAPP | G2LOADER | JUPYTER | PHPPGADMIN | SENZINGCONSOLE | SSHD | STREAMLOADER | STREAMPRODUCER | \
            #### XTERM | SWAGGER
            * )
                printf "\nERROR: Valid collection values are All, WEBAPPDEMO"
                printf "\n${USAGE}"
                exit 1
        esac
    done
else
    SENZING_UP_COLLECTIONS="WEBAPPDEMO"
fi

if [[ ! -z ${SENZING_UP_ACTION} && ${SENZING_UP_ACTION} == 'DEPLOY' && -z ${INPUT_PROJ} ]]; then
    printf "\nERROR: A previously created project package must be specified with --input-project (-i)"
    printf "\n${USAGE}"
    exit 1
fi

# Determine operating system running this script.
UNAME_VALUE="$(uname -s)"

case "${UNAME_VALUE}" in
    Linux*)     HOST_MACHINE_OS=Linux;;
    Darwin*)    HOST_MACHINE_OS=Mac;;
    CYGWIN*)    HOST_MACHINE_OS=Cygwin;;
    MINGW*)     HOST_MACHINE_OS=MinGw;;
    *)          HOST_MACHINE_OS="UNKNOWN:${UNAME_VALUE}"
esac

# Verify environment: curl, docker, python3.
if [[ ! -n "$(command -v curl)" ]]; then
    printf "\nERROR: curl is required, see:"
    printf "\n%7s%s\n" "" "https://github.com/Senzing/knowledge-base/blob/master/HOWTO/install-curl.md"
    exit 1
fi

if [[ ! -n "$(command -v docker)" ]]; then
    printf "\nERROR: docker is required, see:"
    printf "\n%7s%s\n" "" "https://github.com/Senzing/knowledge-base/blob/master/HOWTO/install-docker.md"
    exit 1
fi

if [[ ! -n "$(command -v python3)" ]]; then
    printf "\nERROR: python3 is required, see:"
    printf "\n%7s%s\n" "" "See https://github.com/Senzing/knowledge-base/blob/master/HOWTO/install-python-3.md"
    exit 1
fi

# Determine if Docker is running.
if [[ ( ${UNAME_VALUE:0:6} != "CYGWIN" ) ]]; then
    sudo -p "To run Docker, sudo access is required.  Please enter your password:  " docker info >> /dev/null 2>&1
    DOCKER_RETURN_CODE=$?
    if [[ ( "${DOCKER_RETURN_CODE}" != "0" ) ]]; then
        printf "ERROR: Docker is not running, please start it."
        exit 1
    fi
else
    printf "\nTo run sudo docker, you may prompted for your password."
fi

# Configuration via environment variables.
SENZING_ENVIRONMENT_SUBCOMMAND=${SENZING_ENVIRONMENT_SUBCOMMAND:-"add-docker-support-macos"}
TRUTH_SET_1_DATA_SOURCE_NAME=${SENZING_TRUTH_SET_1_DATA_SOURCE_NAME:-"CUSTOMER"}
TRUTH_SET_2_DATA_SOURCE_NAME=${SENZING_TRUTH_SET_2_DATA_SOURCE_NAME:-"WATCHLIST"}

# Synthesize variables.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" > /dev/null 2>&1 && pwd )"
SENZING_PROJECT_DIR_REALPATH=$(find_realpath ${SENZING_PROJECT_DIR})
HORIZONTAL_RULE="=============================================================================="
SCRIPT_OUTPUT=${HORIZONTAL_RULE:0:2}
SENZING_DATA_DIR=${SENZING_PROJECT_DIR_REALPATH}/data
SENZING_DOCKER_BIN_DIR=${SENZING_PROJECT_DIR_REALPATH}/docker-bin
SENZING_ETC_DIR=${SENZING_PROJECT_DIR_REALPATH}/docker-etc
SENZING_G2_DIR=${SENZING_PROJECT_DIR_REALPATH}/g2
SENZING_HISTORY_FILE=${SENZING_PROJECT_DIR_REALPATH}/.senzing/history.log
SENZING_PROJECT_NAME=$(basename "${SENZING_PROJECT_DIR_REALPATH}")
SENZING_VAR_DIR=${SENZING_PROJECT_DIR_REALPATH}/var
TERMINAL_TTY=/dev/tty

#### This needs to change when pushed to master
SENZING_ENVIRONMENT_URL='https://raw.githubusercontent.com/Senzing/senzing-environment/Issue-80.Ant.1/senzing-environment.py'
SENZING_DOCKER_VERSIONS_LATEST_URL='https://raw.githubusercontent.com/Senzing/knowledge-base/master/lists/versions-latest.sh'
SENZING_DOCKER_VERSIONS_LATEST=${SENZING_PROJECT_DIR_REALPATH}/docker_versions_latest.sh
SENZING_DOCKER_VERSIONS_LATEST_BIN=${SENZING_DOCKER_BIN_DIR}/docker_versions_latest.sh
ERROR_EMAIL="Please contact support@senzing.com and attach ${SENZING_HISTORY_FILE}"
DOCKER_IMAGES_OUTPUT_PATH=${SENZING_VAR_DIR}/docker_save
DOCKER_IMAGES_OUTPUT_FILE="DockerImages.tar"
SENZING_PROJECT_NAME_FILE=${SENZING_PROJECT_DIR_REALPATH}"/.senzing/projname---"${SENZING_PROJECT_NAME}
declare -a get_image_names_return

# Create project directory if new project
if [[ ( ! -d ${SENZING_PROJECT_DIR} ) ]]; then
    FIRST_TIME_INSTALL=1
    MKDIR_OUTPUT=$(mkdir -p ${SENZING_PROJECT_DIR}/.senzing 2>&1)
    if [[ $? != "0" ]]; then
        printf "\nERROR: Unable to create the project directory:"
        printf "\n%7s%s\n" "" "${MKDIR_OUTPUT}"
        exit 1
    fi

    # Future use, store the project name for easy reference when moving projects
    touch ${SENZING_PROJECT_NAME_FILE}

# If a project directory does exist, ask if it should be updated.
# Reason: If someone is doing a demo, they shouldn't have to wait for an update.

# Don't update if packaging or deploying
elif [[ ${SENZING_UP_ACTION} != "PACKAGE" && ${SENZING_UP_ACTION} != "DEPLOY" ]]; then
    printf "\n"
    read -p "Existing Senzing-Up project specified, check for and install updates?  [y/N] " UPDATES_RESPONSE
    case ${UPDATES_RESPONSE} in
        [Yy]* ) PERFORM_UPDATES=1;;
        * ) ;;
    esac
##else
##    echo "Shouldn't be here!"
fi

# Accept EULA, presented when new project, updating or deploying
if [[ ! -z ${FIRST_TIME_INSTALL} \
   || ! -z ${PERFORM_UPDATES} \
   && ${SENZING_UP_ACTION} != "PACKAGE"} \
   ]]; then

    printf "\nThe Senzing End User License Agreement (EULA) is located at: https://senzing.com/end-user-license-agreement\n\n"
    read -p "Do you accept the EULA license terms and conditions?  [y/N] " EULA_RESPONSE
    case ${EULA_RESPONSE} in
        [Yy]* ) SENZING_ACCEPT_EULA=I_ACCEPT_THE_SENZING_EULA;;
        * )
            printf "\nSenzing EULA not accepted. Must enter 'Y' to accept EULA and install Senzing APIs.\n"
            exit 1;;
    esac
fi

# Configure log visibility.
printf "\n"
read -p "Show verbose logging in this terminal?  [y/N] " LOG_RESPONSE
case ${LOG_RESPONSE} in
    [Yy]* ) LOG_TO_TERMINAL=1;;
    * ) ;;
esac

# All logging will go to log file, also want to see on terminal?
# Some output should always go to terminal using printf_tty function
if [[ ( ! -z ${LOG_TO_TERMINAL} ) ]]; then
    # Tee output to file and screen
    # Temporary logging for deploying
    if [[ ${SENZING_UP_ACTION} == "DEPLOY" ]]; then
        SENZING_HISTORY_FILE=${SENZING_PROJECT_DIR_REALPATH}"/history.log"
    fi
    exec &> >(tee -i -a ${SENZING_HISTORY_FILE})
else
    printf "${SCRIPT_OUTPUT} To monitor the log, run the following in another terminal:\n\ttail -f ${SENZING_HISTORY_FILE}\n"
    # Send output to file
    exec >> ${SENZING_HISTORY_FILE} 2>&1
fi

# Log useful info for debug and support
printf "\n%s" ${HORIZONTAL_RULE}
printf "\n%s Project path: %s" ${SCRIPT_OUTPUT} ${SENZING_PROJECT_DIR_REALPATH}
printf "\n%s Action: %s" ${SCRIPT_OUTPUT} ${SENZING_UP_ACTION}
printf "\n%s Collection(s): %s" ${SCRIPT_OUTPUT} "${SENZING_UP_COLLECTIONS[@]}"
printf "\n%s Start time: %s" ${SCRIPT_OUTPUT} "$(date)"
printf "\n%s Senzing-Up Version: %s" ${SCRIPT_OUTPUT} ${SCRIPT_VERSION}
printf "\n%s OS running script: %s" ${SCRIPT_OUTPUT} ${HOST_MACHINE_OS} 
printf "\n%s First install: %s" ${SCRIPT_OUTPUT} "$([[ -z ${FIRST_TIME_INSTALL} ]] && echo 'False' || echo 'True')"
printf "\n%s Perform updates: %s" ${SCRIPT_OUTPUT} "$([[ -z ${PERFORM_UPDATES} ]] && echo 'False' || echo 'True')"
printf "\n%s\n" ${HORIZONTAL_RULE}

# Action == package? 
if [[ ${SENZING_UP_ACTION} == "PACKAGE" ]]; then
    if [[ -z ${FIRST_TIME_INSTALL} ]]; then
        printf "\n%s Packaging and project dir already exists..." ${SCRIPT_OUTPUT}
        package
        # When the project already exists assumed to have be tested previously, we can exit
        exit 0
    # If the project dir doesn't exist, create project locally first and then package it up at end
    else
        printf "\n%s Project doesn't exist, creating first and then packaging...\n" ${SCRIPT_OUTPUT}
        PACKAGE_CREATE_PROJ_FIRST=1
    fi
fi

# Action == deploy?
if [[ ${SENZING_UP_ACTION} == "DEPLOY" ]]; then
    deploy
    exit 0
fi

# Fetch the latest pinned information for versions
printf "\n${SCRIPT_OUTPUT} Fetching latest Senzing Docker assets version information...\n"

curl -X GET \
    --fail \
    --silent \
    --show-error \
    --output ${SENZING_DOCKER_VERSIONS_LATEST} \
    ${SENZING_DOCKER_VERSIONS_LATEST_URL} 

# Issues fetching the latest versions info
if [[ $? != "0" ]]; then
    printf_tty "\nWARNING: Unable to fetch latest version details for Docker assets from:"
    printf_tty "           ${SENZING_DOCKER_VERSIONS_LATEST_URL}\n"
    if [[ -f ${SENZING_DOCKER_VERSIONS_LATEST_URL} ]]; then
        printf_tty "           Existing Docker assets versions file detected. Using for this run:"
        printf_tty "           ${SENZING_DOCKER_VERSIONS_LATEST}\n"
    else
        printf_tty "           Can't continue! No existing Docker assets versions file detected in:"
        printf_tty "           ${SENZING_DOCKER_BIN_DIR}\n"
        printf_tty "${ERROR_EMAIL}"
        exit 1
    fi

    echo ${ERROR_EMAIL}
else
    chmod +x ${SENZING_DOCKER_VERSIONS_LATEST}
fi

source ${SENZING_DOCKER_VERSIONS_LATEST}


# If first time or update, pull docker images
if [[ ( ! -z ${FIRST_TIME_INSTALL} ) \
   || ( ! -z ${PERFORM_UPDATES} ) \
   ]]; then
    # Build the get_image_names_return array to intersect with the currently installed images
    get_image_names ${SENZING_UP_COLLECTIONS[@]}
    docker_pull ${get_image_names_return[@]}
fi

# If new project or update requested, install/update Senzing
if [[ ! -e ${SENZING_G2_DIR}/g2BuildVersion.json \
   || ! -e ${SENZING_DATA_DIR}/terms.ibm \
   || ! -z ${PERFORM_UPDATES} \
   ]]; then

    if [[ ! -z ${PERFORM_UPDATES} ]]; then
        printf "\n${SCRIPT_OUTPUT} Performing updates..."
        printf_tty "\n${SCRIPT_OUTPUT} Determining if a new version of Senzing exists..."
    fi

    # Determine version of senzingapi on public repository.
    sudo docker run \
      --privileged \
      --rm \
      senzing/yum:${SENZING_DOCKER_IMAGE_VERSION_YUM} list senzingapi > ${SENZING_PROJECT_DIR}/yum-list-senzingapi.txt

    SENZING_G2_CURRENT_VERSION=$(grep senzingapi ${SENZING_PROJECT_DIR}/yum-list-senzingapi.txt | awk '{print $2}' | awk -F \- {'print $1'})
    SENZING_G2_DIR_CURRENT=${SENZING_G2_DIR}-${SENZING_G2_CURRENT_VERSION}
    rm ${SENZING_PROJECT_DIR}/yum-list-senzingapi.txt

    # Determine version of senzingdata on public repository.
    sudo docker run \
      --privileged \
      --rm \
      senzing/yum:${SENZING_DOCKER_IMAGE_VERSION_YUM} list senzingdata-v1 > ${SENZING_PROJECT_DIR}/yum-list-senzingdata.txt

    SENZING_DATA_CURRENT_VERSION=$(grep senzingdata ${SENZING_PROJECT_DIR}/yum-list-senzingdata.txt | awk '{print $2}' | awk -F \- {'print $1'})
    SENZING_DATA_DIR_CURRENT=${SENZING_DATA_DIR}-${SENZING_DATA_CURRENT_VERSION}
    rm ${SENZING_PROJECT_DIR}/yum-list-senzingdata.txt

    # If new version available, install it.
    if [[ ( ! -e ${SENZING_G2_DIR_CURRENT} ) ]]; then

        printf_tty "\n\n${SCRIPT_OUTPUT} Installing Senzing API version ${SENZING_G2_CURRENT_VERSION}, depending on network speeds this may take up to 15 minutes...\n\n"

        # If symbolic links exist, move them.
        # If successful, they will be removed later.
        # If unsuccessful, they will be restored.
        TIMESTAMP=$(date +%s)

        if [[ -e ${SENZING_G2_DIR} ]]; then
            mv ${SENZING_G2_DIR} ${SENZING_G2_DIR}-bak-${TIMESTAMP}
        fi

        if [[ -e ${SENZING_DATA_DIR} ]]; then
            mv ${SENZING_DATA_DIR} ${SENZING_DATA_DIR}-bak-${TIMESTAMP}
        fi

        # Download Senzing binaries.
        sudo docker run \
          --env SENZING_ACCEPT_EULA=${SENZING_ACCEPT_EULA} \
          --privileged \
          --rm \
          --volume ${SENZING_PROJECT_DIR_REALPATH}:/opt/senzing \
          senzing/yum:${SENZING_DOCKER_IMAGE_VERSION_YUM}

        # DEBUG: local install.
#        sudo docker run \
#            --privileged \
#            --env SENZING_ACCEPT_EULA=${SENZING_ACCEPT_EULA} \
#            --rm \
#            --volume ${SENZING_PROJECT_DIR_REALPATH}:/opt/senzing \
#            --volume ~/Downloads:/data \
#            senzing/yum:${SENZING_DOCKER_IMAGE_VERSION_YUM} -y localinstall /data/senzingapi-2.0.0-20197.x86_64.rpm /data/senzingdata-v1-1.0.0-19287.x86_64.rpm

        sudo chown -R $(id -u):$(id -g) ${SENZING_PROJECT_DIR_REALPATH}

        # Create symbolic links to versioned directories.
        # Tricky code: Also accounting for a failed/cancelled YUM install.
        pushd ${SENZING_PROJECT_DIR_REALPATH} > /dev/null 2>&1

        # Move "g2" to "g2-M.m.P" directory and make "g2" symlink.
        if [[ -e ${SENZING_G2_DIR} ]]; then
            mv g2 g2-${SENZING_G2_CURRENT_VERSION}
            ln -s g2-${SENZING_G2_CURRENT_VERSION} g2
            rm -rf ${SENZING_G2_DIR}-bak-${TIMESTAMP}
        else
            mv ${SENZING_G2_DIR}-bak-${TIMESTAMP} ${SENZING_G2_DIR}
        fi

        # Move "data" to "data-M.m.P" directory, remove the version subdirectory, make "data" symlink.
        if [[ ( ! -e ${SENZING_DATA_DIR_CURRENT} ) ]]; then
            mv data data-backup
            mv data-backup/1.0.0 data-${SENZING_DATA_CURRENT_VERSION}
            rmdir data-backup
            ln -s data-${SENZING_DATA_CURRENT_VERSION} data
            rm -rf ${SENZING_DATA_DIR}-bak-${TIMESTAMP}
        else
            rm -rf ${SENZING_DATA_DIR}
            mv ${SENZING_DATA_DIR}-bak-${TIMESTAMP} ${SENZING_DATA_DIR}
        fi

        popd > /dev/null 2>&1

    fi
fi

# If needed, populate docker-bin directory.
DOCKER_ENVIRONMENT_VARS_FILENAME=${SENZING_DOCKER_BIN_DIR}/docker-environment-vars.sh

if [[ ( ! -e ${DOCKER_ENVIRONMENT_VARS_FILENAME} ) ]]; then

    # If needed, add senzing-environment.py.
    SENZING_ENVIRONMENT_FILENAME=${SENZING_PROJECT_DIR_REALPATH}/senzing-environment.py

    if [[ ( ! -e ${SENZING_ENVIRONMENT_FILENAME} ) ]]; then

        curl -X GET \
             --fail \
             --silent \
             --show-error \
             --output ${SENZING_ENVIRONMENT_FILENAME} \
             ${SENZING_ENVIRONMENT_URL}

        chmod +x ${SENZING_ENVIRONMENT_FILENAME}

    fi

    # Populate docker-bin and docker-etc directories.
    ${SENZING_ENVIRONMENT_FILENAME} ${SENZING_ENVIRONMENT_SUBCOMMAND} --project-dir ${SENZING_PROJECT_DIR}

    # Create private network.
    sudo docker network create senzing-up
    echo "export SENZING_NETWORK_PARAMETER=\"--net senzing-up\"" >> ${SENZING_PROJECT_DIR}/docker-bin/docker-environment-vars.sh

    if [[ ( ! -d ${SENZING_DOCKER_BIN_DIR} ) ]]; then
        mkdir -p ${SENZING_DOCKER_BIN_DIR}
    fi

    mv ${SENZING_ENVIRONMENT_FILENAME} ${SENZING_DOCKER_BIN_DIR}

fi

# If needed, initialize etc and var directories.
if [[ ! -e ${SENZING_ETC_DIR} ]]; then

    printf_tty "\n${SCRIPT_OUTPUT} Creating ${SENZING_ETC_DIR} and initializing Senzing configuration...\n\n"

    sudo docker run \
        --privileged \
        --rm \
        --user 0 \
        --volume ${SENZING_DATA_DIR}:/opt/senzing/data \
        --volume ${SENZING_ETC_DIR}:/etc/opt/senzing \
        --volume ${SENZING_G2_DIR}:/opt/senzing/g2 \
        --volume ${SENZING_VAR_DIR}:/var/opt/senzing \
        senzing/init-container:${SENZING_DOCKER_IMAGE_VERSION_INIT_CONTAINER}

    sudo chown -R $(id -u):$(id -g) ${SENZING_PROJECT_DIR_REALPATH}

fi

# If requested, update Senzing database schema and configuration.
if [[ ! -z ${PERFORM_UPDATES} ]]; then

    printf_tty "\n${SCRIPT_OUTPUT} Updating Senzing database schema..."

    sudo docker run \
        --privileged \
        --rm \
        --user $(id -u):$(id -g) \
        --volume ${SENZING_DATA_DIR}:/opt/senzing/data \
        --volume ${SENZING_ETC_DIR}:/etc/opt/senzing \
        --volume ${SENZING_G2_DIR}:/opt/senzing/g2 \
        --volume ${SENZING_VAR_DIR}:/var/opt/senzing \
        senzing/senzing-debug:${SENZING_DOCKER_IMAGE_VERSION_SENZING_DEBUG} \
            /opt/senzing/g2/bin/g2dbupgrade \
                -c /etc/opt/senzing/G2Module.ini \
                -a

    printf_tty "\n${SCRIPT_OUTPUT} Updating Senzing configuration..."

    # Remove obsolete GTC files.
    sudo rm --force ${SENZING_G2_DIR}/resources/config/g2core-config-upgrade-1.9-to-1.10.gtc

    # Apply all G2C files in alphabetical order.
    for FULL_PATHNAME in ${SENZING_G2_DIR}/resources/config/*; do
        FILENAME=$(basename ${FULL_PATHNAME})

        printf "\n${SCRIPT_OUTPUT} Verifying ${FILENAME}..."

        sudo docker run \
            --privileged \
            --rm \
            --user $(id -u):$(id -g) \
            --volume ${SENZING_DATA_DIR}:/opt/senzing/data \
            --volume ${SENZING_ETC_DIR}:/etc/opt/senzing \
            --volume ${SENZING_G2_DIR}:/opt/senzing/g2 \
            --volume ${SENZING_VAR_DIR}:/var/opt/senzing \
            senzing/senzing-debug:${SENZING_DOCKER_IMAGE_VERSION_SENZING_DEBUG} \
                /opt/senzing/g2/python/G2ConfigTool.py \
                    -c /etc/opt/senzing/G2Module.ini \
                    -f /opt/senzing/g2/resources/config/${FILENAME}

        RETURN_CODE=$?

        printf "\n${SCRIPT_OUTPUT} Return code: ${RETURN_CODE}"
    done

fi

# Load Senzing with truthset sample data
if [[ ( ! -z ${FIRST_TIME_INSTALL} ) ]]; then
    printf_tty "\n${SCRIPT_OUTPUT} Loading sample truth set data...\n"

    # Create file:  truthset-project.csv
    cat <<EOT > ${SENZING_VAR_DIR}/truthset-project.csv
DATA_SOURCE,FILE_FORMAT,FILE_NAME
${TRUTH_SET_1_DATA_SOURCE_NAME},CSV,/opt/senzing/g2/python/demo/truth/truthset-person-v1-set1-data.csv
${TRUTH_SET_2_DATA_SOURCE_NAME},CSV,/opt/senzing/g2/python/demo/truth/truthset-person-v1-set2-data.csv
EOT

    # Invoke G2Loader.py via Docker container to load files into Senzing
    sudo docker run \
        --privileged \
        --rm \
        --user $(id -u):$(id -g) \
        --volume ${SENZING_DATA_DIR}:/opt/senzing/data \
        --volume ${SENZING_ETC_DIR}:/etc/opt/senzing \
        --volume ${SENZING_G2_DIR}:/opt/senzing/g2 \
        --volume ${SENZING_VAR_DIR}:/var/opt/senzing \
        senzing/g2loader:${SENZING_DOCKER_IMAGE_VERSION_G2LOADER} \
            -p /var/opt/senzing/truthset-project.csv
fi


# Move docker_versions_latest.sh in to docker-bin, do after all other actions
mv ${SENZING_DOCKER_VERSIONS_LATEST} ${SENZING_DOCKER_BIN_DIR} > /dev/null 2>&1

# Print prolog.
if [[ ( ! -z ${FIRST_TIME_INSTALL} ) ]]; then
    printf_tty "\n${SCRIPT_OUTPUT} Senzing-Up installation completed at: $(date)"
elif [[ ( ! -z ${PERFORM_UPDATES} ) ]]; then
    printf_tty "\n${SCRIPT_OUTPUT} Senzing-Up update completed at: $(date)"
fi

# If first time install and packaging, test locally before deploying elsewhere?
if [[ ! -z ${PACKAGE_CREATE_PROJ_FIRST} ]]; then
    printf_tty "\n\n${SCRIPT_OUTPUT} Project created, packaging up...\n"
    package
    printf_tty "\n${SCRIPT_OUTPUT} Would you like to start the Senzing Web App Demo to test locally on this system?  [Y/n] "
    input_start_webapp_demo
fi

start_webapp_demo

exit 0
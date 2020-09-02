#!/usr/bin/env sh
#
# Ping Identity DevOps - Docker Build Hooks
#
#- This script is started in the background immediately before 
#- the server within the container is started
#-
#- This is useful to implement any logic that needs to occur after the
#- server is up and running
#-
#- For example, enabling replication in PingDirectory, initializing Sync 
#- Pipes in PingDataSync or issuing admin API calls to PingFederate or PingAccess

# shellcheck source=../../../../pingcommon/opt/staging/hooks/pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"

_out=/tmp/pa.api.request.out

_pa_curl ()
{
     _curl \
        --insecure \
        --user "${ROOT_USER}:${PING_IDENTITY_PASSWORD}" \
        --header "X-Xsrf-Header: PingAccess" \
        --output ${_out} \
        "${@}"
    return ${?}
}

pahost=${PA_CONSOLE_HOST}
if test -n "${OPERATIONAL_MODE}" && test "${OPERATIONAL_MODE}" = "CLUSTERED_CONSOLE_REPLICA"
then
    echo "This node is a console replica"
    while true
    do
        _pa_curl https://${pahost}:${PA_ADMIN_PORT}/pa/heartbeat.ping
        if test $? -ne 0 ; 
        then
            echo "Adding Console Replica: Server not started, waiting.."
            sleep 3
        else
            echo "PA started, begin adding console replica"
            break
        fi
    done

    _pa_curl \
        https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/users/1 \
        2>/dev/null \
    || die_on_error 51 "Connection to admin unsuccessful, check vars PING_IDENTITY_PASSWORD and PA_CONSOLE_HOST"

    # Get Engine Certificate ID
    echo "Retrieving Key Pair ID from administration API..."
    _pa_curl https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/httpsListeners
    test ${?} -ne 200 && die_on_error 51 "Could not retrieve key-pair ID"
    keypairid=$( jq '.items[] | select(.name=="CONFIG QUERY") | .keyPairId' "${_out}" )
    echo "KeyPairId:"${keypairid}

    echo "Retrieving the Key Pair alias..."
    _pa_curl https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/keyPairs
    test ${?} -ne 200 && die_on_error 51 "Could not retrieve key-pair alias"
    kpalias=$( jq '.items[] | select(.id=='${keypairid}') | .alias' "${_out}" )
    echo "Key Pair Alias:"${kpalias}

    echo "Retrieving Certificate ID..."
    _pa_curl  https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/engines/certificates
    test ${?} -ne 200 && die_on_error 51 "Could not retrieve certificate ID"
    certid=$( jq '.items[] | select(.alias=='${kpalias}' and .keyPair==true) | .id' "${_out}" )
    echo "Engine Cert ID:"${certid}

    echo "Adding new console"
    curl \
        --insecure \
        --request POST \
        --user "${ROOT_USER}:${PING_IDENTITY_PASSWORD}" \
        --header "X-Xsrf-Header: PingAccess" \
        --data '{"name":"'"replica1"'", "hostPort": "'"${PA_CONSOLE_REPLICA_HOST}:${PA_ADMIN_PORT}"'", "selectedCertificateId": "'"${certid}"'"}' \
        https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/adminConfig/replicaAdmins

    echo "Retrieving the replcia admin config..."
    curl \
        --insecure \
        --request POST \
        --user "${ROOT_USER}:${PING_IDENTITY_PASSWORD}" \
        --header "X-Xsrf-Header: PingAccess" \
        --output /tmp/admin-config.zip \
        https://${pahost}:${PA_ADMIN_PORT}/pa-admin-api/v3/adminConfig/replicaAdmins/1/config

    echo "Extracting bootstrap and pa.jwk files to conf folder..."
    unzip -o /tmp/admin-config.zip -d "${OUT_DIR}/instance"
    # ls -la ${OUT_DIR}instance/conf
    # cat ${OUT_DIR}/instance/conf/bootstrap.properties
    chmod 400 "${OUT_DIR}/instance/conf/pa.jwk"

    echo "Cleanup zip.."
    rm /tmp/admin-config.zip
fi

#!/usr/bin/with-contenv bashio
# ==============================================================================
# Home Assistant Add-on: Cloudflared
#
# Creates a Cloudflared tunnel to a given Cloudflare Teams project and creates
# the needed DNS entry under the given hostname
# ==============================================================================

# ------------------------------------------------------------------------------
# Delete all Cloudflared config files
# ------------------------------------------------------------------------------
resetCloudflareFiles() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.warning "Deleting all existing Cloudflared config files..."

    if bashio::fs.file_exists "/data/cert.pem" ; then
        bashio::log.debug "Deleting certificate file"
        rm -f /data/cert.pem || bashio::exit.nok "Failed to delete certificate file"
    fi

    if bashio::fs.file_exists "/data/tunnel.json" ; then
        bashio::log.debug "Deleting tunnel file"
        rm -f /data/tunnel.json || bashio::exit.nok "Failed to delete tunnel file"
    fi

    if bashio::fs.file_exists "/data/config.yml" ; then
        bashio::log.debug "Deleting config file"
        rm -f /data/config.yml || bashio::exit.nok "Failed to delete config file"
    fi

    if bashio::fs.file_exists "/data/cert.pem" \
        || bashio::fs.file_exists "/data/tunnel.json" \
        || bashio::fs.file_exists "/data/config.yml";
    then
        bashio::exit.nok "Failed to delete cloudflared files"
    fi

    bashio::log.info "Succesfully deleted cloudflared files"

    bashio::log.debug "Removing 'reset_cloudflared_files' option from add-on config"
    bashio::addon.option 'reset_database'
}

# ------------------------------------------------------------------------------
# Check if Cloudflared certificate (authorization) is available
# ------------------------------------------------------------------------------
hasCertificate() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Checking for existing certificate..."
    if bashio::fs.file_exists "/data/cert.pem" ; then
        bashio::log.info "Existing certificate found"
        return "${__BASHIO_EXIT_OK}"
    fi

    bashio::log.notice "No certificate found"
    return "${__BASHIO_EXIT_NOK}"
}

# ------------------------------------------------------------------------------
# Create cloudflare certificate
# ------------------------------------------------------------------------------
createCertificate() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Creating new certificate..."
    bashio::log.notice "Please follow the Cloudflare Auth-Steps:"
    /opt/cloudflared tunnel login

    bashio::log.green "Authentication successfull, moving auth file to config folder"

    mv /root/.cloudflared/cert.pem /data/cert.pem || bashio::exit.nok "Failed to move auth file"

    hasCertificate || bashio::exit.nok "Failed to create certificate"
}

# ------------------------------------------------------------------------------
# Check if Cloudflared tunnel is existing
# ------------------------------------------------------------------------------
hasTunnel() {
    bashio::log.trace "${FUNCNAME[0]}:"
    bashio::log.info "Checking for existing tunnel..."

    # Check if tunnel file(s) exist
    if ! bashio::fs.file_exists "/data/tunnel.json" ; then
        bashio::log.notice "No tunnel file found"
        return "${__BASHIO_EXIT_NOK}"
    fi

    # Get tunnel UUID from JSON
    tunnel_uuid="$(bashio::jq "/data/tunnel.json" .TunnelID)"

    bashio::log.info "Existing tunnel with ID ${tunnel_uuid} found"

    # Check if tunnel name in file matches config value
    bashio::log.info "Checking if existing tunnel matches name given in config"
    local tunnel_name_from_file
    tunnel_name_from_file="$(bashio::jq "/data/tunnel.json" .TunnelName)"
    bashio::log.debug "Tunnnel name read from file: $tunnel_name_from_file"
    if [[ $tunnel_name != "$tunnel_name_from_file" ]]; then
        bashio::log.warning "Tunnel name in file does not match config, removing tunnel file"
        rm -f /data/tunnel.json  || bashio::exit.nok "Failed to remove tunnel file"
        return "${__BASHIO_EXIT_NOK}"
    fi
    bashio::log.info "Tunnnel name read from file matches config, proceeding with existing tunnel file"

    return "${__BASHIO_EXIT_OK}"
}

# ------------------------------------------------------------------------------
# Create cloudflare tunnel with name from HA-Add-on-Config
# ------------------------------------------------------------------------------
createTunnel() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Creating new tunnel..."
    /opt/cloudflared --origincert=/data/cert.pem --cred-file=/data/tunnel.json tunnel create "${tunnel_name}" \
    || bashio::exit.nok "Failed to create tunnel.
    Please check the Cloudflare Teams Dashboard for an existing tunnel with the name ${tunnel_name} and delete it:
    https://dash.teams.cloudflare.com/ Access / Tunnels"

    bashio::log.debug "Created new tunnel: $(cat /data/tunnel.json)"

    bashio::log.info "Checking for old config"
    if bashio::fs.file_exists "/data/config.yml" ; then
        rm -f /data/config.yml || bashio::exit.nok "Failed to remove old config"
        bashio::log.notice "Old config found and removed"
    else bashio::log.info "No old config found"
    fi

    hasTunnel || bashio::exit.nok "Failed to create tunnel"
}

# ------------------------------------------------------------------------------
# Create cloudflare config with variables from HA-Add-on-Config and Cloudfalred set-up
# ------------------------------------------------------------------------------
createConfig() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Creating new config file..."
    cat << EOF > /data/config.yml
        url: http://homeassistant:${internal_ha_port}
        tunnel: ${tunnel_uuid}
        credentials-file: /data/tunnel.json
EOF
    bashio::log.debug "Sucessfully created config file: $(cat /data/config.yml)"

    createDNS
}

# ------------------------------------------------------------------------------
# Create cloudflare DNS entry for external hostname
# ------------------------------------------------------------------------------
createDNS() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Creating new DNS entry ${external_hostname}..."
    /opt/cloudflared --origincert=/data/cert.pem tunnel route dns "${tunnel_uuid}" "${external_hostname}" \
    || bashio::exit.nok "Failed to create DNS entry.
    Please check the Cloudflare Dashboard for an existing DNS entry with the name ${external_hostname} and delete it:
    https://dash.cloudflare.com/ Website / DNS"
}

# ==============================================================================
# RUN LOGIC
# ------------------------------------------------------------------------------
external_hostname=""
internal_ha_port=""
tunnel_name=""
tunnel_uuid=""

main() {
    bashio::log.trace "${FUNCNAME[0]}"

    external_hostname="$(bashio::config 'external_hostname')"
    internal_ha_port="$(bashio::config 'internal_ha_port')"
    tunnel_name="$(bashio::config 'tunnel_name')"

    if bashio::config.true 'reset_cloudflared_files' ; then
        resetCloudflareFiles
    fi

    if ! hasCertificate ; then
        createCertificate
    fi

    if ! hasTunnel ; then
        createTunnel
    fi

    createConfig

    bashio::log.info "Finished setting-up the Cloudflare tunnel"
}
main "$@"
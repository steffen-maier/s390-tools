#!/bin/bash
#
# Copyright IBM Corp. 2016, 2017
#
# s390-tools is free software; you can redistribute it and/or modify
# it under the terms of the MIT license. See LICENSE for details.
#
#
# 95zdev/module_setup.sh
#   This module installs configuration files (udev rules and modprobe.conf
#   files) required to enable the root device on s390. It will only work when
#   the root device was configured using the chzdev tool. In addition,
#   a hook is installed to parse rd.zdev= kernel parameters.
#

# called by dracut
check() {
    local _arch
    _arch=$(uname -m)

    # Ensure that we're running on s390
    [ "$_arch" = "s390" ] || [ "$_arch" = "s390x" ] || return 1

    # shellcheck source=/dev/null
    source "${moddir:?}/zdev-lib.sh"

    # Leave kdump device configuration to module zdev-kdump to
    # ensure a minimal device footprint
    zdev_is_kdump && return 1

    # Ensure that required tools are available
    require_binaries chzdev lszdev /lib/s390-tools/zdev_id || return 1
    require_binaries sed || return 1

    return 0
}

# called by dracut
depends() {
    return 0
}

# called by dracut
installkernel() {
    # Add modules for all device types supported by chzdev (required for
    # auto-configuration)
    hostonly="$(optional_hostonly)" \
    instmods ctcm lcs qeth qeth_l2 qeth_l3 dasd_mod dasd_eckd_mod dasd_fba_mod \
	     dasd_diag_mod zfcp
}

# called by dracut
install() {
    local _tempfile

    # Ensure that required tools are available
    inst_multiple chzdev lszdev vmcp /lib/s390-tools/zdev_id

    # Hook to parse zdev kernel parameter
    inst_hook cmdline 95 "$moddir/parse-zdev.sh"

    # Rule to automatically enable devices when running in DPM
    inst_rules "81-dpm.rules"

    # Obtain early + root device configuration

    # If enabled, add the host-specific config of required devices into initrd
    # shellcheck disable=SC2154
    [[ $hostonly ]] || return 0

    _tempfile=$(mktemp --tmpdir dracut-zdev.XXXXXX)
    function check_zdev() {
        local _dev=$1
        local _devsysfs _bdevpath
        _devsysfs=$(
            cd -P /sys/dev/block/"$_dev" && echo "$PWD"
                 )
        _bdevpath=/dev/${_devsysfs##*/}
        chzdev --export - --active --by-node "$_bdevpath" --quiet \
               2>/dev/null >> "$_tempfile"
               #--type # needs a change in chzdev to not have subsequent
                       # import bail out on unknown type properties
    }
    for_each_host_dev_and_slaves_all check_zdev
    sed -i -e 's/^\[active /\[persistent /' "$_tempfile"

    chzdev --export - --persistent --by-attrib "zdev:early=1" --quiet \
	   --type 2>/dev/null >> "$_tempfile"

    # Obtain early device configuration for site-specific settings
    for (( site=0; site<10; site++ ))
    do
    chzdev --export - --persistent --by-attrib "zdev:early=1" --site $site \
           --quiet 2>/dev/null >> "$_tempfile"
    done

    ddebug < "$_tempfile"

    # Apply via --import to prevent other devices from being configured
    chzdev --import "$_tempfile" --persistent --base "/etc=${initdir:?}/etc" \
           --yes --no-root-update --force 2>&1 | ddebug
    # Apply site-specific configurations via --import
    for (( site=0; site<10; site++ ))
    do
    chzdev --import "$_tempfile" --persistent --base "/etc=$initdir/etc" \
           --site $site --yes --no-root-update --force 2>&1 | ddebug
    done

    lszdev --configured --persistent --info \
           --base "/etc=$initdir/etc" 2>&1 | ddebug

    rm -f "$_tempfile"

    # these are purely generated udev rules so we have to glob expand
    # within $initdir and strip the $initdir prefix for mark_hostonly
    local -a _array
    local _nullglob
    _nullglob=$(shopt -p nullglob)
    shopt -u nullglob
    readarray -t _array < \
              <(ls -1 "$initdir"/etc/udev/rules.d/41-*.rules 2> /dev/null)
    [[ ${#_array[@]} -gt 0 ]] && mark_hostonly "${_array[@]#$initdir}"
    readarray -t _array < \
              <(ls -1 "$initdir"/etc/modprobe.d/s390x-*.conf 2> /dev/null)
    [[ ${#_array[@]} -gt 0 ]] && mark_hostonly "${_array[@]#$initdir}"
    $_nullglob

    return 0
}

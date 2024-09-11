#!/bin/bash

# Copyright (c) 2024 Microsoft Corporation
#
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# 1. Setup: start kata-agent as an individual process listening on the default port
# 2. Use a bats script to run all tests
# 3. Collect logs if possible (look into this to validate success/failures)
# 4. handle errors/exit in cleanup to remove all mounts, etc.
# The agent process runs locally as a standalone process for now.

agent_binary="/usr/bin/kata-agent"
agent_ctl_path="/opt/kata/bin/kata-agent-ctl"

# Name of socket file used by a local agent.
agent_socket_file="/tmp/kata-agent.socket"

# Kata Agent socket URI.
local_agent_server_addr="unix://@${agent_socket_file}"

# Log file that contains agent ctl output
ctl_log_file="${PWD}/agent-ctl.log"
# Log file that contains agent output.
agent_log_file="${PWD}/kata-agent.log"

agent_log_level="debug"
keep_logs=false

local_policy_file="/opt/kata/test.rego"
policy_file="/etc/kata-opa/default-policy.rego"

cleanup()
{
	info "cleaning resources..."

	local failure_ret="$?"

	stop_agent

	sudo unlink $policy_file
	sudo rm $local_policy_file
	sudo rm -rf $(dirname ${policy_file})

	local sandbox_dir="/run/sandbox-ns/"
	sudo umount -f "${sandbox_dir}/uts" "${sandbox_dir}/ipc" &>/dev/null || true
	sudo rm -rf "${sandbox_dir}" &>/dev/null || true

	if [ "$failure_ret" -eq 0 ] && [ "$keep_logs" = 'true' ]
	then
		info "SUCCESS: Test passed, but leaving logs:"
		info ""
		info "agent log file       : ${agent_log_file}"
		info "agent-ctl log file   : ${ctl_log_file}"
		return 0
	fi

	if [ $failure_ret -ne 0 ]; then
		warn "ERROR: Test failed"
		warn ""
		warn "Not cleaning up to help debug failure:"
		warn ""

		info "agent-ctl log file   : ${ctl_log_file}"
		info "agent log file       : ${agent_log_file}"
		return 0
	fi

	sudo rm -f \
		"$agent_log_file" \
		"$ctl_log_file"
}

run_agent_ctl()
{
	local cmds="${1:-}"

	[ -n "$cmds" ] || die "need commands for agent control tool"

	local redirect="&>\"${ctl_log_file}\""

	local server_address="--server-address ${local_agent_server_addr}"

	eval \
		sudo \
		RUST_BACKTRACE=full \
		"${agent_ctl_path}" \
		-l debug \
		connect \
		${server_address} \
		${cmds} \
		${redirect}
}

get_agent_pid()
{
	local pids

	local name
	name=$(basename "$agent_binary")

	pids=$(pgrep "$name" || true)
	[ -z "$pids" ] && return 0

	local count
	count=$(echo "$pids"|wc -l)

	[ "$count" -gt 1 ] && \
		die "too many agent processes running ($count, '$pids')"

	echo $pids
}

check_agent_alive()
{
	local cmds=()

	cmds+=("-c Check")

	run_agent_ctl \
		"${cmds[@]}"
}

wait_for_agent_to_start()
{
	local cmd="check_agent_alive"

	local wait_time_secs=20
	local sleep_time_secs=1

	info "Waiting for agent process to start.."

	waitForProcess \
		"$wait_time_secs" \
		"$sleep_time_secs" \
		"$cmd"

	info "Kata agent process running."
}

stop_agent() {
	info "Stopping agent"
	local cmds=()
	cmds+=("-c DestroySandbox")
	run_agent_ctl \
		"${cmds[@]}"
}

start_agent()
{
	local log_file="${1:-}"
	[ -z "$log_file" ] && die "need agent log file"

	local running
	running=$(get_agent_pid || true)

	[ -n "$running" ] && die "agent already running: '$running'"

	eval \
		sudo \
			RUST_BACKTRACE=full \
			KATA_AGENT_LOG_LEVEL=${agent_log_level} \
			KATA_AGENT_SERVER_ADDR=${local_agent_server_addr} \
			${agent_binary} \
			&> ${log_file} \
			&

    wait_for_agent_to_start
}

setup_agent() {
	info "Starting a single kata agent process."

	start_agent $agent_log_file

	info "Setup done."
}

# The setup attempts to start kata-agent as standalone process instead of inside a UVM.
# Hence, the contents of the UVM rootfs is not available here.
# Initing Agent policy with a relaxed `allow-all.rego`
install_policy_doc()
{
	info "Installing local policy document"

	allow_all_rego_file="${repo_root_dir}/src/kata-opa/allow-all.rego"
	[ ! -f $allow_all_rego_file ] && die "Failed to locate allow-all.rego file"

	local policy_dir=$(dirname ${policy_file})
	[ ! -d $policy_dir ] && sudo mkdir -p $policy_dir || true

	sudo cp $allow_all_rego_file $local_policy_file

	[ ! -f $policy_file ] && sudo ln -s $local_policy_file $policy_file || die "Failed to setup local policy file, exists: $policy_file"
}

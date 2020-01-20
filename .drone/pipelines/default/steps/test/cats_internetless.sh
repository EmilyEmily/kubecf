#!/usr/bin/env bash

# This is a variant of cf_acceptance_tests.sh which runs only suite `internetless`.
# As part of that it
# - Reconfigures the deployment (Changing the list of cat suites)
#   - This includes waiting for the deployment jobs to complete
# - Applies a network policy to isolate the system from the internet
# - Runs the CATS
# - Removes the isolation policy.
# - Re-reconfigures the deployment (undo the cat suite selection)

set -o errexit -o nounset

# shellcheck disable=SC1091
source ".drone/pipelines/default/runtime/binaries.sh"
# shellcheck disable=SC1091
source ".drone/pipelines/default/runtime/config.sh"
# shellcheck disable=SC1091
source ".drone/pipelines/default/runtime/cats_common.sh"

# More helpers

isolate_network()
{
    enable="${1:-1}"

    if [[ $enable == 1 ]]; then
	# Complaint wrong. The echo generates a traling newline the `blue` doesn't.
	# shellcheck disable=SC2005
	echo "$(blue "Configure cluster network: Deny egress external")"
	# enable isolation
	# ingress - allows all incoming traffic
	# egress  - allows dns traffic anywhere
	#         - allows traffic to all ports, pods, namespaces
	#           (but no whitelisting of external ips!)
	# references
	# - BASE = https://github.com/ahmetb/kubernetes-network-policy-recipes
	# - (BASE)/blob/master/02a-allow-all-traffic-to-an-application.md
	# - (BASE)/blob/master/14-deny-external-egress-traffic.md
	# - See also https://www.youtube.com/watch?v=3gGpMmYeEO8 (31min)
	#   - Egress info wrt disallow external see 17:20-17:52
	#
	# __ATTENTION__
	# Requires a networking plugin to enforce, else ignored
	# (if not directly supported by platform)
	# - Example plugins: Calico, WeaveNet, Romana
	#
	# GKE: Uses Calico, Use `--enable-network-policy` when
	# creating a cluster (`gcloud`).
	# Minikube needs special setup.
	# KinD used by our Drone setup may have support.

	cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cats-internetless
  namespace: ${KUBECF_NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - {}
  egress:
    - ports:
      - port: 53
        protocol: UDP
      - port: 53
        protocol: TCP
    - to:
      - namespaceSelector: {}
EOF
	# For debugging, show what kube thinks of it.
	kubectl describe networkpolicies \
		--namespace "${KUBECF_NAMESPACE}" \
		cats-internetless
    else
	# shellcheck disable=SC2005
	echo "$(blue "Configure cluster network: Full access")"
	# disable isolation
	kubectl delete networkpolicies \
		--namespace "${KUBECF_NAMESPACE}" \
		cats-internetless
    fi
}

configure_cats_suites() {
    # shellcheck disable=SC2005
    echo "$(blue "Configure CATS: =internetless")"

    # External script. Variant of the script `deploy/kubecf.sh`
    # modified to limit the suites used by the cats to `internetless`
    # alone.
    #
    # External __by choice__. Make it easier in the future to
    # consolidate with the original script and use parameters,
    # templating, whatever to choose mode on call.
    #
    # || true catches that reconfiguration generates errors of the
    # form ``invalid: spec.clusterIP: Invalid value: "": field is immutable``.
    # These errors do not seem to prevent us from running the CATS again.
    # And the redirection hides the output from that.

    { ".drone/pipelines/default/runtime/cats_kubecf.sh" >& /dev/null; } || true
    wait_for_ig_job || exit 1
}

deconfigure_cats_suites() {
    # shellcheck disable=SC2005
    echo "$(blue "Configure CATS: defaults")"

    # Undo the limited configuration of the cats.
    { ".drone/pipelines/default/runtime/decats_kubecf.sh" >& /dev/null; } || true

    # { ".drone/pipelines/default/deploy/kubecf.sh" >& /dev/null; } || true
    wait_for_ig_job || exit 1
}

# - -- --- ----- -------- ------------- ---------------------

# Reconfigure deployment
configure_cats_suites

# Isolate deployment
isolate_network

# Run the cats in the new environment
run_cf_acceptance_tests
exit_code="$(cat EXIT)"

# Unisolate
isolate_network 0

# Reconfigure deployment again
deconfigure_cats_suites

# Signal results, and be done
if [[ "$exit_code" == "0" ]]; then
    # shellcheck disable=SC2005
    echo "$(green OK)"
else
    # shellcheck disable=SC2005
    echo "$(red "FAILED")"
fi
# ... and exit the script with the container's exit code.
exit "${exit_code}"

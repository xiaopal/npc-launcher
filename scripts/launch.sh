#!/usr/bin/dumb-init /bin/bash

INFRA_CONFD=/infrastructure
INFRA_CONF=/infrastructure.conf

do_comb_sync(){
	[ -d $INFRA_CONFD ] && {
		for NAMESPACE_CONF in $(find $INFRA_CONFD -maxdepth 1 -type f -name '*.conf'); do
			echo 'namespace "'"$(basename "${NAMESPACE_CONF%.*}")"'" {'
			cat $NAMESPACE_CONF
			echo
			echo '}'
		done
	} > $INFRA_CONF

	[ -f $INFRA_CONF ] && /comb-sync.sh $INFRA_CONF || echo 'Nothing to sync'
}

comb_sync(){
	do_comb_sync
}

[ ! -z "$GIT_URL" ] && { 
	[ ! -f ~/.ssh/id_rsa ] && {
		cat /dev/zero | ssh-keygen -q -N ""
	}

	( 
		echo 'StrictHostKeyChecking no' 
		echo 'UserKnownHostsFile /dev/null'
	) > ~/.ssh/config 

	[ -d /.ssh ] && [ -f /.ssh/id_rsa ] && {
		echo 'Override ssh keys...'
		cat /.ssh/id_rsa > ~/.ssh/id_rsa
		[ -f /.ssh/id_rsa.pub ] && cat /.ssh/id_rsa.pub > ~/.ssh/id_rsa.pub
	}

	[ -f ~/.ssh/id_rsa.pub ] && {
		echo ' '
		echo '===SSH PUBLIC KEY==='
		cat ~/.ssh/id_rsa.pub
		echo '===================='
		echo ' '
	}

	comb_sync(){
		INFRA_GREPO="${INFRA_CONF%.*}.g"
		INFRA_GLOCK="${INFRA_CONF%.*}.glock"
		INFRA_CONFD="${INFRA_GREPO}/${GIT_PATH#/}"
		(
			flock 100 || exit 0;
			[ ! -d $INFRA_GREPO ] && git clone $GIT_URL --branch ${GIT_BRANCH:-master} --single-branch $INFRA_GREPO
			( cd $INFRA_GREPO && git pull )
		) 100>>$INFRA_GLOCK

		( [ -f $INFRA_CONFD/comb.api ] || [ -f $INFRA_CONFD/.comb.api ] ) && {
			export COMB_API_JSON="${INFRA_CONF%.*}.api" COMB_API_TOKEN="${INFRA_CONF%.*}.api.token"
			[ -f $INFRA_CONFD/.comb.api ] && cat $INFRA_CONFD/.comb.api > $COMB_API_JSON
			[ -f $INFRA_CONFD/comb.api ] && cat $INFRA_CONFD/comb.api > $COMB_API_JSON
		}
		do_comb_sync
	}

	while true; do 
		nc -l -p ${GIT_WEBHOOK_PORT:-9000} -e /webhook.sh && { 
			sleep 2s && comb_sync &
		}
	done &
}

[ ! -z "$CONSUL_AGENT" ] && { 
	consul agent $CONSUL_AGENT &
	CONSUL_PID=$!
	
	while kill -0 $CONSUL_PID &>/dev/null; do
		CONSUL_LEADER="$(curl -sf "http://${CONSUL_ENDPOINT:-127.0.0.1:8500}/v1/status/leader")"
		[ ! -z "$CONSUL_LEADER" ] && [ "$CONSUL_LEADER" != '""' ] && break
		echo 'Wait for Consul agent' && sleep 1s
	done
    kill -0 $CONSUL_PID &>/dev/null || echo 'Consul Agent exited!' >&2
}

trap 'cleanup EXIT' EXIT
trap 'cleanup INT'  INT
trap 'cleanup TERM' TERM
cleanup() {
	[ ! -z "$1" ] && echo "Caught $1 signal! Shutting down..." || echo "Shutting down..."
	trap - EXIT INT TERM
	exit 0
}

COMB_SYNC_INTERVAL=${COMB_SYNC_INTERVAL:-1m}
while true; do 
	comb_sync
	[ "$COMB_SYNC_INTERVAL" = "once" ] && break
	sleep $COMB_SYNC_INTERVAL
done

cleanup

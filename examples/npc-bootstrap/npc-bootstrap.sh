#!/usr/bin/dumb-init /bin/sh

if [ ! -z "$SERF_EVENT" ]; then
	bootstrap(){
		local FIRE_EVENT="$1" 
		export ADDRESSES="$(jq -c 'arrays|select(length >= (env.NPC_BOOTSTRAP_EXPECT|tonumber))')"
		[ ! -z "$ADDRESSES" ] && [ ! -f $NPC_BOOTSTRAP_SERVERS ] \
			&& ( exec 200>$NPC_BOOTSTRAP_SERVERS.lock && flock 200 \
				&& [ ! -f $NPC_BOOTSTRAP_SERVERS ] \
				&& jq -nr 'env.ADDRESSES|fromjson|.[]' >$NPC_BOOTSTRAP_SERVERS ) \
			&& {
				[ ! -z "$FIRE_EVENT" ] && {
					serf event "bootstrap@$NPC_DATACENTER" "$ADDRESSES"
				}
				[ ! -z "$NPC_BOOTSTRAP_ONCE" ] && {
					serf leave &>/dev/null
				}
			}
		[ -f $NPC_BOOTSTRAP_SERVERS ] && return 0
		return 1
	}

	[ ! -f $NPC_BOOTSTRAP_SERVERS ] && {
		[ "$SERF_EVENT" = "user" ] && [ "$SERF_USER_EVENT" = "bootstrap@$NPC_DATACENTER" ] && bootstrap
		[ "$SERF_EVENT" = "member-join" ] && {
			serf members -tag "datacenter=$NPC_DATACENTER" -status=alive -format=json \
				| jq -c 'try .members|map(.host=(.addr|split(":")[0])|'"${NPC_BOOTSTRAP_SERVER_TEMPLATE:-.host}"')' \
				| bootstrap EVENT
		}
	}

	exit 0
fi

export NPC_SERVICE=${NPC_SERVICE:-${CLOUDCOMB_SERVICE_ID:-$(hostname)}}
export NPC_GROUP=${NPC_GROUP:-$NPC_SERVICE}
export NPC_DATACENTER=${NPC_DATACENTER:-default}

[ -z "$NPC_GROUP_INDEX" ] && export NPC_GROUP_INDEX=$(jq -n 'env.NPC_GROUP|split(",")|index(env.NPC_SERVICE)//empty')
[ -z "$NPC_BOOTSTRAP_EXPECT" ] && export NPC_BOOTSTRAP_EXPECT=$(jq -n 'env.NPC_GROUP|split(",")|length')

until BIND_ADDR="$(ip -o -4 addr show ${BIND_INTERFACE:+dev $BIND_INTERFACE} | awk -F '[ /]+' '/global/ {print $4}' | head -1)" && \
	[ ! -z "$BIND_ADDR" ] && export BIND_ADDR; do
		echo "Wait for network ${BIND_INTERFACE:+(dev $BIND_INTERFACE)} ... "
		sleep 1s;
done

export SERF_PORT=${SERF_PORT:-18731}
export SERF_BIND_ADDR=$BIND_ADDR:$SERF_PORT
export SERF_RPC_ADDR=127.0.0.1:$SERF_PORT
export SERF_EVENT_HANDLER="$0"
export SERF_DATACENTER=${NPC_DATACENTER:-default}
jq -n '{
	bind: env.SERF_BIND_ADDR,
	rpc_addr: env.SERF_RPC_ADDR,
	discover: env.SERF_DATACENTER,
	event_handlers: [ env.SERF_EVENT_HANDLER ],
	leave_on_terminate: true,
	tags: {
		service:(env.NPC_SERVICE//""),
		namespace:(env.NPC_NAMESPACE//""),
		datacenter:(env.SERF_DATACENTER//"")
	}
}' >bootstrap.serf

export NPC_BOOTSTRAP_SERVERS=${NPC_BOOTSTRAP_SERVERS:-bootstrap.servers}

if [ ! -z "$NPC_BOOTSTRAP_ONCE" ]; then
	serf agent -config-file=bootstrap.serf
else
	rm -f $NPC_BOOTSTRAP_SERVERS
	serf agent -config-file=bootstrap.serf & SERF_AGENT_PID=$!
	trap "while kill $SERF_AGENT_PID 2>/dev/null; do :; done;" EXIT
fi

until [ -f $NPC_BOOTSTRAP_SERVERS ] && flock $NPC_BOOTSTRAP_SERVERS.lock rm -f $NPC_BOOTSTRAP_SERVERS.lock; do
	sleep 1s;
done

if [ ! -z "$*" ]; then
	echo "$*" 
	$*
else
	wait
fi

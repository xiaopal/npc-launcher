#! /bin/bash

CONSUL_HA="${CONSUL_HA%/}"

sync_begin(){
	[ -z "$SYNC_LOCK_HELD" ] && return 1

	rm -f $INFRA_DIR/*.*
	local STATE_SYNC
	consul kv get "-http-addr=$CONSUL_ENDPOINT" -keys "$CONSUL_HA/" || return 1
	consul kv get "-http-addr=$CONSUL_ENDPOINT" "$CONSUL_HA/.sync" >$INFRA_DIR/.sync && STATE_SYNC="$(cat $INFRA_DIR/.sync)" || return 0
	consul kv get "-http-addr=$CONSUL_ENDPOINT" -keys "$CONSUL_HA/$STATE_SYNC" >$INFRA_DIR/.keys || return 1

	local STATUS SYNC_ITEM
	[ -f $INFRA_DIR/.keys ] && while read -r SYNC_ITEM; do
		[[ "$SYNC_ITEM" != *'/' ]] && [[ "${SYNC_ITEM##*/}" != '.'* ]] && {
			echo "Loading $SYNC_ITEM"
			consul kv get "-http-addr=$CONSUL_ENDPOINT" "$SYNC_ITEM" > "$INFRA_DIR/${SYNC_ITEM##*/}" || STATUS=1
		}
	done < $INFRA_DIR/.keys
	return ${STATUS:-0}
}

sync_end(){
	[ -z "$SYNC_LOCK_HELD" ] && return 1
	
	rm -f $INFRA_DIR/*.json

	local STATUS SYNC_ITEM
	for SYNC_ITEM in $(find $INFRA_DIR -maxdepth 1 -type f -name '*.*'); do
		[[ "${SYNC_ITEM##*/}" != '.'* ]] && [ -f $SYNC_ITEM ] && {
			echo "Saving $SYNC_ITEM"
			consul kv put "-http-addr=$CONSUL_ENDPOINT" "$CONSUL_HA/$SYNC_LOCK_HELD/${SYNC_ITEM##*/}" "@$SYNC_ITEM" || STATUS=1
		}
	done

	[ -z "$STATUS" ] && {
		local STATE_SYNC
		consul kv get "-http-addr=$CONSUL_ENDPOINT" "$CONSUL_HA/.sync" >$INFRA_DIR/.sync && STATE_SYNC="$(cat $INFRA_DIR/.sync)"
		consul kv put "-http-addr=$CONSUL_ENDPOINT" "$CONSUL_HA/.sync" "$SYNC_LOCK_HELD" || STATUS=1
		[ ! -z "$STATE_SYNC" ] && [ "$STATE_SYNC" != "$SYNC_LOCK_HELD" ] && \
			consul kv delete "-http-addr=$CONSUL_ENDPOINT" -recurse "$CONSUL_HA/$STATE_SYNC"
	}

	[ ! -z "$STATUS" ] && {
		consul kv delete "-http-addr=$CONSUL_ENDPOINT" -recurse "$CONSUL_HA/$SYNC_LOCK_HELD"
	}

	return ${STATUS:-0}
}

sync_lock(){
	[ -z "$SYNC_LOCK_HELD" ] && return 1
	consul lock "-http-addr=$CONSUL_ENDPOINT" "-name=$SYNC_LOCK_HELD" "$@" || return 1
}
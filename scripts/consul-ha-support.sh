#! /bin/bash

CONSUL_HA="${CONSUL_HA%/}"

sync_begin(){
	[ -z "$SYNC_LOCK_HELD" ] && return 1

	rm -f $INFRA_DIR/*.*
	consul kv get "-http-addr=$CONSUL_ENDPOINT" -keys "$CONSUL_HA/" >$INFRA_DIR/.keys || return 1

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
	
	consul kv get "-http-addr=$CONSUL_ENDPOINT" -keys "$CONSUL_HA/" >/dev/null || return 1
	rm -f $INFRA_DIR/*.json

	local STATUS SYNC_ITEM
	for SYNC_ITEM in $(find $INFRA_DIR -maxdepth 1 -type f -name '*.*'); do
		[[ "${SYNC_ITEM##*/}" != '.'* ]] && [ -f $SYNC_ITEM ] && {
			echo "Saving $SYNC_ITEM"
			consul kv put "-http-addr=$CONSUL_ENDPOINT" "$CONSUL_HA/${SYNC_ITEM##*/}" "@$SYNC_ITEM" || STATUS=1
		}
	done

	return ${STATUS:-0}
}

sync_lock(){
	[ -z "$SYNC_LOCK_HELD" ] && return 1
	consul lock "-http-addr=$CONSUL_ENDPOINT" "-name=$SYNC_LOCK_HELD" "$@" || return 1
}
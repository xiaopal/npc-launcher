#! /bin/bash

. /comb-api-support.sh

API_REPO_ROOT="$(jq -r '.repo_root//empty' $COMB_API_JSON)"
API_REPO_PREFIX="$(jq -r '.repo_prefix//empty' $COMB_API_JSON)"
API_REPO_NAME="$(jq -r '.repo//empty' $COMB_API_JSON)"

export COMB_REPO_PREFIX="${COMB_REPO_PREFIX:-/${API_REPO_NAME:+$API_REPO_NAME/}${API_REPO_PREFIX#/}}"

COMB_REPO_ROOT="${COMB_REPO_ROOT:-$API_REPO_ROOT}"
[ -z "$COMB_REPO_ROOT" ] && {
	COMB_REPO_ROOT='hub.c.163.com'
	[ ! -z "$COMB_REPO_PREFIX" ] && [[ "$COMB_REPO_PREFIX" = *'/'* ]] && [[ "$COMB_REPO_PREFIX" != '/'* ]] && \
		COMB_REPO_ROOT="${COMB_REPO_PREFIX%%/*}"
}
[ ! -z "$COMB_REPO_ROOT" ] && export COMB_REPO_ROOT="${COMB_REPO_ROOT%/}/"

export CONSUL_ENDPOINT=${CONSUL_ENDPOINT:-127.0.0.1:8500}

hcl2json(){
	json2hcl -reverse < "$1"
}

INFRA_CONF=$1
[ -z "$INFRA_CONF" ] && echo '$INFRA_CONF required.' && exit 1
[ ! -f "$INFRA_CONF" ] && echo "$INFRA_CONF not exists." && exit 1
INFRA_JSON="${INFRA_CONF%.*}.json"
INFRA_LOCK="${INFRA_CONF%.*}.lock"
INFRA_DIR="${INFRA_CONF%.*}.d"; [ ! -d "$INFRA_DIR" ] && mkdir -p "$INFRA_DIR"

# 兼容旧版容器规格
SPEC_ID_ALIAS_1=C1M1S20
SPEC_ID_ALIAS_2=C1M1S20
SPEC_ID_ALIAS_3=C2M2S20
SPEC_ID_ALIAS_4=C2M4S20
SPEC_ID_ALIAS_5=C4M8S20
SPEC_ID_ALIAS_6=C8M16S20
SPEC_ID_ALIAS_7=C16M64S20

init_infra(){
	hcl2json "$INFRA_CONF" | jq '
		def merge: 
		  reduce .[] as $item (null; 
			if type=="object" and ($item|type=="object") then 
				. as $merged | . + ($item | with_entries(.key as $key | .value |= ([$merged[$key],.]|merge))) 
			else $item end);
		def walk(f):
		  . as $in
		  | if type == "object" then
			  reduce keys[] as $key
				( {}; . + { ($key):  ($in[$key] | walk(f)) } ) | f
		  elif type == "array" then map( walk(f) ) | f
		  else f end; 
		  walk(if type == "array" and (.[0]|type == "object") then .|merge else . end)' > $INFRA_JSON && rm -f $INFRA_DIR/*.json || rm -f $INFRA_JSON
	[ ! -f "$INFRA_JSON" ] && return 1

	jq -c '[.namespace//{}| to_entries[] | .key as $namespace
			| ( .value.template//{} | to_entries[] | .value + {name: .key, namespace: $namespace, type:"template"}),
			  ( .value.service//{} | to_entries[] 
				| ( .key | [ gsub("\\{(?<part>[^\\}]+)\\}";"\(.part|split(",")[])") ] ) as $names 
				| .value as $service
				| $names | keys[]| $service 
					+ {name : $names[.], group : (if . > 0 then {names: $names, index: ., prev: $names[.-1]} else {names: $names, index: .} end) } 
					+ {namespace: $namespace, type:"service"})]
            | map(. + {code: "\(.namespace).\(.name)"} | {key: .code, value: .})| from_entries as $entries
        | def extend($from):
                    $from + . 
                    + (if $from.env and .env then {env: ($from.env + .env)} else {} end)
                    + (if $from.init_env and .init_env then {init_env: ($from.init_env + .init_env)} else {} end)
                    + (if $from.links and .links then {links: ($from.links + .links | unique)} else {} end)
                    + (if $from.depends and .depends then {depends: ($from.depends + .depends | unique)} else {} end);
            def entry:
                $entries[.] | if .from then extend("\(.namespace).\(.from)"|entry//{}) else . end;
			$entries[]|select(.type == "service")|.code|entry' $INFRA_JSON | while read -r SERVICE_ENTRY; do
		local NAMESPACE="$(jq -r .namespace<<<"$SERVICE_ENTRY")" \
			SERVICE_NAME="$(jq -r .name<<<"$SERVICE_ENTRY")" \
			SERVICE_CODE="$(jq -r .code<<<"$SERVICE_ENTRY")"
		local SERVICE_LINKS="$INFRA_DIR/$SERVICE_CODE.links.json"

		( export NAMESPACE; jq -c 'try .links[]
			|match("(?:(?<name>.+)=)?(?:ip\\://(?<ip>.+)|(?:(?:(?<namespace>[^\\?]+)\\.)?(?<service>[^@\\?]+)(?<optional>[\\?])?))")|{
				name: ((.captures[0].string//"\(.captures[3].string)"//"IP_\(.captures[1].string)") | gsub("[^A-Za-z0-9]+";"_") | ascii_upcase), 
				service: (if .captures[3].string then "\(.captures[2].string//env.NAMESPACE).\(.captures[3].string)" else null end),
				optional: (.captures[4].length > 0),
				ip: (.captures[1].string)
			}'<<<"$SERVICE_ENTRY" ) | while read -r LINK_ENTRY; do echo "$LINK_ENTRY" >> $SERVICE_LINKS; done

		( jq -r '(try .depends[]),(try .group.prev | select(.))//empty'<<<"$SERVICE_ENTRY";
			[ -f $SERVICE_LINKS ] && jq -r 'select(.service and (.optional|not)) | .service' $SERVICE_LINKS
			) | sort -u | grep . | while read -r SERVICE_DEPEND_NAME; do
			local SERVICE_DEPEND_NS=$NAMESPACE
			[[ "$SERVICE_DEPEND_NAME" == *'.'* ]] && SERVICE_DEPEND_NS="${SERVICE_DEPEND_NAME%.*}" && SERVICE_DEPEND_NAME="${SERVICE_DEPEND_NAME##*.}"
			SERVICE_DEPEND_CODE="$SERVICE_DEPEND_NS.$SERVICE_DEPEND_NAME"

			echo "$SERVICE_DEPEND_CODE" >> "$INFRA_DIR/$SERVICE_CODE.dependOn.json"
			echo "$SERVICE_CODE" >> "$INFRA_DIR/$SERVICE_DEPEND_CODE.dependBy.json"
		done

		jq '.' <<<"$SERVICE_ENTRY" > "$INFRA_DIR/$SERVICE_CODE.def.json" && init_action "$SERVICE_CODE"
	done

	for SERVICE in $(find $INFRA_DIR -name '*.service'); do
		local SERVICE_CODE="$(basename $SERVICE .service)" SERVICE_DEF="${SERVICE%.service}.def.json" SERVICE_ID="$(jq -r '.id//empty' $SERVICE)"
		[ ! -z "$SERVICE_ID" ] && [ ! -f "$SERVICE_DEF" ] && init_action "$SERVICE_CODE" || ([ -z "$SERVICE_ID" ] && rm -f $SERVICE)
	done

	return 0
}

init_action(){
	local SERVICE_CODE="$1"
	local SERVICE="$INFRA_DIR/$SERVICE_CODE.service" \
		SERVICE_DEF="$INFRA_DIR/$SERVICE_CODE.def.json" \
		SERVICE_STAGE="$INFRA_DIR/$SERVICE_CODE.action.json" \
		NAMESPACE="${SERVICE_CODE%.*}" SERVICE_NAME="${SERVICE_CODE##*.}"

	[ -f $SERVICE_STAGE ] && rm -f $SERVICE_STAGE
	
	local SERVICE_STATEFUL SERVICE_ACTION
	[[ $SERVICE_NAME == *'-vm' ]] && SERVICE_STATEFUL=1

	local JQ_PORTS_TO_MAP='try .ports|map(tostring|split("/")|[(.[0]|tostring),(.[1]//"tcp"|ascii_upcase)])|sort|map({port:.[0], target_port:.[0], protocol:.[1]})'

	local SERVICE_ID CONTAINER_ID
	local SERVICE_PORTS SERVICE_IMAGE_PATH SERVICE_SPEC_ID SERVICE_REPLICAS SERVICE_ENVS
	if [ -f "$SERVICE" ]; then
		SERVICE_ID="$(jq -r '.id//empty' $SERVICE)"
		CONTAINER_ID="$(jq -r '.container_id//empty' $SERVICE)" 
		SERVICE_PORTS="$(jq -c "$JQ_PORTS_TO_MAP" $SERVICE)"
		SERVICE_IMAGE_PATH="$(jq -r '.image//empty' $SERVICE)"
		SERVICE_SPEC_ID="$(jq -r '.spec//empty' $SERVICE)"
		SERVICE_REPLICAS="$(jq -r '.replicas//empty' $SERVICE)"
		SERVICE_ENVS="$(jq -Sc '.env//{}' $SERVICE)"
	fi

	local IMAGE_PATH IMAGE_REPO_NAME IMAGE_TAG_NAME TRIGGER UPDATE_READY_SECONDS
	local SPEC_ID REPLICAS PORTS LOG_DIRS 
	local INET_ADDR INET_ADDR_IP
	local INIT_ENVS ENVS FULL_ENVS
	local INIT_JOIN INIT_JOIN_WAN
	local INIT_LINKS
    local SERVICE_GROUP SERVICE_GROUP_INDEX

    if [ -f "$SERVICE_DEF" ]; then
	    SERVICE_GROUP="$(jq -r 'try .group.names|join(",")' $SERVICE_DEF)"
	    SERVICE_GROUP_INDEX="$(jq -r '.group.index//empty' $SERVICE_DEF)"

		IMAGE_PATH="$(jq -r '(.image//empty)|sub("^//";env.COMB_REPO_PREFIX//"")|sub("^/";env.COMB_REPO_ROOT//"")' $SERVICE_DEF)"
		IMAGE_REPO_NAME=${IMAGE_PATH##*/}; IMAGE_REPO_NAME=${IMAGE_REPO_NAME%%:*}
		TRIGGER="$(jq -r '.trigger//empty' $SERVICE_DEF)"
		if [ ! -z "$TRIGGER" ] && [ ! -z "$IMAGE_REPO_NAME" ]; then
			local TRIGGER_IMAGE_PATH="$(export TRIGGER IMAGE_REPO_NAME;  jq -r '.trigger[env.TRIGGER][env.IMAGE_REPO_NAME].image//empty' $INFRA_JSON)"
			[ ! -z "$TRIGGER_IMAGE_PATH" ] && IMAGE_PATH="$TRIGGER_IMAGE_PATH"
		fi
		IMAGE_TAG_NAME=${IMAGE_PATH##*/}
		[[ $IMAGE_TAG_NAME == *':'* ]] && IMAGE_TAG_NAME=${IMAGE_TAG_NAME##*:} || IMAGE_TAG_NAME=
		UPDATE_READY_SECONDS="$(jq -r '.update_ready_seconds//15' $SERVICE_DEF)"

		SPEC_ID="$(jq -r '.spec//empty' $SERVICE_DEF)"
		[ ! -z "$SPEC_ID" ] && local SPEC_ID_ALIAS_NAME=SPEC_ID_ALIAS_$SPEC_ID && SPEC_ID="${!SPEC_ID_ALIAS_NAME:-$SPEC_ID}"

		if [ -z "$SERVICE_STATEFUL" ]; then
			REPLICAS="$(jq -r '.replicas//empty' $SERVICE_DEF)"
		fi

		PORTS="$(jq -c "$JQ_PORTS_TO_MAP" $SERVICE_DEF)"
		LOG_DIRS="$(jq '.logs // ["/app-logs/"]' $SERVICE_DEF)"

		if [ ! -z "$SERVICE_STATEFUL" ]; then
			INET_ADDR="$(jq -r '.inet_addr|strings//booleans|select(.)' $SERVICE_DEF)" 
			INET_ADDR_IP="$(jq -r '.inet_addr|strings' $SERVICE_DEF)"
		fi

		local ENV_DATACENTER="$(jq -r '.datacenter//empty' $SERVICE_DEF)"
		
		INIT_JOIN="$(jq -r '.init_join|strings//empty' $SERVICE_DEF)"
		[ ! -z "$INIT_JOIN" ] && [ -z "$ENV_DATACENTER" ] && ENV_DATACENTER="$INIT_JOIN"

		[ -z "$INIT_JOIN" ] && [ ! -z "$(jq -r '.init_join|booleans|select(.)' $SERVICE_DEF)" ] && INIT_JOIN="${ENV_DATACENTER:-dc1}"

		INIT_JOIN_WAN=$(jq -r '.init_join_wan|strings//empty' $SERVICE_DEF)

		local SERVICE_LINKS="$INFRA_DIR/$SERVICE_CODE.links.json"
		[ -f $SERVICE_LINKS ] && INIT_LINKS="$(jq -Ssc 'map({key:.name, value:(.ip//.service)})|from_entries' $SERVICE_LINKS)"

		INIT_ENVS="$(export SERVICE_NAME NAMESPACE INIT_JOIN INIT_JOIN_WAN INIT_LINKS SERVICE_GROUP SERVICE_GROUP_INDEX; jq -Sc '
				{ NPC_SERVICE : env.SERVICE_NAME, NPC_NAMESPACE : env.NAMESPACE }
				+ (if env.INIT_LINKS|length>0 then (try env.INIT_LINKS | fromjson//{} | with_entries(.value|=null)) else {} end)
				+ (.init_env//{}) 
				+ (if env.SERVICE_GROUP|length>0 then {NPC_GROUP:env.SERVICE_GROUP, NPC_GROUP_INDEX:env.SERVICE_GROUP_INDEX, NPC_GROUP_ADDRS:""} else {} end) 
				+ (if env.INIT_JOIN|length>0 then {NPC_JOIN:null} else {} end) 
				+ (if env.INIT_JOIN_WAN|length>0 then {NPC_JOIN_WAN:null} else {} end)
			' $SERVICE_DEF)"

		ENVS="$(export ENV_DATACENTER INIT_LINKS; 
			jq -Sc '(.env//{})
				+ (if env.ENV_DATACENTER|length>0 then {NPC_DATACENTER:env.ENV_DATACENTER} else {} end) 
				+ (if env.INIT_LINKS|length>0 then {NPC_LINKS:(@base64 "\(env.INIT_LINKS)")} else {} end) 
			' $SERVICE_DEF)"
		
		FULL_ENVS="$(export INIT_ENVS ENVS SERVICE_ENVS; jq -nSc '
            ((try env.INIT_ENVS | fromjson)//{}) as $init_envs | $init_envs | to_entries | map(.key) as $init_keys |
            (try env.SERVICE_ENVS | fromjson)//{} | to_entries | map(select([.key]|inside($init_keys))) | from_entries as $service_envs |
            $init_envs + $service_envs + ((try env.ENVS | fromjson)//{})')"
	fi

	[ -z "$SERVICE_ID" ] && [ -f "$SERVICE_DEF" ] && SERVICE_ACTION=create
	[ ! -z "$SERVICE_ID" ] && [ ! -f "$SERVICE_DEF" ] && SERVICE_ACTION=destroy

	local UPDATE_ENVS UPDATE_IMAGE UPDATE_SPEC_ID UPDATE_PORTS UPDATE_REPLICAS
	if [ ! -z "$SERVICE_ID" ] && [ -f "$SERVICE_DEF" ]; then
		( [ "$FULL_ENVS" != "$SERVICE_ENVS" ] && [ -z "$SERVICE_STATEFUL" ] ) && UPDATE_ENVS=Y && SERVICE_ACTION=update
		( [ ! -z "$SPEC_ID" ] && [ "$SPEC_ID" != "$SERVICE_SPEC_ID" ] && [ -z "$SERVICE_STATEFUL" ]) && UPDATE_SPEC_ID=Y && SERVICE_ACTION=update
		( [ ! -z "$IMAGE_TAG_NAME" ] && [ "$IMAGE_PATH" != "$SERVICE_IMAGE_PATH" ] && [ -z "$SERVICE_STATEFUL" ] ) && UPDATE_IMAGE=Y && SERVICE_ACTION=update
		( [ ! -z "$PORTS" ] && [ "$PORTS" != "$SERVICE_PORTS" ] ) && UPDATE_PORTS=Y && SERVICE_ACTION=update
		( [ ! -z "$REPLICAS" ] && [ "$REPLICAS" != "$SERVICE_REPLICAS" ] && [ -z "$SERVICE_STATEFUL" ] ) && UPDATE_REPLICAS=Y && SERVICE_ACTION=update
	fi

	[ ! -z "$SERVICE_ACTION" ] && ( 
		export SERVICE_ACTION SERVICE_CODE SERVICE_NAME NAMESPACE SERVICE_STATEFUL
		export SERVICE_ID CONTAINER_ID SERVICE_GROUP
		export IMAGE_PATH IMAGE_REPO_NAME IMAGE_TAG_NAME TRIGGER UPDATE_READY_SECONDS
		export SPEC_ID REPLICAS PORTS LOG_DIRS 
		export INET_ADDR INET_ADDR_IP
		export INIT_ENVS ENVS FULL_ENVS
		export INIT_JOIN INIT_JOIN_WAN INIT_LINKS
		export UPDATE_ENVS UPDATE_IMAGE UPDATE_SPEC_ID UPDATE_PORTS UPDATE_REPLICAS

		jq -n '{
			action : (if env.SERVICE_ACTION | length>0 then env.SERVICE_ACTION else null end),
			id : (if env.SERVICE_ID|length>0 then env.SERVICE_ID else null end),
			container_id : (if env.CONTAINER_ID|length>0 then env.CONTAINER_ID else null end),
			code : env.SERVICE_CODE,
			name : env.SERVICE_NAME,
			namespace : env.NAMESPACE,
			stateful : (if env.SERVICE_STATEFUL|length>0 then "1" else "0" end),
			image : {
				path : env.IMAGE_PATH, 
				name : env.IMAGE_REPO_NAME, 
				tag: (if env.IMAGE_TAG_NAME|length>0 then env.IMAGE_TAG_NAME else null end)
			},
			update_ready_seconds : ((try env.UPDATE_READY_SECONDS|tonumber)//15),
			spec : env.SPEC_ID,
			replicas : ((try env.REPLICAS | tonumber)//1),
			port_maps : ((try env.PORTS | fromjson)//[]),
			log_dirs : ((try env.LOG_DIRS | fromjson)//[]),
			envs : ((try env.FULL_ENVS | fromjson)//{}),

			group : env.SERVICE_GROUP,

			init_join : (if env.INIT_JOIN | length>0 then env.INIT_JOIN else null end),
			init_join_wan : (if env.INIT_JOIN_WAN | length>0 then env.INIT_JOIN_WAN else null end),
			init_links : (if env.INIT_LINKS | length>0 then 1 else null end),

			inet_addr : (if env.INET_ADDR | length>0 then env.INET_ADDR else null end),
			inet_addr_ip : (if env.INET_ADDR_IP | length>0 then env.INET_ADDR_IP else null end),

			update_envs : (if env.UPDATE_ENVS | length>0 then 1 else null end),
			update_image : (if env.UPDATE_IMAGE | length>0 then 1 else null end),
			update_spec : (if env.UPDATE_SPEC_ID | length>0 then 1 else null end),
			update_ports : (if env.UPDATE_PORTS | length>0 then 1 else null end),
			update_replicas : (if env.UPDATE_REPLICAS | length>0 then 1 else null end)
		}' > $SERVICE_STAGE
	) && return 0 || return 1
}

lookup_namespace(){
	local NAMESPACE="$1" FORCE_CREATE="$2" NAMESPACE_ID=
	[ -z "$NAMESPACE" ] && return 1

	local NAMESPACES="$INFRA_DIR/NAMESPACES.json"
	if [ ! -f $NAMESPACES ]; then
		api GET /api/v1/namespaces | jq -c '.namespaces[]|{id:.id, name:.display_name}' > $NAMESPACES \
			|| rm -f $NAMESPACES
	fi
	[ -f $NAMESPACES ] && NAMESPACE_ID="$(export NAMESPACE; jq -r 'select(.name == env.NAMESPACE)|.id//empty' $NAMESPACES)"

	if [ -z "$NAMESPACE_ID" ] && [ ! -z "$FORCE_CREATE" ]; then
		NAMESPACE_ID="$(api POST /api/v1/namespaces "$(export NAMESPACE; jq -nc '{name: env.NAMESPACE}')" | jq -r '.namespace_id//.namespace_Id//empty')"
		[ ! -z "$NAMESPACE_ID" ] && rm -f $NAMESPACES
	fi
	[ ! -z "$NAMESPACE_ID" ] && echo "$NAMESPACE_ID" && return 0 || return 1
}

lookup_service(){
	local SERVICE_CODE="$1" NAMESPACE_ID='' SERVICE_ID=''
	local NAMESPACE="${SERVICE_CODE%.*}" SERVICE_NAME="${SERVICE_CODE##*.}"
	local SERVICE="$INFRA_DIR/$SERVICE_CODE.service" NAMESPACE_SERVICES="$INFRA_DIR/$NAMESPACE.SERVICES.json"

	[ -f "$SERVICE" ] && SERVICE_ID="$(jq -r .id $SERVICE)"

	if [ -z "$SERVICE_ID" ]; then
		if [ ! -f $NAMESPACE_SERVICES ]; then
			NAMESPACE_ID="$(lookup_namespace "$NAMESPACE")" && [ ! -z "$NAMESPACE_ID" ] || return 1
			api GET "/api/v1/namespaces/$NAMESPACE_ID/microservices?offset=0&limit=65535" \
				| jq -c '.microservice_infos[] | {id:.id, name:.service_name}' > $NAMESPACE_SERVICES \
				|| rm -f $NAMESPACE_SERVICES
		fi
		[ -f $NAMESPACE_SERVICES ] && SERVICE_ID="$(export SERVICE_NAME; jq -r 'select(.name == env.SERVICE_NAME)|.id//empty' $NAMESPACE_SERVICES)"
	fi

	[ ! -z "$SERVICE_ID" ] && echo "$SERVICE_ID" && return 0 || return 1
}

init_inet_addr(){
	local SERVICE_CODE="$1" INET_ADDR_IP="$2"
	local INET_IPS="$INFRA_DIR/IPS.json" SERVICE_IP="$INFRA_DIR/$NAMESPACE.$SERVICE_NAME.IP" 

	local LOOKUP_IP="$INET_ADDR_IP"
	[ -z "$LOOKUP_IP" ] && [ -f $SERVICE_IP ] && LOOKUP_IP="$(jq -r '.ips[0]|.ip//empty' $SERVICE_IP)"
	if [ ! -z "$LOOKUP_IP" ]; then
		[ ! -f $INET_IPS ] && (api GET '/api/v1/ips?status=available&type=nce&offset=0&limit=65535' > $INET_IPS || rm -f $INET_IPS)
		[ -f $INET_IPS ] && local INET_ADDR_ID="$(export LOOKUP_IP; jq -r '.ips[]|select(.ip == env.LOOKUP_IP)|.id//empty' $INET_IPS)" \
			&& [ ! -z "$INET_ADDR_ID" ] && echo "$INET_ADDR_ID" && return 0
	fi
	[ ! -z "$INET_ADDR_IP" ] && return 1
	api POST '/api/v1/ips' '{"nce": 1}' > $SERVICE_IP \
		&& local INET_ADDR_ID="$(jq -r '.ips[0]|.id//empty' $SERVICE_IP)" \
		&& [ ! -z "$INET_ADDR_ID" ] && echo "$INET_ADDR_ID" && return 0
	rm -f $SERVICE_IP; return 1
}

load_service(){
	local SERVICE_CODE="$1" FORCE_LOAD="$2" SERVICE_ID="$3"
	local SERVICE="$INFRA_DIR/$SERVICE_CODE.service" \
		NAMESPACE="${SERVICE_CODE%.*}" SERVICE_NAME="${SERVICE_CODE##*.}"
	local SERVICE_JSON=$SERVICE.json;
	[ -z "$SERVICE_ID" ] && [ -f "$SERVICE" ] && SERVICE_ID="$(jq -r .id//empty $SERVICE)"
	[ -z "$SERVICE_ID" ] && SERVICE_ID="$(lookup_service "$SERVICE_CODE" )"
	[ -z "$SERVICE_ID" ] && return 1
	
	([ ! -f $SERVICE_JSON ] || [ ! -z "$FORCE_LOAD" ]) \
		&& (api GET /api/v1/microservices/$SERVICE_ID > $SERVICE_JSON || rm -f $SERVICE_JSON)
	
	[ -f $SERVICE_JSON ] && jq '{
		id: .service_info.id, 
		status: .service_info.status,
		name: .service_info.service_name,
		namespace_code: .service_info.namespace,
		spec: .service_info.spec_info|fromjson|.spec_alias,
		ports: .service_info.port_maps|fromjson|map((.port|tostring)+"/"+(.protocol)),
		replicas: (.service_info.replicas//1),
		container_id: (.service_container_infos[0].container_id//""),
		env: (.service_container_infos[0].envs//[])|from_entries,
		logs: (.service_container_infos[0].log_dirs//[]),
		image: (.service_container_infos[0].image_path//""),
		tag: (.service_container_infos[0].image_tag//"")
	}' $SERVICE_JSON > $SERVICE && { init_action "$SERVICE_CODE"; return 0; }

	rm -f $SERVICE_JSON && return 1
}


update_service(){
	local SERVICE_CODE="$1" SERVICE_ID=''
	local SERVICE_STAGE="$INFRA_DIR/$SERVICE_CODE.action.json" \
		SERVICE="$INFRA_DIR/$SERVICE_CODE.service" \
		NAMESPACE="${SERVICE_CODE%.*}" SERVICE_NAME="${SERVICE_CODE##*.}"

	[ ! -f $SERVICE_STAGE ] && return 0		

	if [ "$(jq -r .action $SERVICE_STAGE)" = "destroy" ]; then
		SERVICE_ID="$(jq -r '.id//empty' $SERVICE_STAGE)"
		echo "[ $(date -R) ] ACTION - DESTROY_SERVICE $SERVICE_CODE{id=$SERVICE_ID}"
		local RESPONSE="$(api_http DELETE "/api/v1/microservices/$SERVICE_ID?free_ip=false")"
		local STATUS="$(check_http_response '.status'<<<"$RESPONSE")" BODY="$(check_http_response '.body'<<<"$RESPONSE")"
		( check_http_response<<<"$RESPONSE" || ( [ "$STATUS" = "404" ] && [ "$(jq -r '.code'<<<"$BODY")" = "4040141" ] ) ) && {
			rm -f $SERVICE && return 0
		} || {
			echo "$BODY" >&2 && return 1
		}
	fi

	local CONSUL_JOIN CONSUL_JOIN_WAN INIT_JOIN INIT_JOIN_WAN ENV_LINKS ENV_GROUP_ADDRS
	prepare_envs(){
		INIT_JOIN="$(jq -r .init_join//empty $SERVICE_STAGE)"
		if [ ! -z "$INIT_JOIN" ] && [ -z "$(jq -r '.envs["JOIN"]//empty' $SERVICE_STAGE)" ]; then
			CONSUL_JOIN="$(do_http GET "http://$CONSUL_ENDPOINT/v1/health/service/consul?passing&dc=$INIT_JOIN" \
				| check_http_response '.body|fromjson
					|map(.Node|.TaggedAddresses["lan"]//.Address//empty)|join(",")' false )"
			[ -z "$CONSUL_JOIN" ] && {
				echo "[ $(date -R) ] INFO - $SERVICE_CODE not ready: INIT_JOIN=$INIT_JOIN"
				return 1
			}
		fi
		INIT_JOIN_WAN="$(jq -r .init_join_wan//empty $SERVICE_STAGE)"
		if [ ! -z "$INIT_JOIN_WAN" ] && [ -z "$(jq -r '.envs["JOIN_WAN"]//empty' $SERVICE_STAGE)" ]; then
			CONSUL_JOIN_WAN="$(do_http GET "http://$CONSUL_ENDPOINT/v1/health/service/consul?passing&dc=$INIT_JOIN_WAN" \
				| check_http_response '.body|fromjson
					|map(.Node|.TaggedAddresses["wan"]//.Address//empty)|join(",")' false )"
			[ -z "$CONSUL_JOIN_WAN" ] && {
				echo "[ $(date -R) ] INFO - $SERVICE_CODE not ready: INIT_JOIN_WAN=$INIT_JOIN_WAN"
				return 1
			}
		fi
		if [ ! -z "$(jq -r .init_links//empty $SERVICE_STAGE)" ]; then
			ENV_LINKS="$(while read -r LINK_ENTRY; do
				local LINK_NAME="$(jq -r .name <<<"$LINK_ENTRY")" LINK_IP="$(jq -r .ip//empty <<<"$LINK_ENTRY")" LINK_SERVICE="$(jq -r .service//empty <<<"$LINK_ENTRY")"
				[ -z "$LINK_IP"] && [ ! -z "$LINK_SERVICE" ] && check_service "$LINK_SERVICE" \
					&& LINK_IP="$(grep -E '^ip://' "$INFRA_DIR/$LINK_SERVICE.check.json" | cut -c 6- | sort -R | head -1)"
				( export LINK_NAME LINK_IP; jq -nc '{key: env.LINK_NAME, value:env.LINK_IP }' )
			done < "$INFRA_DIR/$SERVICE_CODE.links.json" | jq -Ssc 'from_entries' )"
		fi

		if [ ! -z "$(jq -r '.group//empty' $SERVICE_STAGE)" ]; then
			ENV_GROUP_ADDRS="$(jq -r 'try .group|split(",")|.[]' $SERVICE_STAGE | while read -r GROUP_ITEM; do
				local GROUP_ITEM_SERVICE="$NAMESPACE.$GROUP_ITEM"
				check_service "$GROUP_ITEM_SERVICE" && grep -E '^ip://' "$INFRA_DIR/$GROUP_ITEM_SERVICE.check.json" | cut -c 6-
			done | jq -R . | jq -rs 'join(",")')"
		fi


		return 0
	}

	[ -z "$(jq -r .image.tag//empty $SERVICE_STAGE)" ] && {
		echo "[ $(date -R) ] INFO - $SERVICE_CODE not ready: IMAGE_PATH=$(jq -r .image.path $SERVICE_STAGE)"
		return 2
	}

	if [ "$(jq -r .action $SERVICE_STAGE)" = "create" ]; then
		prepare_envs || return 2
		
		local INET_ADDR_ID INET_ADDR="$(jq -r .inet_addr//empty $SERVICE_STAGE)" INET_ADDR_IP="$(jq -r .inet_addr_ip//empty $SERVICE_STAGE)"
		[ ! -z "$INET_ADDR" ] && INET_ADDR_ID="$(init_inet_addr "$SERVICE_CODE" "$INET_ADDR_IP")" && [ -z "$INET_ADDR_ID" ] && {
			echo "[ $(date -R) ] INFO - $SERVICE_CODE not ready: inet_addr=$INET_ADDR"
			return 2
		}

		local NAMESPACE_ID="$(lookup_namespace "$NAMESPACE" 1)" && [ ! -z "$NAMESPACE_ID" ] || return 1

		# create service
		local CREATE_SERVICE="$(
			export NAMESPACE_ID INET_ADDR_ID CONSUL_JOIN CONSUL_JOIN_WAN ENV_LINKS ENV_GROUP_ADDRS
			jq -c '{
				bill_info:"default",
				service_info: ({
					namespace_id: env.NAMESPACE_ID,
					stateful: .stateful,
					replicas: .replicas,
					service_name: .name,
					port_maps: .port_maps,
					spec_alias: (if .spec | length>0 then .spec else "C1M1S20" end),
					disk_type: 2
				} + (if env.INET_ADDR_ID | length>0 then
						{state_public_net:{used: true, type: "flow", bandwidth: 1}, ip_id: env.INET_ADDR_ID}
					else 
						{state_public_net:{used: false, type: "flow", bandwidth: 1}}
					end)),
				service_container_infos: [{
					image_path: .image.path,
					container_name: .name,
					envs: ((
						.envs 
						+ (if env.ENV_LINKS | length>0 then (try env.ENV_LINKS | fromjson)//{} else {} end)
						+ (if env.ENV_GROUP_ADDRS | length>0 then { NPC_GROUP_ADDRS: env.ENV_GROUP_ADDRS } else {} end)
						+ (if env.CONSUL_JOIN | length>0 then {NPC_JOIN : env.CONSUL_JOIN} else {} end)
						+ (if env.CONSUL_JOIN_WAN | length>0 then {NPC_JOIN_WAN : env.CONSUL_JOIN_WAN} else {} end)
						)|to_entries//[]),
					log_dirs: .log_dirs,
					cpu_weight: 100, 
					memory_weight: 100,
					local_disk_info: [],
					volume_info:{}
				}]
			}' $SERVICE_STAGE)"
		echo "[ $(date -R) ] ACTION - CREATE_SERVICE $SERVICE_CODE: $CREATE_SERVICE"
		api POST /api/v1/microservices "$CREATE_SERVICE" > $SERVICE \
			&& SERVICE_ID="$(jq -r '.service_id' $SERVICE)"; rm -f $SERVICE	
		[ ! -z "$SERVICE_ID" ] && { 
			load_service "$SERVICE_CODE" 1 "$SERVICE_ID" || return 1 
			return 0 
		}
		load_service "$SERVICE_CODE" || return 1
	fi

	if [ -f $SERVICE_STAGE ] && [ "$(jq -r .action $SERVICE_STAGE)" = "update" ] && load_service "$SERVICE_CODE"; then
		local CONTAINER_ID PENDING_STATUS UPDATE_STATUS
		
		init_update(){
			PENDING_STATUS=
			[ -f $SERVICE_STAGE ] || return 1
			SERVICE_ID="$(jq -r .id $SERVICE_STAGE)"
			CONTAINER_ID="$(jq -r .container_id//empty $SERVICE_STAGE)"
			
			local SERVICE_STATUS="$(jq -r '.status//empty' $SERVICE)"
			[ ! -z "$SERVICE_STATUS" ] && [[ "$SERVICE_STATUS" != *'_succ' ]] && {
				PENDING_STATUS="$SERVICE_STATUS"
				return 1
			}
			[ -z "$CONTAINER_ID" ] && {
				PENDING_STATUS=require_container 
				return 1
			}

			return 0
		}

		if init_update && [ ! -z "$(jq -r .update_envs//empty $SERVICE_STAGE)" ]; then
			prepare_envs || return 2
			local UPDATE_STATELESS="$(
				export CONSUL_JOIN CONSUL_JOIN_WAN ENV_LINKS ENV_GROUP_ADDRS
				jq -c '{container_infos: [{
					container_id: .container_id, 
					envs: ((
						.envs 
						+ (if env.ENV_LINKS | length>0 then (try env.ENV_LINKS | fromjson)//{} else {} end)
						+ (if env.ENV_GROUP_ADDRS | length>0 then { NPC_GROUP_ADDRS: env.ENV_GROUP_ADDRS } else {} end)
						+ (if env.CONSUL_JOIN | length>0 then {NPC_JOIN : env.CONSUL_JOIN} else {} end)
						+ (if env.CONSUL_JOIN_WAN | length>0 then {NPC_JOIN_WAN : env.CONSUL_JOIN_WAN} else {} end)
						)|to_entries//[]),
					log_dirs: .log_dirs, 
					cpu_weight: 100, 
					memory_weight: 100 
				}]}' $SERVICE_STAGE)"
			echo "[ $(date -R) ] ACTION - UPDATE_STATELESS $SERVICE_CODE{id=$SERVICE_ID}: $UPDATE_STATELESS"
			api PUT "/api/v1/microservices/$SERVICE_ID/actions/update-stateless" "$UPDATE_STATELESS" && load_service "$SERVICE_CODE" 1 || UPDATE_STATUS=1
		fi
		if init_update && [ ! -z "$(jq -r .update_image//empty $SERVICE_STAGE)" ]; then
			local UPDATE_IMAGE="$(jq -c '{
				container_images: [{
					container_id: .container_id, 
					image_path: .image.path
				}],
				min_ready_seconds: .update_ready_seconds
			}' $SERVICE_STAGE)"
			echo "[ $(date -R) ] ACTION - UPDATE_IMAGE $SERVICE_CODE{id=$SERVICE_ID}: $UPDATE_IMAGE"
			api PUT "/api/v1/microservices/$SERVICE_ID/actions/update-image" "$UPDATE_IMAGE" && load_service "$SERVICE_CODE" 1 || UPDATE_STATUS=1
		fi
		if init_update && [ ! -z "$(jq -r .update_spec//empty $SERVICE_STAGE)" ]; then
			local UPDATE_SPEC_ID="$(jq -r .spec $SERVICE_STAGE)"
			echo "[ $(date -R) ] ACTION - UPDATE_SPEC_ID $SERVICE_CODE{id=$SERVICE_ID}: $UPDATE_SPEC_ID"
			api PUT "/api/v1/microservices/$SERVICE_ID/specification?spec_alias=$UPDATE_SPEC_ID" && load_service "$SERVICE_CODE" 1 || UPDATE_STATUS=1
		fi
		if init_update && [ ! -z "$(jq -r .update_ports//empty $SERVICE_STAGE)" ]; then
			local UPDATE_PORTS="$(jq -c '{port_maps : .port_maps}' $SERVICE_STAGE)"
			echo "[ $(date -R) ] ACTION - UPDATE_PORTS $SERVICE_CODE{id=$SERVICE_ID}: $UPDATE_PORTS"
			api PUT "/api/v1/microservices/$SERVICE_ID/actions/update-port" "$UPDATE_PORTS" && load_service "$SERVICE_CODE" 1 || UPDATE_STATUS=1
		fi
		if init_update && [ ! -z "$(jq -r .update_replicas//empty $SERVICE_STAGE)" ]; then
			local UPDATE_REPLICAS="$(jq -r .replicas $SERVICE_STAGE)"
			echo "[ $(date -R) ] ACTION - UPDATE_REPLICAS $SERVICE_CODE{id=$SERVICE_ID}: $UPDATE_REPLICAS"
			api PUT "/api/v1/microservices/$SERVICE_ID/actions/elastic-scale?new_replicas=$UPDATE_REPLICAS" && load_service "$SERVICE_CODE" 1 || UPDATE_STATUS=1
		fi
		[ ! -z "$PENDING_STATUS" ] && { 
			echo "[ $(date -R) ] INFO - Pending $SERVICE_CODE:  PENDING_STATUS=$PENDING_STATUS SERVICE_ID=$SERVICE_ID CONTAINER_ID=$CONTAINER_ID"
			return 1
		}
	fi
	return ${UPDATE_STATUS:-0}
}

check_service(){
	local SERVICE_CODE="$1"
	local SERVICE_CHECK="$INFRA_DIR/$SERVICE_CODE.check.json" \
		SERVICE_JSON="$INFRA_DIR/$SERVICE_CODE.service.json" \
		SERVICE_DEF="$INFRA_DIR/$SERVICE_CODE.def.json" \
		SERVICE_STAGE="$INFRA_DIR/$SERVICE_CODE.action.json"

	[ -f $SERVICE_STAGE ] && return 1

	[ -f $SERVICE_CHECK ] && return 0

	local SERVICE_ID="$(lookup_service "$SERVICE_CODE")"
	
	[ -z "$SERVICE_ID" ] && return 1

	[ ! -f $SERVICE_JSON ] && (api GET /api/v1/microservices/$SERVICE_ID > $SERVICE_JSON || rm -f $SERVICE_JSON)
	if [ -f $SERVICE_JSON ]; then
		local SERVICE_STATUS="$(jq -r 'try .service_info.status' $SERVICE_JSON)"
		[[ "$SERVICE_STATUS" = *'_succ' ]] && while read -r LAN_IP; do
			echo "ip://$LAN_IP" >> $SERVICE_CHECK

			local HTTP_CHECK=''
			[ -f "$SERVICE_DEF" ] && HTTP_CHECK="$(export LAN_IP; jq -r '.check.http//empty|"http://\(env.LAN_IP):\(.port//80)\(.path//"/")"' $SERVICE_DEF)";
			if [ ! -z "$HTTP_CHECK" ]; then
				local HTTP_CHECK_JQ="$(jq -r '.check.http.jq//empty' $SERVICE_DEF)"
				do_http GET "$HTTP_CHECK" | check_http_response "${HTTP_CHECK_JQ:+.body|fromjson|$HTTP_CHECK_JQ}" false >/dev/null && echo "$HTTP_CHECK" >> $SERVICE_CHECK || { 
					rm -f $SERVICE_CHECK && echo "[ $(date -R) ] INFO - $SERVICE_CODE Failed to check $HTTP_CHECK"
					return 1 
				}
			fi
		done< <(jq -r 'try .service_container_infos[]|.lan_ips[]' $SERVICE_JSON)
	fi

	[ -f $SERVICE_CHECK ] && return 0 || return 1
}

sync(){
	sync_begin && init_infra || return 1

	local SYNC_STATUS

	sync_service(){
		local SERVICE_CODE="$1"
		local SERVICE_STAGE="$INFRA_DIR/$SERVICE_CODE.action.json" \
			SERVICE_DEPEND_ON="$INFRA_DIR/$SERVICE_CODE.dependOn.json" \
			SERVICE_DEPEND_BY="$INFRA_DIR/$SERVICE_CODE.dependBy.json"
		
		if [ -f $SERVICE_DEPEND_ON ]; then
			while read -r DEPEND_SERVICE_CODE ; do
				check_service "$DEPEND_SERVICE_CODE" || return 1
			done < <(sort -u $SERVICE_DEPEND_ON | grep .)
		fi

		if [ -f $SERVICE_STAGE ]; then
			update_service "$SERVICE_CODE" \
				|| { echo "[ $(date -R) ] WARN - Failed to update $SERVICE_CODE" && return 1; }
		fi
		
		if [ -f $SERVICE_DEPEND_BY ]; then
			while read -r NEXT_SERVICE_CODE ; do
				sync_service "$NEXT_SERVICE_CODE" || SYNC_STATUS=1
			done < <(sort -u $SERVICE_DEPEND_BY | grep .)
		fi
		
		[ -z "$SYNC_STATUS" ] && check_service "$SERVICE_CODE" && return 0
		return 1
	}

	for SERVICE_STAGE in $(find $INFRA_DIR -name '*.action.json'); do
		local SERVICE_CODE="$(basename $SERVICE_STAGE .action.json)" SERVICE_ACTION="$(jq -r .action $SERVICE_STAGE)"
		echo "$SERVICE_CODE" >> "$INFRA_DIR/SYNC.$SERVICE_ACTION.json"
	done

	( [ -f "$INFRA_DIR/SYNC.create.json" ] || [ -f "$INFRA_DIR/SYNC.update.json" ] || [ -f "$INFRA_DIR/SYNC.destroy.json" ] ) \
		&& for SERVICE_DEF in $(find $INFRA_DIR -name '*.def.json'); do
			local SERVICE_CODE="$(basename $SERVICE_DEF .def.json)"
			if [ ! -f "$INFRA_DIR/$SERVICE_CODE.dependOn.json" ]; then
				sync_service "$SERVICE_CODE" || SYNC_STATUS=1
			fi
	done
	
	if [ -z "$SYNC_STATUS" ] && [ -f "$INFRA_DIR/SYNC.destroy.json" ]; then
		if [ ! -z "$(find $INFRA_DIR -name '*.def.json' -print)" ]; then
			while read -r SERVICE_CODE; do
				update_service "$SERVICE_CODE" || SYNC_STATUS=1
			done < "$INFRA_DIR/SYNC.destroy.json"
		else
			# 防止异常删除所有容器
			echo "[ $(date -R) ] WARN - Destroying all services ! (Not Supported)"
		fi
	fi

	sync_end $SYNC_STATUS || SYNC_STATUS=1
	return ${SYNC_STATUS:-0}
}

sync_begin(){
	return 0
}
sync_end(){
	return 0
}
sync_lock(){
	(
		flock 200 || exit 1
		"$@"
		exit 0
	) 200<$INFRA_LOCK 
}

[ ! -z "$CONSUL_HA" ] && . /consul-ha-support.sh

INFRA_SYNC_STATUS="${INFRA_CONF%.*}.status"
if [ ! -z "$SYNC_LOCK_HELD" ]; then
	# 检测到变更后延迟5s启动
	check_infra(){
		while ! md5sum -c $INFRA_LOCK &>/dev/null; do
			md5sum $INFRA_CONF >$INFRA_LOCK
			echo "[ $(date -R) ] INFO - $INFRA_CONF changed."
			sleep 5s
		done
		return 0
	}
	rm -f $INFRA_SYNC_STATUS && check_infra && sync || echo 1>$INFRA_SYNC_STATUS
else
	touch $INFRA_LOCK && while SYNC_LOCK_HELD="$(cat /proc/sys/kernel/random/uuid | md5sum | (read -r ID _ && echo $ID))" sync_lock "$0" "$@" && \
			[ -f $INFRA_SYNC_STATUS ]; do
		sleep 5s
	done
fi

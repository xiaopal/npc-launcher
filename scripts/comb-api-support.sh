#! /bin/bash

COMB_API_HOST=https://open.c.163.com
COMB_API_TOKEN=${COMB_API_TOKEN:-~/.comb-api.token}
[ -z "$COMB_API_JSON" ] && [ -f ~/.comb-api.json ] && COMB_API_JSON=~/.comb-api.json
[ -z "$COMB_API_JSON" ] && [ -f /.comb-api.json ] && COMB_API_JSON=/.comb-api.json
[ -z "$COMB_API_JSON" ] && [ ! -z "$COMB_API_KEY" ] && [ ! -z "$COMB_API_SECRET" ] && COMB_API_JSON=~/.comb-api.json \
	&& echo '{"app_key":"'"$COMB_API_KEY"'","app_secret":"'"$COMB_API_SECRET"'"}' > $COMB_API_JSON

do_http(){
	local METHOD="$1" URI="$2" DATA="$3"; shift && shift && shift
	local RESPONSE="$( exec 3> >(export METHOD URI DATA;jq -sc '{method: env.METHOD, uri: env.URI, data: env.DATA, status:.[0], body:.[1]}')
		export BODY="$(curl -s -k -o >(cat >&1) -w '"%{http_code}"' -X "$METHOD" -d "$DATA" "$@" "$URI" >&3)"
		jq -n 'env.BODY' >&3 )"
	jq -r '"HTTP \(.status) - \(.method) \(.uri)"'<<<"$RESPONSE" >&2 && echo "$RESPONSE" 
}

check_http_response(){
	local RESPONSE="$(cat -)" FILTER="$1" ERROR_OUTPUT="$2"
	[[ "$(jq -r '.status'<<<"$RESPONSE")" = 20* ]] && {
		[ ! -z "$FILTER" ] && {
			jq -ecr "$1"<<<"$RESPONSE" || return 1 
		}
		return 0
	} || {
		[ ! -z "$FILTER" ] && [ "$ERROR_OUTPUT" != "false" ] && {
			[ ! -z "$ERROR_OUTPUT" ] && jq -cr "$1"<<<"$RESPONSE" >"$ERROR_OUTPUT" ||  jq -cr "$1"<<<"$RESPONSE"
		}
		return 1
	}
}

api_http(){
	local METHOD="$1" URI="$2" REQUEST="$3"
	do_auth(){
		[ ! -z "$COMB_API_JSON" ] && [ -f $COMB_API_JSON ] || { 
			echo '$COMB_API_JSON/.comb-api.json required'>&2
			return 1
		}
		do_http POST "$COMB_API_HOST/api/v1/token" "$(cat $COMB_API_JSON)" -H 'Content-Type: application/json'| check_http_response '.body' false > $COMB_API_TOKEN && return 0 || {
			 cat $COMB_API_TOKEN >&2 && echo >&2 && rm -f $COMB_API_TOKEN
			 return 1
		}
	}

	do_api(){
		[ ! -f $COMB_API_TOKEN ] && { do_auth || return 1; }
		local TOKEN=$(jq -r '.token//empty' $COMB_API_TOKEN)
		do_http "$METHOD" "$COMB_API_HOST$URI" "$REQUEST" ${TOKEN:+-H "Authorization: Token $TOKEN"} -H 'Content-Type: application/json'
	}

	local RESPONSE=$(do_api)
	
	[ "$(check_http_response '.status'<<<"$RESPONSE")" = "401" ] && {
		rm -f $COMB_API_TOKEN
		RESPONSE=$(do_api)
	}
	echo "$RESPONSE"
}

api(){
	api_http "$@" | check_http_response '.body' /dev/fd/2 && return 0 || return 1
}

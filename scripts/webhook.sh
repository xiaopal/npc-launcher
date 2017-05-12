#! /bin/bash

ok(){
	echo -e "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK" && exit 0
}

bad(){
	echo -e "HTTP/1.0 400 Bad Request\r\nContent-Length: 3\r\n\r\nBAD" && exit 1 
}

read -t 1 -r LINE && [[ "$LINE" = "POST /webhook"* ]] || bad

[ -z "$GIT_WEBHOOK_TOKEN" ] && ok

while read -t 1 -r LINE; do
	[[ "$LINE" = *"$GIT_WEBHOOK_TOKEN" ]] && ok
	[ -z "$LINE" ] && bad
done

bad

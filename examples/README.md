```
while true; do serf agent -config-file=bootstrap.serf; echo "serf agent exited, wait 5s and retry..."; sleep 5s; done &

for SERF_PORT in {7373,{8001..8005}}; do
  serf agent -node="PORT-$SERF_PORT" -bind="192.168.137.100:$SERF_PORT" -rpc-addr="127.0.0.1:$SERF_PORT" -discover=serf -tag datacenter=serf &
done

docker run --rm npc-bootstrap cat bootstrap.servers
docker run --rm -v $PWD/npc-bootstrap.sh:/npc-bootstrap.sh npc-bootstrap cat bootstrap.servers
for I in {1..5};do 
  docker run --rm -e NPC_BOOTSTRAP_EXPECT=5 -v $PWD/npc-bootstrap.sh:/npc-bootstrap.sh npc-bootstrap cat bootstrap.servers &
done

for I in {1..5};do 
  docker run --rm -e NPC_BOOTSTRAP_ONCE=Y -e NPC_BOOTSTRAP_EXPECT=5 -v $PWD/npc-bootstrap.sh:/npc-bootstrap.sh npc-bootstrap cat bootstrap.servers &
done

for I in {1..5};do 
  docker run --rm -e NPC_SERVICE=zookeeper.$I -e ZK_PORT=18011 -e NPC_BOOTSTRAP_SERVER_TEMPLATE='"\(.tags.service)=\(.host):\(env.ZK_PORT)"' -e NPC_BOOTSTRAP_EXPECT=5 -v $PWD/npc-bootstrap.sh:/npc-bootstrap.sh npc-bootstrap cat bootstrap.servers &
done

for I in {1..5};do 
  docker run --rm -e NPC_SERVICE=zookeeper.$I -e ZK_PORT=18011 -e NPC_BOOTSTRAP_ONCE=Y -e NPC_BOOTSTRAP_SERVER_TEMPLATE='"\(.tags.service)=\(.host):\(env.ZK_PORT)"' -e NPC_BOOTSTRAP_EXPECT=5 -v $PWD/npc-bootstrap.sh:/npc-bootstrap.sh npc-bootstrap cat bootstrap.servers &
done
```
FROM alpine:3.5

ADD npc-bootstrap.tar.gz /
ADD npc-bootstrap.sh /
RUN chmod a+x /npc-bootstrap.sh

ENTRYPOINT ["/npc-bootstrap.sh"]
CMD ["/bin/sh"]
FROM alpine:3.5

# RUN echo -e 'https://mirrors.ustc.edu.cn/alpine/v3.5/main\nhttps://mirrors.ustc.edu.cn/alpine/v3.5/community' >/etc/apk/repositories && \
#     apk update && apk add curl openssh-client git bash && \
# 	rm -rf /var/cache/apk/* 
# ADD dumb-init.tar.gz /usr/bin
# ADD jq_1.5_linux_amd64.tar.gz /usr/bin
# ADD json2hcl_v0.0.6_linux_amd64.tar.gz /usr/bin
ADD bin-all.tar.gz /

ADD scripts /
RUN chmod a+x /*.sh
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/launch.sh"]
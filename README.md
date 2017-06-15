蜂巢服务代理演示版
===

开始使用
---
```
COMB_API_KEY='<蜂巢APP_KEY>'
COMB_API_SECRET='<蜂巢APP_SECRET>'
# COMB_API_KEY="$(jq -r .app_key ~/.comb-api.json)" 
# COMB_API_SECRET="$(jq -r .app_secret ~/.comb-api.json)" 

# 启动服务
docker run -it --rm \
    -e COMB_API_KEY="$COMB_API_KEY" \
    -e COMB_API_SECRET="$COMB_API_SECRET" \
    -e GIT_URL="https://github.com/xiaopal/npc-launch-repo.git" \
	-p 9000:9000 \
    xiaopal/npc-launcher:latest

# 指定SSH KEY启动服务
docker run -it --rm \
    -e COMB_API_KEY="$COMB_API_KEY" \
    -e COMB_API_SECRET="$COMB_API_SECRET" \
	-e GIT_URL=ssh://git@g.hz.netease.com:22222/cloud-wyzc/npc-launch-repo.git \
    -v $HOME/.ssh:/.ssh \
	-p 9000:9000 \
    xiaopal/npc-launcher:latest

# 特殊用法：根据模板在蜂巢创建服务，完成后退出
# COMB_API_KEY="$(jq -r .app_key ~/.comb-api.json)" \
# COMB_API_SECRET="$(jq -r .app_secret ~/.comb-api.json)" \
COMB_API_KEY='<蜂巢APP_KEY>'
COMB_API_SECRET='<蜂巢APP_SECRET>'
cat<<EOF >infrastructure.conf
namespace "fnd" {
    // 编排npc-launcher服务
    service "npc-launcher" {
        stateful = true
        image = "/xiaopal/npc-launcher:latest"
        spec = "C1M2S20"
        ports = [9000]
        env {
            COMB_API_KEY = "$COMB_API_KEY"
            COMB_API_SECRET = "$COMB_API_SECRET"
            GIT_URL = "https://github.com/xiaopal/npc-launch-repo.git"
        }
    }
}
EOF
docker run -it --rm \
    -e COMB_API_KEY="$COMB_API_KEY" \
    -e COMB_API_SECRET="$COMB_API_SECRET" \
    -e COMB_SYNC_INTERVAL=once \
    -v $PWD/infrastructure.conf:/infrastructure.conf \
    xiaopal/npc-launcher:latest
```

配置(环境变量)
---
```
COMB_API_KEY='<蜂巢APP_KEY>'
COMB_API_SECRET='<蜂巢APP_SECRET>'
COMB_REPO_PREFIX='/<蜂巢镜像仓库用户名>/'

# Git配置仓库地址
# 如果使用ssh key认证，记录启动过程打印的自动生成公钥并设置到配置仓库；如有必要，映射到文件 /.ssh/id_rsa 设置git仓库私钥 
GIT_URL='<Git配置仓库地址>'
# 配置仓库分支，默认'master'
# GIT_BRANCH=master
# 配置仓库路径，默认'/'
# GIT_PATH=/

# GIT_WEBHOOK设置
# 监听端口，默认'9000'
# GIT_WEBHOOK_PORT=9000
# WEBHOOK地址，默认'/webhook'
# GIT_WEBHOOK_PATH=/webhook
# 检查在回调HTTP头中包含的TOKEN，默认无
# GIT_WEBHOOK_TOKEN='XXXXXXX'

# 启动consul agent，默认不启动
# CONSUL_AGENT='-data-dir=/consul.data -join=10.173.32.5'

# 定期自动拉取配置并同步的间隔，默认1分钟，设置为 once 则在第一次创建并完成后退出
# COMB_SYNC_INTERVAL='1m'
```


`配置仓库`规则和服务定义语法
---
空间（服务）定义: `${GIT_PATH}/<namespace>.conf` 
```
    // 定义服务
    service "busybox" {
        // 镜像地址，必需，无状态服务支持更新
        // * "/library/busybox:latest" 自动扩展为 "hub.c.163.com/library/busybox:latest"
        // * "//busybox:latest" 自动扩展为 "hub.c.163.com${COMB_REPO_PREFIX}busybox:latest"
        image = "/library/busybox:latest" 
        
        // 设置环境变量，无状态服务支持更新
        env = { 
            TZ = "Asia/Shanghai"
        }

        // 绑定的服务端口号，JSON数组，至少包含一项，默认[22]
        // * 默认绑定协议tcp
        // ports = [8500,"8301/tcp","8301/udp"]  

        // 指定创建有状态服务，默认创建无状态服务
        // stateful = true

        // 容器规格，创建时默认2，无状态服务支持更新
        // * 规格选项：1-微小型/CNY0.049/1CPU/640M, 2-小型/CNY0.06/1CPU/1G, 3-中型/CNY0.19/2CPU/2G, 
        // *           4-大型/CNY0.25/2CPU/4G, 5-豪华型/CNY0.52/4CPU/8G, 6-旗舰型/CNY1.02/8CPU/16G, 
        // *           7-超级旗舰型/CNY3.32/16CPU/64G
        // spec = 2
        
        // 覆盖命令行
        // command = "/usr/sbin/sshd -D"

        // 副本数，创建时默认1，无状态服务支持更新
        // replicas = 1

        // 服务依赖
        // depends = ["service-1", "default.service-3"]

        // 服务状态检查（可作用于服务依赖）
        // check http {
        //     path = "/health"
        //     port = 9000
        // }

        // 绑定外网IP(自动申请IP)
        // inet_addr = true

        // 绑定外网IP(绑定已有IP)
        // inet_addr = "xx.xx.xx.xx"
    }

    service "busybox-2" {
        // 继承另一个服务
        from = "busybox"
        // ...
    }

    // 服务模板: 不创建服务，允许被其他服务 from 引用
    template "consul-tmpl" { 
        stateful = true
        image = "/wyzcdevops/zc-consul:latest" 
        // ...
    }

    service "consul-instance" { 
        // 继承服务模板
        from = "consul-tmpl"
        // ...
    }

    // 服务组：批量定义多个服务
    // * 该示例展开后相当于定义了相互有依赖关系的三个服务：[consul-a] -(被依赖)-> [consul-b] -(被依赖)-> [consul-c] 
    // *    service "consul-a" { 
    // *        from = "consul-tmpl"
    // *        env {
    // *            NPC_GROUP = "consul-a,consul-b,consul-c"
    // *            NPC_GROUP_INDEX = "0"
    // *            NPC_GROUP_ADDRS = ""
    // *        }
    // *     }
    // *    service "consul-b" { 
    // *        from = "consul-tmpl"
    // *        env {
    // *            NPC_GROUP = "consul-a,consul-b,consul-c"
    // *            NPC_GROUP_INDEX = "1"
    // *            NPC_GROUP_ADDRS = "<consul-a服务内网IP>"
    // *        }
    // *     }
    // *    service "consul-c" { 
    // *        from = "consul-tmpl"
    // *        env {
    // *            NPC_GROUP = "consul-a,consul-b,consul-c"
    // *            NPC_GROUP_INDEX = "2"
    // *            NPC_GROUP_ADDRS = "<consul-a服务内网IP>,<consul-b服务内网IP>"
    // *        }
    // *     }
    service "consul-{a,b,c}" { 
        stateful = true
        from = "consul-tmpl"
    }

```
其他说明：
- 修改服务定义中支持更新的属性（所有服务的ports，无状态服务的 image、 env、 spec 和 replicas），对应蜂巢服务属性也被更新
- 无状态服务的 env、 spec 和 replicas 属性如果没有设置， 则只在创建服务时使用默认值
- 移除服务定义条目，对应的蜂巢服务被删除


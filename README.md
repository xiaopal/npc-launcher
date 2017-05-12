蜂巢服务代理
===

名称空间（服务）定义: `/config/comb/<namespace>.conf` 
---
配置规则如下：
```
    // 定义服务：默认创建无状态服务，服务名包含"-vm"后缀则创建有状态服务
    service "consul-0-vm" { 
        description = "Consul-1"

        // 镜像地址，必需，无状态服务支持更新
        // * 如果同时设置了trigger， 可不填写tag以避免trigger触发前创建服务， 如 image = "hub.c.163.com/wyzcdevops/zc-consul" 
        image = "hub.c.163.com/wyzcdevops/zc-consul:latest" 
        
        // 绑定的服务端口号，JSON数组，必需（且至少包含一项）
        // * 默认绑定协议tcp
        ports = [8500,"8301/tcp","8301/udp"]  

        //设置环境变量，无状态服务支持更新
        env = { 
            TIME_ZONE = "Asia/Shanghai"
        }

        // 仅用于初始化的环境变量，作为变量缺省值，生效优先级低于 env，仅在蜂巢服务缺失变量时进行更新
		// * 自动添加的条目： 
		// *     CONSUL_NAME=<当前服务名>
		// * 如果init_join=true, 自动添加以下条目： 
		// *     JOIN=<根据CONSUL_DATACENTER查询的consul服务节点IP列表>
        // init_env = { 
		//     CONSUL_NAME = "consul-0-vm"
		//     JOIN = "10.1.1.1,10.2.2.2"
        // }

		// consul 数据中心
		// * 等同在env设置CONSUL_DATACENTER
        // datacenter = "wyzc" 

		// 自动寻找和加入 consul 节点(通过在init_env设置JOIN实现, 隐含设置datacenter即同时在env设置CONSUL_DATACENTER)
		// init_join = "<datacenter>"

		// 自动寻找和加入 consul wan 节点(通过在init_env设置JOIN_WAN实现, 隐式启动CONSUL_SERVER模式)
		// init_join_wan = "<wan_datacenter>"

        // 容器规格，创建时默认2，无状态服务支持更新
        // * 规格选项：1-微小型/CNY0.049/1CPU/640M, 2-小型/CNY0.06/1CPU/1G, 3-中型/CNY0.19/2CPU/2G, 
        // *           4-大型/CNY0.25/2CPU/4G, 5-豪华型/CNY0.52/4CPU/8G, 6-旗舰型/CNY1.02/8CPU/16G, 
        // *           7-超级旗舰型/CNY3.32/16CPU/64G
        // spec = 2
        
        // 副本数，创建时默认1，无状态服务支持更新
        // replicas = 1

        // 关联镜像触发器：如果设置，触发器中对应仓库的image属性覆盖为服务镜像地址
        // trigger = "release-SNAPSHOT"

		// 服务依赖
		// depends = ["consul-1-vm", "wyzc-fnd-services.consul-1-vm"]

		// 服务连接
		// links = ["consul-1-vm", "consul1=wyzc-fnd-services.consul-1-vm?", "consul-1=ip://10.0.0.1"]

		// 服务状态检查（作用于服务连接和服务依赖）
		// check http {
		//     path = "/health"
		//     port = 9000
		// }

    }

    service "consul-1-vm" {
		// 继承另一个服务
		from = "consul-0-vm"
        // ...
    }

	//服务模板
    template "consul-2-tmpl" { 
		// ...
    }

	service "consul-2-vm" { 
		// 继承服务模板
		from = "consul-2-tmpl"
        // ...
    }

	//定义服务组管理多个服务
	service "consul-{a,b}-vm" { 
        // ...
    }


```
说明：
- 修改服务定义中支持更新的属性（所有服务的ports，无状态服务的 image、 env、 spec 和 replicas），对应蜂巢服务属性也被更新
- 无状态服务的 env、 spec 和 replicas 属性如果没有设置， 则只在创建服务时使用默认值
- 移除服务定义条目，对应的蜂巢服务被删除
- 注意清空或删除 `<namespace>.conf` 不会删除之前创建的服务。  
  

镜像触发器定义: /config/comb/triggers.properties 
---
配置规则如下：
```
# 定义方式：触发器名称=镜像版本匹配的模式(包含*作为通配符)
# * 如果触发器名称以SNAPSHOT结尾，代表临时镜像，临时镜像在仓库中仅保留最新版本
develop-SNAPSHOT=develop.r*
release-SNAPSHOT=release-*.r*
hotfix-SNAPSHOT=hotfix-*.r*
tags=v*
```
说明：
- 读取容器内 /webhooks 文件 或 访问 `http://<容器地址>/webhooks` 能获取以下内容

>
```
*:develop.r*=http://<container-ip>/trigger/develop-SNAPSHOT?{}
*:hotfix-*.r*=http://<container-ip>/trigger/hotfix-SNAPSHOT?{}
*:release-*.r*=http://<container-ip>/trigger/release-SNAPSHOT?{}
*:v*=http://<container-ip>/trigger/tags?{}
```

- 请求该地址可以更新镜像版本： `http://<container-ip>/trigger/<TRIGGER>?<版本全路径>`  
  如  `curl 'http://127.0.0.1/trigger/tags?hub.c.163.com/wyzcdevops/app-test:v1.0.1'`
- 镜像版本被更新后，所有绑定该触发器的服务镜像版本被同步更新；对于临时镜像，仓库中与模式匹配的所有其他版本镜像自动被删除（除非该版本是其他触发器的当前镜像）
  
  
  
  
附：infrastructure.conf 解析规则 
---
```
// 定义空间
// * 注意移除空间定义后不会自动删除已创建的空间
namespace "wyzc-fnd-services" {

    // 定义服务：默认创建无状态服务，服务名包含"-vm"后缀则创建有状态服务
    service "consul-0-vm" { 
        description = "Consul-1"

        // 镜像地址，必需，无状态服务支持更新
        // * 如果同时设置了trigger， 可不填写tag以避免trigger触发前创建服务， 如 image = "hub.c.163.com/wyzcdevops/zc-consul" 
        image = "hub.c.163.com/wyzcdevops/zc-consul:latest" 
        
        // 绑定的服务端口号，JSON数组，必需（且至少包含一项）
        // * 默认绑定协议tcp
        ports = [8500,"8301/tcp","8301/udp"]  
        
        //设置环境变量，无状态服务支持更新
        env = { 
            CONSUL_DATACENTER = "wyzc"
            CONSUL_NAME = "consul"
        }

        // 容器规格，创建时默认2，无状态服务支持更新
        // * 规格选项：1-微小型/CNY0.049/1CPU/640M, 2-小型/CNY0.06/1CPU/1G, 3-中型/CNY0.19/2CPU/2G, 
        // *           4-大型/CNY0.25/2CPU/4G, 5-豪华型/CNY0.52/4CPU/8G, 6-旗舰型/CNY1.02/8CPU/16G, 
        // *           7-超级旗舰型/CNY3.32/16CPU/64G
        // spec = 2
        
        // 副本数，创建时默认1，无状态服务支持更新
        // replicas = 1

        // 关联镜像触发器：如果设置，触发器中对应仓库的image属性覆盖为服务镜像地址
        // trigger = "release-SNAPSHOT"
    }

    service "consul-1-vm" { 
        // ...
    }
}

namespace "wyzc-app-develop" {
    service "nginx-web-develop" {
        description = "Nginx Web Site"
        image = "hub.c.163.com/wyzcdevops/nginx-web:latest" 
        ports = [80, 443]  
        env = { 
            CONSUL_DATACENTER = "wyzc"
            CONSUL_NAME = "nginx-web-develop"
        }
        trigger = "develop-SNAPSHOT"
    }
}

// 定义镜像触发器
trigger "develop-SNAPSHOT" {
    // 仓库名称
    "nginx-web" = {
        // 镜像地址
        image = "hub.c.163.com/wyzcdevops/nginx-web:develop.r571"
        // 镜像版本删除规则，如果设置了snapshot，在image每次更新后自动删除仓库中与规则匹配的所有其他镜像
        snapshot = "develop.r*"
    }
    "zc-consul" = {
        image = "hub.c.163.com/wyzcdevops/zc-consul:develop.r571"
    }
}

trigger "release-SNAPSHOT" {
    "nginx-web" = {
        image = "hub.c.163.com/wyzcdevops/nginx-web:release-v1.13.r154"
        snapshot = "release-v*.r*"
    }
}

trigger "tags" {
    "nginx-web" = {
        image = "hub.c.163.com/wyzcdevops/nginx-web:v1.2"
    }
}
```

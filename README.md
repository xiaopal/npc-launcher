蜂巢服务代理
===

名称空间（服务）定义: `/config/comb/<namespace>.conf` 
---
配置规则如下：
```
    // 定义服务：默认创建无状态服务，服务名包含"-vm"后缀则创建有状态服务
    service "consul-0-vm" { 

        // 镜像地址，必需，无状态服务支持更新
        // * 如果同时设置了trigger， 可不填写tag以避免trigger触发前创建服务， 如 image = "hub.c.163.com/wyzcdevops/zc-consul" 
        image = "hub.c.163.com/wyzcdevops/zc-consul:latest" 
        
        // 绑定的服务端口号，JSON数组，必需（且至少包含一项）
        // * 默认绑定协议tcp
        ports = [8500,"8301/tcp","8301/udp"]  

        //设置环境变量，无状态服务支持更新
        env = { 
            TZ = "Asia/Shanghai"
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


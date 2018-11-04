# Gateway

This is the API gateway for the back end. It uses [Ambassador][1].

The different templates are based off the yaml [here][2] from Ambassador's [Getting Started][3]
page. The prefab Helm chart that Ambassador supplies isn't used as it creates its own ELB and 
does way more than it needs to for this application.

AWS EKS has Kubernetes RBAC enabled by default.

**NOTE**: When configuring the route for a service behind the gateway, the path needs to 
include the "/api" prefix otherwise the proxy won't happen. The path-based routing in the
ELB routes "/api/*" to the gateway. That complete path is then used by the gateway in its
routing. 

TODO: need to figure out how to get easy access to Gateway admin webpage.

[1]:https://www.getambassador.io/
[2]:https://getambassador.io/yaml/ambassador/ambassador-rbac.yaml
[3]:https://www.getambassador.io/user-guide/getting-started/
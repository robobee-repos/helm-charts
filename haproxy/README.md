# HAProxy

[HAProxy](https://www.haproxy.org/) is a TCP proxy and a HTTP reverse proxy. It supports SSL termination and offloading, TCP and HTTP normalization, traffic regulation, caching and protection against DDoS attacks.

## TL;DR

```console
$ helm repo add bitnami https://charts.bitnami.com/bitnami
$ helm install my-release bitnami/haproxy
```

## Introduction

Clone of the original Bitnami HaProxy Helm chart:

https://github.com/bitnami/charts/tree/master/bitnami/haproxy

## Modifications

* Add externalIPs to service;

## License

Copyright &copy; 2022 Erwin Müller
Copyright &copy; 2022 Bitnami

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

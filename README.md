# demo-multi-cluster

## Overview

This is a demo of multiple clusters. It follows the
model of 
[Open Cluster Management](https://open-cluster-management.io/)
with a hub cluster and several worker clusters which are
controlled by the hub cluster.

This demo installs ArgoCD and OLM. Using OLM and the
ArgoCD AppSet Cluster Decision Resource Generator
a number of applications (cert-manager, reloader etc)
is installed in the worker clusters.

## Start

To start the clusters in kind, run the following command:

```shell
make start-kind
```
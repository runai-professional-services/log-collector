# runai log collector

This proprietary script is designed to collect logs via kubectl and generate a general information dump to aid in debugging and troubleshooting Run:AI environments.


## pre-requisites
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) (with admin access to the cluster)
- [helm](https://helm.sh/docs/intro/install/)

## execution
```
chmod +x ./start.sh
bash ./start.sh
```

Once done, a `tar.gz` archive is generated per namespace (`runai` / `runai-backend`), time-stamped for identification.

## `runai` namespace

### folder tree

```
runai-logs-07-07-2025_14-30
├── cm_runai-public.yaml
├── engine-config.yaml
├── helm_charts_list.txt
├── helm-values_runai-cluster.yaml
├── logs
│   ├── <POD_NAME>_<CONTAINER_NAME>.log
│   ├── ...
├── node-list.txt
├── pod-list_runai.txt
└── runaiconfig.yaml
```

### file mapping

| file name | command output |
|--|--|
| `logs/${POD}_${CONTAINER}.log` | `kubectl -n $NAMESPACE logs --timestamps $POD -c  $CONTAINER` |
| `cm_runai-public.yaml` | `kubectl  -n  runai  get  cm  runai-public  -o  yaml` |
| `engine-config.yaml` | `kubectl  -n  runai  get  configs.engine.run.ai  engine-config  -o  yaml` |
| `helm_charts_list.txt` | `helm  ls  -A` |
| `helm-values_runai-cluster.yaml` | `helm  -n  runai  get  values  runai-cluster` |
| `node-list.txt` | `kubectl  get  nodes  -o  wide` |
| `pod-list_runai.txt` | `kubectl  -n  runai  get  pods  -o  wide` |
| `runaiconfig.yaml` | `kubectl  -n  runai  get  runaiconfig  runai  -o  yaml` |

## `runai-backend` namespace

### folder tree

```
runai-backend-logs-07-07-2025_14-31
├── helm-values_runai-backend.yaml
├── logs
│   ├── <POD_NAME>_<CONTAINER_NAME>.log
│   ├── ...
└── pod-list_runai-backend.txt
```

### file mapping

| file name | command output |
|--|--|
| `logs/${POD}_${CONTAINER}.log` | `kubectl -n $NAMESPACE logs --timestamps $POD -c  $CONTAINER` |
| `helm-values_runai-backend.yaml` | `helm  -n  runai-backendget  values  runai-backend` |
| `pod-list_runai-backend.txt` | `kubectl  -n  runai-backend  get  pods  -o  wide` |

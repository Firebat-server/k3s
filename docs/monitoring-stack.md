# K3s 네이티브 모니터링 스택

## 결정 사항

워크로드는 `monitoring` namespace에 설치하고, Argo CD `Application` 객체는 기존처럼
`server` namespace에서 관리한다. 저장소 경로도 `application-set/server` 아래에 둔다.
이를 위해 ApplicationSet이 values의 `destinationNamespace`를 읽도록 확장했다.

단일 노드에서 다음 네 개의 Argo CD Application으로 분리한다.

| Application | Chart | 고정 버전 | 주요 애플리케이션 버전 |
|---|---|---:|---:|
| kube-prometheus-stack-dev | kube-prometheus-stack | 87.17.0 | Operator 0.92.1, Prometheus 3.13.1, Alertmanager 0.33.1, Grafana 13.1.0 |
| loki-dev | loki | 18.5.1 | Loki 3.7.3 |
| alloy-dev | alloy | 1.10.1 | Alloy 1.17.1 |
| blackbox-exporter-dev | prometheus-blackbox-exporter | 11.15.1 | Blackbox Exporter 0.28.0 |

`monitoring-config-dev`는 이 저장소의 로컬 Chart이며 클러스터 전용
`PrometheusRule`과 선택적 `AlertmanagerConfig`를 관리한다. 위 버전들의 Chart
metadata는 Kubernetes 1.33을 지원한다(`kube-prometheus-stack`/Loki는 1.25 이상).
업그레이드는 반드시 release note와 CRD diff를 검토한 별도 변경으로 수행한다.

공식 참고 자료:

- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Loki monolithic 설치](https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/)
- [Alloy Kubernetes 설치](https://grafana.com/docs/alloy/latest/set-up/install/kubernetes/)
- [Prometheus local storage](https://prometheus.io/docs/prometheus/latest/storage/)

## 용량과 보존 정책

- Prometheus: `30Gi` PVC, `30d`, `20GB`
- Alertmanager: `2Gi` PVC, 상태 보존 `120h`
- Grafana: `5Gi` PVC
- Loki: `20Gi` PVC, `30일(720h)`

기존 Prometheus의 `365d`는 512GB 단일 SSD와 local-path 단일 복제 구조에서
시간 기준만으로 예측하기 어렵고, WAL/compaction 여유 공간까지 잠식할 수 있다.
초기값은 30일과 20GB 중 먼저 도달하는 조건으로 제한한다. 실제 2~4주간
`prometheus_tsdb_storage_blocks_bytes`, WAL 크기, PVC 증가율을 본 뒤 조정한다.

모든 StatefulSet PVC는 삭제/scale-down 시 `Retain` 정책을 사용한다. 다만
`local-path`는 노드 장애에 대한 복제나 원격 백업이 아니다. PVC/PV 보존과 별도로
정기적인 외부 디스크 백업이 필요하다.

`local-path`가 동적으로 만든 PV는 기본 reclaim policy가 `Delete`이므로 PVC가 최초
바인딩된 뒤 해당 PV를 `Retain`으로 바꾼다. 2026-07-19 현재 Prometheus,
Alertmanager, Grafana, Loki의 PV 4개는 모두 `Retain`으로 변경했다. PVC를 재생성하거나
새 PVC를 추가하면 다음 확인을 반복한다.

```bash
for pvc in $(sudo k3s kubectl -n monitoring get pvc -o name); do
  pv=$(sudo k3s kubectl -n monitoring get "$pvc" -o jsonpath='{.spec.volumeName}')
  sudo k3s kubectl patch pv "$pv" --type=merge \
    -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
done
sudo k3s kubectl get pv -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,CLAIM:.spec.claimRef.namespace/.spec.claimRef.name
```

`Retain`은 우발적인 provisioner 삭제를 막지만 backup을 대신하지 않는다. Released PV를
다시 연결하거나 실제 hostPath를 정리하는 작업은 별도 승인과 backup 후에만 수행한다.

## 검색 범위 정책

Prometheus는 모든 namespace를 검색하지만 아래 label이 붙은 리소스만 수집한다.

```yaml
monitoring_jay_gemini_com_enabled: "true"
```

대상은 `ServiceMonitor`, `PodMonitor`, `Probe`, `ScrapeConfig`, `PrometheusRule`이다.
즉 전체 namespace 운영 편의는 유지하면서 임의의 팀이 만든 scrape 설정이 자동으로
Prometheus에 주입되는 것은 막는다. 새 exporter를 추가할 때 같은 label을 붙인다.

K3s에서 API server와 kubelet 수집은 활성화했다. 내장 scheduler,
controller-manager, etcd, kube-proxy는 kubeadm static Pod처럼 검색되지 않으므로
기본 ServiceMonitor를 켜면 false positive가 발생한다. 이 네 대상은 초기에는 끈다.

## Secret 준비

Git에는 실제 값이나 base64 인코딩 값을 커밋하지 않는다. Argo sync 전에 Grafana
Secret을 서버에서 먼저 만든다. 아래 파일 두 개는 임시 위치에서 만들고 권한을
`0600`으로 제한한다.

```bash
sudo k3s kubectl create namespace monitoring --dry-run=client -o yaml \
  | sudo k3s kubectl apply -f -

sudo k3s kubectl -n monitoring create secret generic monitoring-grafana-admin \
  --from-file=admin-user=/secure/path/admin-user \
  --from-file=admin-password=/secure/path/admin-password
```

알림 채널도 같은 원칙으로 만든다.

```bash
sudo k3s kubectl -n monitoring create secret generic monitoring-alertmanager-channels \
  --from-file=slack-api-url=/secure/path/slack-api-url
```

그 후 `monitoring-config/chart/values.yaml`의 `alertmanagerChannels.enabled`를
환경 values에서 `true`로 덮어쓰면 Secret을 참조하는 `AlertmanagerConfig`가
생성된다. 기본 상태의 `default`, `warning`, `critical` receiver는 의도적인 no-op이다.
Secret이 준비되기 전 잘못된 외부 전송을 시도하지 않는다.

Alertmanager는 환경변수 치환을 기본 지원하지 않으므로 Kubernetes Secret의
`secretKeyRef` 또는 마운트된 secret file을 사용한다. Slack 외에 다음 구조를
추가할 수 있다.

- Discord/Mattermost: `webhookConfigs.urlSecret`
- Telegram: `telegramConfigs.botToken` Secret 참조
- Email: SMTP password Secret 참조
- Slack: `slackConfigs.apiURL` Secret 참조

각 integration에는 `sendResolved: true`를 설정한다. warning/critical 채널 분리,
grouping, 반복 주기, critical이 warning을 억제하는 inhibit rule은 기본 values에 있다.

## Grafana와 접근 정책

Grafana만 Ingress를 기본 활성화한다. 익명 로그인과 회원가입은 꺼져 있고 admin
credential은 기존 Secret에서 읽는다. Prometheus/Alertmanager/Loki에는 Ingress,
NodePort, LoadBalancer가 없다. Grafana datasource와 Kubernetes dashboard는 Chart가
ConfigMap/sidecar provisioning으로 관리한다.

- Prometheus: kube-prometheus-stack이 기본 datasource로 생성
- Alertmanager: kube-prometheus-stack이 datasource로 생성
- Loki: `http://loki.monitoring.svc.cluster.local:3100`
- Dashboard: Kubernetes 기본 dashboard + Loki dashboard ConfigMap

호스트 Nginx 연결은 [nginx-routing.md](./nginx-routing.md)를 따른다.

## 로그 수집 선택

Promtail은 2026년 3월 EOL이므로 신규 수집기는 Alloy를 선택한다. Alloy는 노드마다
하나의 DaemonSet으로 실행하며 다음 데이터를 Loki에 보낸다.

- `/var/log/pods`의 containerd CRI Pod 로그
- namespace, pod, container, node, app, cluster label
- `/var/log/journal`의 systemd journal
- Kubernetes Events

positions/state는 노드의 `/var/lib/alloy`에 둔다. 기존 Docker 로그는 전환 기간 동안
호스트 systemd Promtail이 계속 수집한다. Alloy에서 Docker 파일 수집까지 동시에 켜면
같은 로그가 중복되므로 기본값은 꺼져 있다. 모든 Docker 서비스가 옮겨진 뒤에만
기존 Promtail을 종료한다.

Ubuntu가 persistent journal 대신 `/run/log/journal`만 쓰는 경우에는 서버 확인 후
해당 경로를 read-only hostPath로 추가해야 한다. 존재하지 않는 경로를 추측해
배포 시 생성하지 않는다.

## Blackbox target

실제 대상은 `application-set/server/blackbox-exporter/values/targets.yaml`에서만
관리한다. 파일은 빈 목록으로 시작한다. 예시에는 HTTPS, backend health, TCP,
DNS 형식이 주석으로 들어 있다. endpoint별로 `probe_type` label을 지정해야 제공된
HTTPS 실패, 5xx, latency, TLS 30일/7일, DNS, TCP alert가 정확히 작동한다.

## 리소스 시작값

단일 6C/12T, 32GB 노드를 기준으로 Prometheus는 request 0.5 CPU/2Gi, limit
2 CPU/6Gi로 시작한다. Loki는 0.2 CPU/512Mi, limit 1 CPU/2Gi이다. Grafana,
Operator, Alertmanager, Alloy, kube-state-metrics, node-exporter, blackbox exporter와
sidecar/init container에도 requests/limits를 지정했다. 배포 후 throttling과 실제
working set을 관찰해 조정한다.

node-exporter는 hostNetwork를 사용하지 않으므로 기존 systemd node_exporter의
host `9100`과 충돌하지 않는다. K3s 검증이 끝나기 전 systemd 서비스를 중지하지 않는다.

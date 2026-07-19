# Docker Compose → K3s 모니터링 이전 Runbook

## 안전 원칙

- 기존 Docker 컨테이너와 systemd 서비스는 검증이 끝날 때까지 유지한다.
- `docker compose down -v`, PVC/PV 삭제, local-path 디렉터리 삭제는 수행하지 않는다.
- GitOps 배포와 데이터 이전을 같은 변경 창에서 동시에 하지 않는다.
- 모든 copy 전에 source와 destination을 각각 백업한다.
- 스크립트는 기본 dry-run이며 `--execute`와 typed confirmation 없이는 변경하지 않는다.

## 1. 사전 조사와 백업

2026-07-19 읽기 전용 조사 기준 legacy 상태는 다음과 같다.

| 항목 | 실행 버전 | Docker volume | 사용량 |
|---|---:|---|---:|
| Prometheus | 3.6.0 | `monitoring_prometheus-storage` | 약 2.7GB |
| Grafana | 12.2.0 | `monitoring_grafana-storage` | 약 68MB |
| Loki | 3.5.5 | `monitoring_loki-storage` | 약 1.0GB |
| Promtail | 3.5.6 | 없음(bind mount) | - |

Docker Compose는 `/srv/monitoring/docker-compose.yml`에 있고 Prometheus/Grafana
provisioning도 `/srv/monitoring` 아래 bind mount로 관리된다. systemd
node_exporter와 promtail은 모두 active/enabled 상태다. legacy 이미지 tag가
`latest`이므로 이후 재시작 전에 현재 image ID와 설정 backup이 특히 중요하다.
실행 중인 Prometheus scrape job은 `prometheus`, `node_exporter` 두 개다.

서비스를 중단하지 않고 생성한 최초 구성/인벤토리 백업은 서버의
`/home/jaemin/backups/monitoring-pre-k3s/20260719T061555Z`에 있으며 권한은 `0600`이다.
실행 중 TSDB의 일관된 cold backup은 데이터 이전 스크립트가 두 Prometheus를 멈춘
변경 창에서 별도로 생성한다.

다음 항목을 기록한다.

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
sudo docker volume ls
sudo docker inspect monitoring_prometheus-storage
sudo docker inspect monitoring_grafana-storage
sudo systemctl status node_exporter promtail --no-pager
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get storageclass,pv,pvc -A
sudo k3s kubectl get pods,svc,ingress -A
```

Compose 파일, Prometheus config/rules, Grafana provisioning, Loki config,
Promtail config와 Nginx 설정을 별도 백업한다. 이 단계에서는 서비스를 중지하지 않는다.

## 2. 신규 스택 배포

1. `monitoring-grafana-admin` Secret을 먼저 생성한다.
2. 변경을 review/commit/push한다.
3. Argo CD에서 CRD와 kube-prometheus-stack을 먼저 sync한다.
4. Loki, Alloy, blackbox exporter, monitoring-config를 sync한다.
5. 모든 Service가 ClusterIP이고 예상 밖 NodePort/LoadBalancer가 없는지 확인한다.

```bash
sudo k3s kubectl -n monitoring get pods,pvc,svc,ingress
sudo k3s kubectl -n monitoring get prometheus,alertmanager,prometheusrule,servicemonitor
sudo k3s kubectl -n monitoring get svc -o wide
```

Prometheus Targets에서 API server, kubelet, node-exporter, kube-state-metrics,
Grafana, Alertmanager, Alloy, Loki를 확인한다. `product` namespace의
`argocd-image-updater-controller` CrashLoopBackOff alert가 firing인지도 확인한다.

```bash
sudo k3s kubectl -n monitoring logs statefulset/loki --tail=200
sudo k3s kubectl -n monitoring logs daemonset/alloy --tail=200
sudo k3s kubectl -n monitoring get prometheusrule monitoring-config-dev-alerts -o yaml
```

Alertmanager receiver는 Secret이 준비되기 전 no-op이다. 테스트용 `vector(1)` alert를
짧게 추가해 warning/critical route와 resolved 알림을 확인한 뒤 제거한다.

## 3. Prometheus 데이터

Prometheus 공식 문서는 실행 중인 TSDB 디렉터리를 그대로 복사하는 대신 snapshot을
권장한다. snapshot API는 `--web.enable-admin-api`가 필요하고 기존 컨테이너에서 꺼져
있을 수 있다. 이 저장소의 script는 보수적으로 다음 순서를 사용한다.

1. Docker volume/PVC/PV 경로와 이미지 major 버전을 비교한다.
2. Argo reconcile을 잠시 멈추고 신규 Prometheus를 0 replica로 만든다.
3. 기존 Docker Prometheus를 정상 종료한다.
4. Docker 원본 전체와 신규 PVC 기존 내용을 각각 tar backup한다.
5. 신규 PVC 내용은 삭제하지 않고 timestamp quarantine으로 이동한다.
6. immutable TSDB block을 복사하고 WAL, `chunks_head`, lock은 제외한다.
7. 신규 Prometheus readiness를 확인한다.
8. 실패하면 자동으로 신규 PVC의 이전 상태를 복구한다.
9. 기존 Docker 컨테이너는 다시 시작하고 volume은 유지한다.

```bash
./scripts/migrate-prometheus-data.sh
./scripts/migrate-prometheus-data.sh --execute --allow-major-upgrade
```

Prometheus 2 → 3처럼 major가 다르면 자동 실행을 막는다. release note/TSDB 호환성을
검토한 뒤에만 `--allow-major-upgrade`를 사용한다. 성공 후에도 일정 기간 legacy
Prometheus를 read-only 비교 대상으로 유지한다. 장기적으로 중요한 과거 데이터는
remote storage 도입을 별도 검토한다.

복구 예시:

```bash
./scripts/migrate-prometheus-data.sh \
  --restore /var/backups/k3s-monitoring/prometheus/TIMESTAMP/k3s-prometheus-before.tar.gz \
  --execute
```

## 4. Grafana 데이터

우선순위는 provisioning된 dashboard/datasource를 코드로 재생성하는 것이다. UI에서만
만든 dashboard, user, folder가 많다면 raw volume migration을 사용한다. script는 두
Grafana를 중지하고 source/destination 전체를 백업한 뒤 SQLite DB와 plugin/data를
복사한다. major 버전 차이는 명시적으로 승인해야 한다.

```bash
./scripts/migrate-grafana-data.sh
./scripts/migrate-grafana-data.sh --execute --allow-major-upgrade
```

기존 DB를 복사하면 기존 admin password가 유지되며 Kubernetes admin Secret이 기존
계정 암호를 덮어쓰지 않는다. datasource의 secure field는 Grafana API export로 복구할
수 없으므로 별도 Secret/provisioning으로 다시 설정한다. plugin이 Grafana 13과
호환되는지도 확인한다.

## 5. Loki 데이터

기본 전략은 직접 병합하지 않고 신규 Loki를 비어 있는 TSDB v13 filesystem으로
시작하는 것이다. 조사된 legacy는 Loki 3.5.5, filesystem TSDB v13,
`from: 2020-10-24`, `index_`, 24시간 period이며 신규 Loki 3.7.3도 이 schema를
맞췄다. 따라서 완전 정지 후 cold copy의 기술적 가능성은 있으나, 신규 30일
retention compactor가 더 오래된 block을 정리할 수 있어 기본 자동화 대상은 아니다.

안전한 병행 전략:

1. 기존 Docker Loki/Promtail을 유지한다.
2. 신규 Alloy는 K3s Pod/journal만 신규 Loki로 전송한다.
3. 필요하면 Grafana에 `Loki Legacy` datasource를 임시 추가한다.
4. 기존 보존 기간(14~30일)이 지난 뒤 legacy Loki를 백업하고 종료한다.

직접 이전은 기존/신규 Loki image, schema config의 `from/store/object_store/schema`,
index prefix/period, storage path가 모두 일치하고 두 프로세스를 완전히 중지한 별도
작업 창에서만 검토한다. 기본 자동화 대상이 아니다.

## 6. Cutover와 legacy 종료

최소 며칠 동안 다음을 확인한다.

- Prometheus target/rule evaluation/Alertmanager delivery
- Grafana dashboard와 Loki Explore
- Prometheus/Loki PVC 증가율과 compaction 오류
- Alloy dropped/retry 로그
- node-exporter 중복 series가 없는지
- Nginx/Traefik 경유 Grafana 로그인과 WebSocket

검증 후에만 아래 명령을 사람이 실행한다. 이 저장소나 migration script는 자동으로
실행하지 않는다.

```bash
sudo systemctl disable --now node_exporter
sudo systemctl disable --now promtail
```

Docker Compose도 먼저 `stop`만 사용하고 volume은 남긴다. 관찰/백업 보존 기간이 끝난
후 별도 승인된 작업에서 container와 volume 정리를 수행한다.

# 호스트 Nginx → K3s Traefik 라우팅

호스트 Nginx가 80/443을 유지하고 TLS를 종료한다. Nginx는 HTTP Traefik NodePort
`127.0.0.1:30080`으로 전달하고, Traefik Ingress가 ClusterIP Service를 선택한다.

```text
Internet → host Nginx :443 → Traefik NodePort :30080
         → Kubernetes Ingress → ClusterIP Service
```

## Grafana

기존 인증서 include와 TLS 정책은 현재 서버 구성을 재사용한다. 핵심 location 예시는
다음과 같다.

```nginx
server {
    listen 443 ssl http2;
    server_name grafana.jay-gemini.com;

    # ssl_certificate /etc/letsencrypt/live/.../fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/.../privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:30080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 300s;
    }
}
```

`$connection_upgrade` map이 없다면 http 블록에 다음을 한 번 정의한다.

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

변경 전 `sudo nginx -t`를 실행하고, 성공한 경우에만 reload한다. 호스트에서 TLS를
종료하므로 이 경로는 `30443`이 아니라 `30080`을 사용한다. Grafana의 `root_url`은
외부 주소인 `https://grafana.jay-gemini.com`이다.

## Alertmanager

기본 배포에는 Alertmanager Ingress가 없다. 외부 UI가 꼭 필요할 때만 Ingress를
추가하고, Nginx에서 VPN 대역 또는 고정 IP를 제한한다.

```nginx
server {
    listen 443 ssl http2;
    server_name alertmanager.jay-gemini.com;

    allow 100.64.0.0/10; # 예: Tailscale; 실제 VPN 대역으로 교체
    allow 203.0.113.10;  # 예시 고정 관리 IP; 실제 값으로 교체
    deny all;

    location / {
        proxy_pass http://127.0.0.1:30080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Basic Auth를 추가한다면 htpasswd 파일은 Git 밖에서 관리하고 location에
`auth_basic`/`auth_basic_user_file`을 설정한다. Traefik에서 제한하려면 다음과 같은
Middleware를 Ingress에 연결할 수 있다.

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: monitoring-admin-allowlist
  namespace: monitoring
spec:
  ipAllowList:
    sourceRange:
      - 100.64.0.0/10
      - 203.0.113.10/32
```

실제 대역을 확인하기 전에는 적용하지 않는다. Basic Auth Secret도 평문 manifest가
아니라 서버 측 Secret 또는 secret manager로 생성한다.

## Prometheus와 Loki

두 UI/API는 외부 도메인으로 공개하지 않는다. 필요할 때만 SSH 접속 후 임시
port-forward를 사용한다.

```bash
sudo k3s kubectl -n monitoring port-forward svc/kube-prometheus-stack-dev-prometheus 19090:9090 --address 127.0.0.1
sudo k3s kubectl -n monitoring port-forward svc/loki 13100:3100 --address 127.0.0.1
```

Prometheus/Alertmanager의 실제 Service 이름은 Argo CD release 이름에 따라 달라질 수
있으므로 먼저 `sudo k3s kubectl -n monitoring get svc`로 확인한다.


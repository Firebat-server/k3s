# Infisical 설치 및 운영

기존 ApplicationSet 형식에 맞춘 자체 호스팅 구성이다. `infisical-dev`와
`infisical-redis-dev` Application, 워크로드, 초기 Secret은 모두 기존 `server`
namespace에 설치된다.

| 구성 | 설정 |
|---|---|
| Infisical | 공식 `infisical-standalone` 차트 `1.11.0`, 이미지 `v0.161.11`, 복제본 1개 |
| PostgreSQL | 기존 `postgresql-dev-primary.data.svc.cluster.local:5432`, 전용 DB·사용자 `infisical` |
| Redis | 별도 로컬 차트, 공식 `redis:7.4.11-alpine`, 인증·AOF·5Gi local-path PVC |
| 접속 주소 | `https://infisical.jaystacks.com` |
| TLS | 기존처럼 호스트 Nginx에서 종료하고 Traefik의 HTTP NodePort 30080으로 전달 |

공식 차트의 내장 PostgreSQL·Redis·ingress-nginx는 비활성화했다. Infisical의
`DB_CONNECTION_URI`, `REDIS_URL` 등은 Kubernetes Secret에서만 주입한다.
Redis 연결은 캐시와 백그라운드 작업을 위해 필수다. 전용 Redis를 설치하는 것은
이 구성의 선택이며, 외부 Redis를 사용할 경우 `REDIS_URL`을 해당 서비스로 변경하고
Infisical용 ServiceAccount·NetworkPolicy를 유지한 채 Redis 배포를 대체한다.
`destinationNamespace: server`를 명시해 기존 ApplicationSet의 Harbor Image Updater
목록에도 포함되지 않는다. Kubernetes Secret 동기화 Operator 설치와 기존 서비스의
Secret 이전은 이번 구성에 포함되지 않는다.

## 1. 사전 준비

다음 작업은 실제 K3s에 연결된 서버에서 수행한다. Secret이 준비되기 전에 이 변경을
`main`에 반영하면 자동 동기화로 Secret 누락 상태의 Pod가 먼저 생성될 수 있다.
새 Secret 준비 스크립트가 아직 서버에 없다면 push 전에 해당 파일만 먼저 전송한다.
Windows PowerShell에서 다음과 같이 임시 작업 경로에 복사할 수 있다.

```powershell
$k3sSshTarget = Read-Host 'K3s SSH 접속 주소 (사용자@호스트)'
ssh $k3sSshTarget 'mkdir -p /tmp/infisical-bootstrap/scripts'
scp 'C:\personal\k3s\scripts\prepare-infisical-secrets.sh' "${k3sSshTarget}:/tmp/infisical-bootstrap/scripts/"
```

이 경우 아래 Secret 준비 명령의 스크립트 경로만
`/tmp/infisical-bootstrap/scripts/prepare-infisical-secrets.sh`로 바꿔 실행한다.

- 대상 Kubernetes context와 기존 PostgreSQL의 정상 상태를 확인한다.
- `local-path` StorageClass와 Traefik의 Pod 라벨 `app.kubernetes.io/name=traefik`을 확인한다.
- 서버에 `kubectl`, `openssl`, `python3`, GNU `realpath`가 있어야 한다.
- 최초 설치 시 Ingress를 끄고 관리자 계정을 먼저 생성한다. 현재 values는 초기 관리자 생성 완료 후 `ingress.enabled: true`로 활성화한 상태다.

```bash
kubectl config current-context
kubectl -n data get pods,svc,pvc
kubectl get storageclass local-path
kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik
kubectl get namespace server
```

## 2. 전용 PostgreSQL DB와 사용자 생성

기존 PostgreSQL 관리자 계정으로 접속한다. 아래 Pod 이름은 현재 차트의 기본 이름이다.
실제 이름이 다르면 `kubectl -n data get pods` 결과에 맞춘다. 관리자 비밀번호는
프롬프트에 입력하고 명령 인자나 SQL 파일에 기록하지 않는다.

```bash
kubectl -n data exec -it postgresql-dev-primary-0 -- psql -h 127.0.0.1 -U postgres -d postgres -W
```

새 설치에 한해 psql에서 다음을 실행한다. `\password`에 입력한 비밀번호는 다음 단계의
Secret 준비 도구에서도 동일하게 입력한다. 기존 Infisical DB나 사용자가 있다면
비밀번호를 변경하거나 초기 키를 새로 만들지 말고 기존 자격 증명을 복구한다.

```sql
CREATE ROLE infisical LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
\password infisical
CREATE DATABASE infisical OWNER infisical;
\q
```

전용 사용자가 DB 소유자이므로 Infisical의 스키마·테이블 마이그레이션을 수행할 수 있다.
기존 `devdb` 또는 Harbor 계정을 공유하지 않는다.

## 3. 초기 Secret 준비

저장소 밖의 보호된 경로를 준비한다. 아래 경로는 예시이며, 민감 파일의 실제 보관 위치로
바꾼다. 새 하위 디렉터리를 지정해야 하며 이미 있는 Secret이나 백업 폴더는 덮어쓰지 않는다.

```bash
sudo install -d -m 0700 -o "$(id -u)" -g "$(id -g)" /secure/infisical
bash scripts/prepare-infisical-secrets.sh \
  --namespace server \
  --backup-dir /secure/infisical/initial \
  --apply
```

도구는 DB 비밀번호를 화면에 표시하지 않고 읽고, URI 특수문자를 인코딩한다.
암호화 키·인증 키·Redis 비밀번호를 새로 생성해 권한이 제한된 파일로 보관하고
`infisical-secrets`, `infisical-redis-auth`를 생성한다. 비밀값을 Git에 넣거나
Secret 전체 YAML을 로그에 출력하지 않는다.
기본 namespace는 `server`이고, Redis 주소는
`infisical-redis.server.svc.cluster.local:6379`로 생성된다.

`--apply` 없이 실행하면 파일만 만든다. 생성 중 일부 Secret 적용이 실패했거나
클러스터를 복구하는 경우 **새 키를 생성하지 말고 같은 파일**로 필요한 Secret만 생성한다.

```bash
backup=/secure/infisical/initial
kubectl -n server create secret generic infisical-redis-auth \
  --from-file="redis-password=$backup/redis-password"
kubectl -n server create secret generic infisical-secrets \
  --from-file="ENCRYPTION_KEY=$backup/ENCRYPTION_KEY" \
  --from-file="AUTH_SECRET=$backup/AUTH_SECRET" \
  --from-file="DB_CONNECTION_URI=$backup/DB_CONNECTION_URI" \
  --from-file="REDIS_URL=$backup/REDIS_URL" \
  --from-file="SITE_URL=$backup/SITE_URL"
```

이미 존재하는 Secret에는 위 `create` 명령이 실패한다. 복구 목적이라도 기존 정상
Secret을 삭제하지 말고 필요한 항목만 기존 값과 대조한 뒤 처리한다.

**DB 백업과 ENCRYPTION_KEY를 함께 서버 밖에 안전하게 보관한다.** DB만 복원하고
암호화 키를 잃으면 저장된 비밀값을 복호화할 수 없다. 초기 Secret을 Infisical 자신에게만
보관하면 복구 시 순환 의존이 생기므로 외부 보관본이 필요하다.

## 4. GitOps 배포와 최초 관리자 생성

DB와 Secret 준비가 끝나면 저장소 변경을 `main`에 push한다. 현재 운영 방식에서는
push 후 기존 GitOps가 ApplicationSet 변경과 서비스 생성·동기화를 자동으로 반영한다.
공식 차트는 매 렌더링마다 `updatedAt`을 변경하므로 ApplicationSet에 Infisical만
대상으로 하는 두 필드의 `ignoreDifferences`와 `RespectIgnoreDifferences=true`를 추가했다.
이 설정은 실제 이미지·설정 변경을 무시하지 않고 시간값 때문에 반복 재배포되는 것만 막는다.

```bash
kubectl -n server get applications infisical-redis-dev infisical-dev
kubectl -n server get pods,svc,pvc,serviceaccounts
kubectl -n server rollout status statefulset/infisical-redis --timeout=300s
kubectl -n server rollout status deployment/infisical --timeout=300s
kubectl -n server get application infisical-dev \
  -o jsonpath='{.spec.ignoreDifferences}{"\n"}{.spec.syncPolicy.syncOptions}{"\n"}'
```

마지막 출력에는 Deployment `infisical`, namespace `server`를 대상으로 하는 시간값
두 필드의 ignore 규칙과 `RespectIgnoreDifferences=true`가 있어야 한다. 없다면 서비스
values만 반영되고 ApplicationSet 자체의 변경이 아직 반영되지 않은 상태이므로
기존 GitOps에서 ApplicationSet 정의를 관리하는 경로의 동기화 상태를 확인한다.

두 Application의 최초 동기화 순서는 보장되지 않는다. Redis Application이 Infisical용
ServiceAccount도 생성하므로 Redis를 먼저 확인한다. Secret·DB·Redis가 준비된 뒤에도
Infisical이 Ready가 되지 않으면 애플리케이션 로그에서 DB 연결·마이그레이션 오류를 확인한다.

클러스터에 접근 가능한 컴퓨터에서 localhost로만 연결해 첫 관리자 계정을 만든다.
원격 SSH 서버에서 port-forward를 실행했다면 로컬 컴퓨터에서 SSH 터널도 연결한다.

```bash
kubectl -n server port-forward svc/infisical 8080:8080 --address 127.0.0.1
```

별도 터미널에서 `curl --fail http://127.0.0.1:8080/api/status`로 확인하고,
브라우저의 `http://localhost:8080`에서 최초 가입을 완료한다. 이 사용자가 인스턴스
관리자가 된다. 최초 부트스트랩 화면이 SITE_URL의 HTTPS로 이동한다면 SSH 터널과
임시 관리자 전용 Nginx 접근 제한을 사용해 같은 주소에서 완료하고 공개 범위를 넓힌다.

## 5. 도메인 공개

현재 `values/dev-values.yaml`의 `ingress.enabled`는 `true`다. 새로 설치하는 경우에는
최초 관리자 생성 후 이 값을 활성화한다.
`infisical.jaystacks.com` DNS와 인증서를 준비한 다음 기존 호스트 Nginx에 다음과 같은
서버 블록을 추가한다. 인증서 경로는 실제 발급 위치를 사용한다.

```nginx
server {
    listen 443 ssl;
    server_name infisical.jaystacks.com;
    ssl_certificate /etc/letsencrypt/live/infisical.jaystacks.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/infisical.jaystacks.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:30080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
    }
}
```

```bash
sudo nginx -t
# nginx -t 성공 후에만 실행한다.
sudo systemctl reload nginx
curl --fail --show-error https://infisical.jaystacks.com/api/status
```

내부 Pod가 Infisical API에 직접 접근하도록 설정할 때는 동반 Redis 차트의
`templates/networkpolicies.yaml`에서 Infisical 8080 ingress에 해당 namespace와 Pod만
추가한다. Redis는 같은 namespace의 Infisical Pod에서만 접근할 수 있다.

## 6. 보존·백업·업그레이드

Redis PVC는 StatefulSet 삭제·축소 시 `Retain`으로 유지된다. `local-path` PV의 reclaim
policy는 별도이므로 최초 바인딩 후 다음처럼 확인하고 보존한다.

```bash
pv=$(kubectl -n server get pvc data-infisical-redis-0 -o jsonpath='{.spec.volumeName}')
kubectl patch pv "$pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

단일 노드의 기존 PostgreSQL과 Redis를 사용하는 초기 구성이다. 실제 비밀값을 저장하기
전에 전용 DB dump·암호화 키·Redis AOF의 서버 밖 백업과 복원 시험을 준비한다.
PostgreSQL 기존 5Gi 볼륨의 여유 공간도 확인한다. Redis 인증값을 변경하면 관련 Secret
두 개를 함께 갱신하고 Redis와 Infisical을 재시작해야 한다.

차트·이미지 버전은 고정되어 있다. 업그레이드 전 DB 백업과 마이그레이션 호환성을
확인한다. DB 스키마 변경이 포함된 경우 이미지 버전만 되돌리는 것으로 복구되지 않을 수 있다.

공식 참고: [Kubernetes 설치](https://infisical.com/docs/self-hosting/deployment-options/kubernetes-helm),
[환경변수](https://infisical.com/docs/self-hosting/configuration/envars),
[Argo CD ignoreDifferences 동기화](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#respect-ignore-differences-configs).

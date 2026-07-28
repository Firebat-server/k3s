# Jay Blog K3s 배포 운영 런북

이 문서는 `jay-blog-fe`와 `jay-blog-be`를 운영 환경으로 전환하는 절차를
설명합니다. Argo CD는 각 애플리케이션의 `values/prod-values.yaml` 파일을
자동으로 감지하고 `product` 네임스페이스에 배포합니다.

## 배포 구성

```text
인터넷
  -> 호스트 Nginx (TLS 종료)
     -> WordPress 전용 경로는 기존 WordPress 업스트림으로 전달
     -> 나머지 jay-gemini.com 트래픽은 Traefik 127.0.0.1:30080으로 전달
        -> jay-blog-fe-prod.product.svc:80

api.jay-gemini.com
  -> 호스트 Nginx (TLS 종료)
     -> Traefik 127.0.0.1:30080
        -> jay-blog-be-prod.product.svc:80
```

ApplicationSet Image Updater가 사용하는 이미지 경로는 다음과 같습니다.

- `harbor.jay-gemini.com/library/jay-blog-fe:latest`
- `harbor.jay-gemini.com/library/jay-blog-be:latest`

레지스트리 비밀번호, 데이터베이스 비밀번호, API 키 또는 이러한 값의 Base64
인코딩 결과를 이 저장소에 커밋하면 안 됩니다.

Jenkins의 Kaniko Pod와 운영 FE Pod는 빌드 및 런타임에 공개
`https://jay-gemini.com/wp-json` 주소로 접근할 수 있어야 합니다. 클러스터의 DNS,
egress 또는 public-IP hairpin 정책이 이를 막는 경우 먼저 내부 WordPress Service
주소를 마련하고 FE의 두 WordPress 환경변수를 그 주소로 변경해야 합니다.

## 1. 네임스페이스와 이미지 가져오기 Secret 준비

Argo CD에 `CreateNamespace=true`가 설정되어 있지만, 최초 동기화 전에
네임스페이스를 생성하면 네임스페이스 범위의 Secret을 먼저 준비할 수 있습니다.

Harbor 인증 정보가 들어 있는 Docker config JSON 파일을 Git 외부의 안전한 경로에
저장하고 권한을 `0600`으로 설정합니다. 그다음 이미지 가져오기 Secret을 생성하거나
갱신합니다.

```bash
kubectl create namespace product --dry-run=client -o yaml \
  | kubectl apply -f -

kubectl -n product create secret generic harbor-creds \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=/secure/path/harbor-dockerconfig.json \
  --dry-run=client -o yaml \
  | kubectl apply -f -
```

Argo CD Image Updater가 사용하는 `server/harbor-creds` Secret은 위 Secret을
대체하지 않습니다. Kubernetes 이미지 가져오기 Secret은 네임스페이스 범위의
리소스이므로 `product/harbor-creds`가 별도로 필요합니다.

## 2. 백엔드 애플리케이션 Secret 준비

Git 외부에 각각의 Secret 값만 담은 파일 네 개를 만들고 권한을 `0600`으로
설정합니다. 해당 파일을 사용해 백엔드 Secret을 생성하거나 갱신합니다.
`jay-blog-be-secrets`에는 다음 네 개 키가 모두 있어야 합니다.

- `POSTGRES_PASSWORD`: PostgreSQL 접속 비밀번호
- `DART_API_KEY`: Open DART API 인증 키
- `KRX_ID`: pykrx가 KRX 데이터를 요청할 때 사용하는 계정 ID
- `KRX_PW`: pykrx가 KRX 데이터를 요청할 때 사용하는 계정 비밀번호

값 자체는 values 파일이나 이 저장소의 다른 파일에 기록하지 않습니다.

```bash
kubectl -n product create secret generic jay-blog-be-secrets \
  --from-file=POSTGRES_PASSWORD=/secure/path/jay-blog-postgres-password \
  --from-file=DART_API_KEY=/secure/path/jay-blog-dart-api-key \
  --from-file=KRX_ID=/secure/path/jay-blog-krx-id \
  --from-file=KRX_PW=/secure/path/jay-blog-krx-password \
  --dry-run=client -o yaml \
  | kubectl apply -f -

kubectl -n product describe secret harbor-creds
kubectl -n product describe secret jay-blog-be-secrets
```

`describe` 명령은 Secret 값을 출력하지 않고 키 이름과 크기를 확인할 수 있습니다.
출력의 `Data` 항목에 `POSTGRES_PASSWORD`, `DART_API_KEY`, `KRX_ID`, `KRX_PW`가
모두 표시되는지 확인합니다. 하나라도 빠지면 백엔드 배포 전에 Secret을 다시
생성해야 합니다.

백엔드는 프로세스 내부에서 스케줄러를 실행하므로 스케줄러를 CronJob으로 분리하거나
리더 선출을 적용하기 전까지 `replicaCount: 1`과 `Recreate` 전략을 유지해야 합니다.
OpenDartReader의 `/app/docs_cache`는 `emptyDir`에 저장되는 비영속 캐시입니다.
Pod를 다시 시작하면 캐시가 사라지고 애플리케이션이 필요한 데이터를 다시 생성합니다.

## 3. 병합 전 Helm 차트 검증

이 저장소의 루트에서 다음 명령을 실행합니다.

```bash
helm lint application-set/product/jay-blog-fe/chart \
  -f application-set/product/jay-blog-fe/values/commonValues.yaml \
  -f application-set/product/jay-blog-fe/values/prod-values.yaml \
  --set envName=prod

helm lint application-set/product/jay-blog-be/chart \
  -f application-set/product/jay-blog-be/values/commonValues.yaml \
  -f application-set/product/jay-blog-be/values/prod-values.yaml \
  --set envName=prod

helm template jay-blog-fe-prod application-set/product/jay-blog-fe/chart \
  --namespace product \
  -f application-set/product/jay-blog-fe/values/commonValues.yaml \
  -f application-set/product/jay-blog-fe/values/prod-values.yaml \
  --set envName=prod > /tmp/jay-blog-fe-prod.yaml

helm template jay-blog-be-prod application-set/product/jay-blog-be/chart \
  --namespace product \
  -f application-set/product/jay-blog-be/values/commonValues.yaml \
  -f application-set/product/jay-blog-be/values/prod-values.yaml \
  --set envName=prod > /tmp/jay-blog-be-prod.yaml

kubectl apply --dry-run=server -f /tmp/jay-blog-fe-prod.yaml
kubectl apply --dry-run=server -f /tmp/jay-blog-be-prod.yaml
```

클러스터 연결이 가능하면 병합 전에 임시 Pod에서도 WordPress 경로를 확인합니다.

```bash
kubectl -n product run jay-blog-wp-connectivity-check \
  --rm -i --restart=Never --image=curlimages/curl:latest -- \
  --fail --show-error \
  'https://jay-gemini.com/wp-json/wp/v2/posts?per_page=1'
```

## 4. WordPress 중단 없이 호스트 Nginx 전환

`jay-gemini.com`의 WordPress API, 미디어 및 관리 경로는 계속 기존 WordPress가
처리합니다. 호스트 Nginx 설정에서는 아래 경로를 전체 프론트엔드 요청을 처리하는
`location /`보다 **앞에** 선언하고 기존 WordPress 업스트림으로 전달해야 합니다.

```nginx
# 각 경로에서 기존 WordPress proxy_pass/업스트림을 그대로 유지합니다.
location = /wp-json      { proxy_pass http://wordpress_legacy; }
location ^~ /wp-json/    { proxy_pass http://wordpress_legacy; }
location = /wp-content   { proxy_pass http://wordpress_legacy; }
location ^~ /wp-content/ { proxy_pass http://wordpress_legacy; }
location = /wp-admin     { proxy_pass http://wordpress_legacy; }
location ^~ /wp-admin/   { proxy_pass http://wordpress_legacy; }
location = /wp-login.php { proxy_pass http://wordpress_legacy; }

# 나머지 최상위 도메인 트래픽만 Next.js 프론트엔드로 전달합니다.
location / {
    proxy_pass http://127.0.0.1:30080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

위 예시의 `wordpress_legacy`는 설명을 위한 이름입니다. 현재 실행 중인 WordPress가
사용하는 실제 업스트림을 그대로 유지해야 합니다. 한 줄로 표시한 WordPress
`location`은 라우팅 우선순위만 보여주므로 실제 설정에서는 기존 전달 헤더,
타임아웃 및 요청 본문 크기 설정도 유지합니다. `/wp-includes/`, `/wp-cron.php`,
`/xmlrpc.php`처럼 현재 사용 중인 WordPress 경로가 더 있다면 함께 보존해야 합니다.
전환 과정에서 현재 WordPress 포트를 추측하거나 임의로 바꾸지 마십시오.

`api.jay-gemini.com`은 별도의 TLS 가상 호스트로 구성하고 `/` 경로를 동일한 전달
헤더와 함께 `http://127.0.0.1:30080`으로 프록시합니다. 트래픽을 전환하기 전에
DNS 레코드와 인증서를 생성하거나 기존 설정이 유효한지 확인합니다. Nginx를 다시
불러오기 전에는 항상 다음 순서로 설정을 검증합니다.

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 5. Argo CD 상태 및 롤아웃 확인

K3s 저장소 변경 사항을 병합하고 푸시한 뒤 다음 명령으로 상태를 확인합니다.

```bash
kubectl -n server get application jay-blog-fe-prod jay-blog-be-prod -o wide
kubectl -n server describe application jay-blog-fe-prod
kubectl -n server describe application jay-blog-be-prod

kubectl -n product rollout status deployment/jay-blog-fe-prod --timeout=5m
kubectl -n product rollout status deployment/jay-blog-be-prod --timeout=5m
kubectl -n product get pod,service,ingress -o wide

curl --fail --show-error 'https://jay-gemini.com/api/health'
curl --fail --show-error 'https://jay-gemini.com/wp-json/wp/v2/posts?per_page=1'
curl --fail --show-error 'https://api.jay-gemini.com/health/live'
curl --fail --show-error 'https://api.jay-gemini.com/health/ready'
```

최상위 도메인 전환이 완료되었다고 판단하기 전에 `/wp-content/` 아래의 WordPress
이미지 URL과 `/wp-admin/` 화면을 모두 직접 확인합니다.

## 6. 롤백

가장 빠르게 트래픽을 롤백하려면 호스트 Nginx의 최상위 `location /` 업스트림을
이전 설정으로 복원하고 `nginx -t`를 실행한 뒤 Nginx를 다시 불러옵니다. 이 방식은
사용자 트래픽을 기존 서비스로 되돌리면서 K3s 워크로드는 장애 분석을 위해 실행
상태로 유지합니다.

GitOps 배포를 롤백하려면 K3s 배포 커밋을 되돌리고 해당 되돌림 커밋을 푸시합니다.
그러면 Argo CD 자동 동기화가 클러스터를 되돌린 원하는 상태에 맞게 조정합니다.
Argo CD 자동 복구가 명령형 변경을 덮어쓸 수 있으므로 `kubectl rollout undo`보다
Git 커밋 되돌리기를 우선합니다. 이미지에만 문제가 있다면 마지막으로 검증된 불변
이미지를 다시 게시하고 정상적인 이미지 업데이트 절차를 통해 추적 중인 이미지와
태그를 갱신합니다.

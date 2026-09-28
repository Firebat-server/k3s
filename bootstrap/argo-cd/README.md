# 🛠 ApplicationSet 템플릿 유지보수 가이드

이 문서는 `application-set.yaml` 파일의 동작 원리를 설명하고, 추후 멀티 클러스터(Multi-Cluster) 환경으로 확장 시 수정해야 할 지점을 안내합니다.

> ⚠️ **주의**: 이 ApplicationSet은 **Go Template**을 사용하여 다수의 애플리케이션을 동적으로 생성하므로, 수정 시 문법에 각별히 주의해야 합니다.

## 도메인 전환 시 Argo CD 우선 적용

새 접속 주소는 `https://argocd.jaystacks.com`이다. Ingress의 hostname과
`global.domain`을 함께 설정하여 Argo CD의 외부 URL도 같은 주소를 사용한다.

### 1. 서버의 DNS 및 TLS 준비

- `argocd.jaystacks.com`의 DNS를 기존 서버로 연결한다.
- 호스트 Nginx의 `server_name`과 인증서를 새 도메인에 맞춘다. 기존 도메인의
  인증서는 새 도메인에 사용할 수 없으므로 새 인증서를 발급/설정한다.
- 기존 구조대로 Nginx에서 TLS를 종료하고 `127.0.0.1:30080`으로 전달한다.
  `Host` 및 `X-Forwarded-Proto` 헤더를 유지한다. [라우팅 예시](../../docs/nginx-routing.md)를 참고한다.
- Nginx 설정 변경 후 `sudo nginx -t`가 성공하면 `sudo systemctl reload nginx`를 실행한다.

### 2. Argo CD bootstrap 적용

변경된 파일을 서버에 가져온 다음 저장소 루트에서 실행한다. 기존 Helm release 이름이
`argocd`, namespace가 `server`인 구성을 기준으로 한다.

```bash
helm dependency build ./bootstrap/argo-cd/chart

helm upgrade --install argocd \
  ./bootstrap/argo-cd/chart \
  -n server \
  --create-namespace \
  -f ./bootstrap/argo-cd/values/dev-values.yaml

kubectl -n server rollout status deployment/argocd-server
kubectl -n server get ingress argocd-server
kubectl -n server get configmap argocd-cm -o jsonpath='{.data.url}{"\n"}'
curl --fail --show-error https://argocd.jaystacks.com/healthz
```

Ingress host는 `argocd.jaystacks.com`, ConfigMap의 URL은
`https://argocd.jaystacks.com`이어야 한다. Image Updater도 새 Harbor 주소를 사용하므로
아래 Harbor 전환과 `server/harbor-creds` 갱신이 완료되어야 이미지 조회가 정상화된다.

### 3. 서비스 동기화 전 확인

ApplicationSet은 `Firebat-server/k3s`의 `main`을 읽고 자동 동기화한다.
**이미 ApplicationSet이 설치되어 있다면 변경 사항을 `main`에 push하는 것만으로
서비스 전환이 시작될 수 있다.** Argo CD만 먼저 적용하려면 변경 파일을 서버에 복사해
위 Helm 명령만 실행하고, 서비스 전환 준비를 마친 뒤 `main`에 반영한다.

- 사용하는 나머지 도메인의 DNS, Nginx `server_name`, TLS 인증서를 준비한다.
- Harbor는 동일한 저장소/데이터를 유지하면서 `harbor.jaystacks.com`으로 전환한다.
  이 저장소는 Ingress host와 `externalURL`을 함께 변경한다. Harbor가 새 주소에서
  정상 응답한 뒤 애플리케이션의 이미지 가져오기를 확인한다. 자동 동기화에는
  Harbor가 먼저 준비된다는 보장이 없으므로 전환 중 이미지 가져오기가 실패하면
  Harbor 준비 후 해당 앱의 상태를 다시 확인한다.
- Docker config JSON의 `auths`에 `harbor.jaystacks.com` 인증 항목을 넣어
  `server/harbor-creds`와 `product/harbor-creds`를 갱신한다. Secret 이름은 유지한다.
  다른 namespace에서도 Harbor 이미지를 사용한다면 해당 인증 정보도 갱신한다.
  [Secret 적용 예시](../../application-set/product/jay-blog-README.md#1-네임스페이스와-이미지-가져오기-secret-준비)를 참고한다.
- 노드의 `/etc/rancher/k3s/registries.yaml`, Jenkins의 이미지 push 주소/인증,
  Git webhook, WordPress 사이트 URL에 기존 주소가 남아 있다면 서버 및 해당 서비스에서
  변경한다. 프런트엔드 이미지에 API 주소가 빌드 시 포함된다면 새 주소로 다시 빌드한다.
- `charts-deploy-values`는 별도 저장소다. 특히 `nolji-frontend`의
  `cicd-auto-values/prod-values.yaml`은 이 저장소의 values보다 나중에 적용되므로
  이미지 주소를 덮어쓰는 설정이 있다면 함께 변경한다.

준비된 변경 사항이 `main`에 반영된 후 ApplicationSet을 적용한다.

```bash
kubectl apply -n server -f ./bootstrap/argo-cd/application-set.yaml
kubectl -n server get applications
kubectl get ingress -A
```

`devvalues.yaml`/`prodvalues.yaml` 이름을 사용하는 기존 Sunsun/Ollama 파일은 현재
ApplicationSet의 `*-values.yaml` 패턴에 포함되지 않는다. 해당 파일의 도메인은
변경했지만, 이번 변경에서는 파일명을 유지하므로 기존 배포 방식으로 별도 적용한다.

---

## 1. 동작 원리 (Architecture)

### 📁 파일 감지 및 변수 매핑 (Git Generator)

Git Generator가 아래 경로 패턴에 맞는 파일을 감지하면 `Application`을 생성합니다.

```yaml
files:
  - path: "application-set/*/*/values/*-*-values.yaml"
```

경로에 따라 다음과 같이 변수가 매핑됩니다 (`.path.segments`):

| 인덱스       | 의미          | 예시 값           | 템플릿 변수              |
| :----------- | :------------ | :---------------- | :----------------------- |
| **0**        | 루트 디렉토리 | `application-set` | `index .path.segments 0` |
| **1**        | Namespace     | `server`, `data`  | `index .path.segments 1` |
| **2**        | App Name      | `jenkins`         | `index .path.segments 2` |
| **filename** | 환경/클러스터 | `dev-values.yaml` | `.path.filename`         |

### 🔄 차트 소스 결정 로직 (Dynamic Source)

`values.yaml` 파일 내부에 `chartConfig` 값 존재 여부에 따라 차트 소스가 결정됩니다.

- **외부/공용 차트**: `chartConfig`가 있으면 해당 `repoURL` 사용
- **로컬 차트**: 없으면 자동으로 `application-set/<ns>/<app>/chart` 경로를 바라봄

---

## 2. 🚀 [중요] 멀티 클러스터 확장 가이드 (Destination)

현재 `destination` 설정은 ArgoCD가 설치된 클러스터(**in-cluster**)로 고정되어 있습니다.

```yaml
destination:
  server: [https://kubernetes.default.svc](https://kubernetes.default.svc)
```

EKS, GKE, On-Premise 등 환경별로 배포 위치를 다르게 하려면 아래 예시 중 하나를 선택하여 `spec.template.spec.destination` 부분을 수정하세요.

### 방법 A: 파일명 키워드로 분기 (추천)

파일명(예: `dev-values.yaml`)에 포함된 단어를 기준으로 API 서버 주소를 매핑합니다.

```yaml
destination:
  server: >-
    {{- if contains "eks" .path.filename -}}
      https://<YOUR-API-URL>
    {{- else if contains "gke" .path.filename -}}
      https://<YOUR-GKE-API-URL>
    {{- else -}}
      [https://kubernetes.default.svc](https://kubernetes.default.svc)  # 기본값 (Local)
    {{- end -}}
  namespace: "{{ index .path.segments 1 }}"
```

### 방법 B: 환경(Dev/Prod) 기준으로 분기

개발계와 운영계 클러스터가 명확히 분리되어 있을 때 사용합니다.

```yaml
destination:
  server: >-
    {{- if contains "prod" .path.filename -}}
      [https://api.production.example.com](https://api.production.example.com)
    {{- else -}}
      [https://api.dev.example.com](https://api.dev.example.com)
    {{- end -}}
  namespace: "{{ index .path.segments 1 }}"
```

### 방법 C: ArgoCD 등록 이름(Cluster Name) 사용

ArgoCD에 클러스터를 `dev`, `gke-prod`와 같은 이름으로 미리 등록했다면, URL 대신 `name` 필드를 사용할 수 있습니다.

```yaml
destination:
  # 예: 파일명이 "dev-values.yaml" -> 클러스터 이름 "dev"로 배포
  name: '{{ .path.filename | replace "-values.yaml" "" }}'
  namespace: "{{ index .path.segments 1 }}"
```

---

## 3. 주의사항 (Caveats)

- **Go Template 문법**: `{{- ... -}}` (대시 포함)은 템플릿 렌더링 시 발생하는 불필요한 공백과 개행을 제거합니다. YAML 인덴트가 깨지지 않도록 주의하세요.
- **IgnoreMissingValueFiles**: `common-values.yaml` 등의 공통 파일이 없는 경우에도 에러가 발생하지 않도록 설정되어 있습니다. 만약 공통 설정이 적용되지 않는다면 파일 경로 오타를 확인하세요.
- **Application 이름 중복 방지**: Application 이름은 `{{앱이름}}-{{파일명ID}}` 형식으로 생성되어 유니크함을 보장합니다. (예: `user-api-dev`)

---

## 4. 적용 방법 (How to Apply)

ApplicationSet은 ArgoCD가 설치된 Namespace에 적용해야 합니다.

### 기본 적용 명령어

```bash
# ArgoCD가 'server' 네임스페이스에 설치된 경우
kubectl apply -f application-set.yaml -n server
```

### 특정 네임스페이스에 적용 (사용자 환경)

만약 ArgoCD 컨트롤러가 `server` 네임스페이스 등 다른 곳에 있다면 해당 네임스페이스를 지정하세요.

```bash
# Windows PowerShell 예시
kubectl apply -f .\application-set.yaml -n server
```

### 정상 등록 확인

```bash
# ApplicationSet 리소스 확인
kubectl get appset -n server
```

### Private Git Repo 인증 추가

`charts-deploy-values` 같은 private Git repo를 `sources`에 추가했다면, ArgoCD가 읽을 수 있도록 `repo-creds` Secret을 먼저 생성해야 합니다.

```bash
kubectl create secret generic argocd-repo-creds-firebat \
  -n server \
  --from-literal=url=https://github.com/Firebat-server \
  --from-literal=username='<GITHUB_USERNAME>' \
  --from-literal=password='<GITHUB_PAT>' \
  --dry-run=client -o yaml \
  | kubectl label -f - argocd.argoproj.io/secret-type=repo-creds --local -o yaml \
  | kubectl apply -f -
```

---

## 5. 🐞 디버깅 가이드 (Debugging Guide)

ApplicationSet을 적용했으나 `Application`이 생성되지 않거나 에러가 발생할 때 확인하는 순서입니다.

### 1단계: ApplicationSet 이벤트 확인 (가장 중요)

템플릿 문법 오류나 Generator 설정 오류는 대부분 여기서 확인 가능합니다.

```bash
# 에러 메시지 확인 (Events 섹션 확인)
kubectl describe appset application-set -n server
```

> **체크 포인트**: `Events` 항목에 `Error`나 `Warning`이 있는지 확인하세요. 문법 에러가 있다면 구체적인 라인 위치가 나옵니다.

### 2단계: 생성된 Application 확인

ApplicationSet 자체는 정상이나, 생성된 개별 Application이 동기화(Sync)되지 않는 경우입니다.

```bash
# 이 AppSet에 의해 생성된 앱 목록 조회
kubectl get application -n server -l app.kubernetes.io/instance=application-set
```

- 목록이 비어있다면? 👉 **Git Generator 경로 패턴**이 실제 Git 저장소 구조와 일치하는지 확인하세요.
- 목록은 있지만 상태가 Unknown/Error라면? 👉 `kubectl describe application <앱이름> -n server`로 개별 앱의 에러를 확인하세요.

### 3단계: 템플릿 렌더링 로그 확인 (ArgoCD Controller)

더 상세한 로그가 필요한 경우 ArgoCD Application Controller의 로그를 확인합니다.

```bash
kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n server --tail=100
```

# ApplicationSet 개발자 가이드!

이 디렉토리는 ArgoCD ApplicationSet을 통해 배포되는 애플리케이션들을 관리합니다. \
유연한 배포 전략을 위해 세 가지 방식의 Helm 차트 정의 방법을 지원합니다.

애플리케이션의 특성에 따라 아래 세 가지 패턴 중 하나를 선택하여 구성해 주세요.

## 디렉토리 구조 개요

`application-set/` 하위의 모든 애플리케이션은 기본적으로 다음과 같은 구조를 따릅니다.

```text
application-set/
├── <namespace> (예: product, server, data)
│   └── <app-name>
│       ├── chart/   (선택 사항: 단독 로컬 차트 사용 시에만 생성)
│       └── values/
│           ├── commonvalues.yaml       (모든 환경 공통 설정)
│           └── <env>-values.yaml (환경별 개별 설정)
```

---

## 1. 공용 커스텀 차트 활용

애플리케이션이 표준 아키텍처(예: Spring Boot API 서버)를 따르며, \
중앙에서 관리되는 `springboot-docker`와 같은 라이브러리 차트를 사용할 때 이 방식을 사용합니다.

**예시:** `sunsun-be` (공용 `springboot-docker` 차트 사용)

### 설정 방법:

1. `application-set/<namespace>/<app-name>/values/` 디렉토리를 생성합니다.
2. **`chart/` 폴더는 생성하지 않습니다.**
3. 환경별 설정 파일(예: `dev-values.yaml`)의 최상단에 공용 차트 경로를 지정하는 `chartConfig` 블록을 추가합니다.

### 설정 예시 (`values/dev-values.yaml`):

```yaml
# 이 저장소 내의 공용 차트 경로 지정
chartConfig:
  path: springboot-docker/springboot-docker

# 해당 앱에서 필요한 설정만 오버라이드
image:
  repository: docker-image-registry/my-app
  tag: "latest"

ingress:
  enabled: true
  # ...
```

---

## 2. 외부 Public 차트 활용

Jenkins, PostgreSQL 등 공식 Helm 레포지토리에서 제공하는 외부 차트를 직접 배포할 때 사용합니다.

**예시:** `jenkins`

### 설정 방법:

1. `application-set/<namespace>/<app-name>/values/` 디렉토리를 생성합니다.
2. **`chart/` 폴더는 생성하지 않습니다.**
3. 환경별 설정 파일에 `repoURL`, `chart` 이름, `targetRevision`을 포함한 `chartConfig`를 추가합니다.

### 설정 예시 (`values/dev-values.yaml`):

```yaml
# 외부 Helm 레포지토리 정보 설정
chartConfig:
  repoURL: https://charts.jenkins.io
  chart: jenkins
  targetRevision: 4.3.23

# 외부 차트의 values.yaml 구조에 맞게 설정 작성
controller:
  serviceType: ClusterIP
  installPlugins:
    - kubernetes:3909.v8fdb_62373a_35
```

---

## 3. 단독 로컬 차트 직접 생성

프론트엔드 앱의 특수한 Nginx 설정이나 복잡한 StatefulSet 등, 공용 차트나 외부 차트로 대응이 불가능한 독자적인 차트 구조가 필요할 때 사용합니다.

**예시:** `sunsun-fe`

### 설정 방법:

1. `application-set/<namespace>/<app-name>/` 하위에 `chart/` 폴더를 생성합니다.
2. `chart/` 폴더 안에 `Chart.yaml`, `templates/` 등을 생성 및 작성합니다.
3. `values/` 폴더를 생성하여 설정 파일들을 넣습니다.
4. **`chartConfig`를 작성하지 않습니다.** `chartConfig`가 없으면 시스템은 자동으로 같은 경로의 `chart/` 폴더를 차트로 인식합니다.

### 디렉토리 레이아웃:

```text
my-app/
├── chart/
│   ├── Chart.yaml
│   ├── templates/
│   └── values.yaml (기본값)
└── values/
    ├── commonvalues.yaml
    └── dev-values.yaml (chartConfig 필요 없음)
```

---

## Values 파일 명명 규칙 및 역할

ApplicationSet 제너레이터는 `values/` 폴더 내에서 `*-values.yaml` 패턴을 가진 파일을 자동으로 감지합니다.

- **`commonvalues.yaml`**: 모든 환경(dev, prod 등)에서 공통으로 사용할 값들을 정의합니다. (예: 서비스 포트, 리소스 요청량, 헬스 체크 경로 등)
- **`<env>-values.yaml`** (예: `dev-values.yaml`, `prod-values.yaml`): 특정 환경에만 적용될 값을 정의합니다. (예: 호스트 주소, 레플리카 수, 외부 시크릿 참조 등)

> **주의:** `chartConfig` 블록은 `commonvalues.yaml`이 아닌, 각 환경별 개별 설정 파일의 최상단에 위치해야 합니다.

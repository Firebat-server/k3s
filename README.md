# k3s

ArgoCD를 통해 k3s에 배포되는 helm chart 저장소입니다.

# 폴더 구조

- `application-set`: 실제 서비스/애플리케이션 배포용 Helm chart 및 Argo CD Application 정의(워크로드 레벨).
- `bootstrap`: 클러스터 초기 구성용 chart/리소스(Argo CD, External Secrets 등) 모음.
- `custum-chart`: credos 내부에서 공통으로 활용할 커스텀 chart 모음.

```
.
├── application-set
│   ├─── <namespace> (예: product, server, data)
│   │    └── <app-name>
│   │       ├── chart/   (선택 사항: 단독 로컬 차트 사용 시에만 생성)
│   │       └───── values/
│   │          ├── commonvalues.yaml (모든 환경 공통 설정)
│   │          └── <env>-values.yaml (환경별 개별 설정)
│   └── ...
├── bootstrap
│   ├── argocd
│   └── external-secrets
└── custom-chart
```

# EKS 부트스트랩 (bootstrap)

EKS 클러스터가 준비된 뒤, 아래 순서로 기본 구성요소를 설치합니다.

1. External Secrets 설치

   ```bash
   helm upgrade external-secrets \
   ./bootstrap/external-secrets/charts/external-secrets \
   -n external-secrets \
   --create-namespace \
   --install
   ```

2. EKS용 ClusterSecretStore 적용

   ```bash
   kubectl apply -f bootstrap/external-secrets/service-store/eks.yaml
   ```

3. Argo CD용 레포지토리 ExternalSecret 적용

   ```bash
   kubectl apply -f bootstrap/argocd/secrets/argocd-repo-credos-charts.yaml
   ```

4. Argo CD 설치

   ```bash
   helm upgrade --install argocd \
   argo/argo-cd \
   -n server \
   --create-namespace \
   -f ./bootstrap/argo-cd/values/dev-values.yaml
   ```

# 🛠 ApplicationSet

### [개발 매뉴얼 보러가기](application-set/README.md)

단일 Manifest로 멀티 클러스터 및 다중 마이크로서비스 배포를 제어하기 위해 ApplicationSet을 적용. \
Git 레포지토리의 변경 사항을 감지하여 동적으로 `Application` 리소스를 생성하며, 새로운 서비스 추가 시 별도의 파이프라인 수정 없이 즉시 배포가 가능함.

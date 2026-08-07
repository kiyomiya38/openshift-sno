# 09. サンプルアプリ

```bash
bash scripts/07-deploy-sample-app.sh
oc -n sample-app get deploy,pod,svc,route
oc -n sample-app logs deployment/hello-openshift
```

Deployment が Pod を管理し、Service が安定した内部宛先、OpenShift 固有の Route が router 経由の外部 URL を提供します。Ingress と目的は似ますが、Route は OpenShift API です。公開・認証不要のサンプルイメージは、Quayで存在を確認した`4.16.0`のマニフェストダイジェストで固定しています。サンプルイメージの版はOCPクラスターバージョンとは独立しています。削除は `oc delete namespace sample-app` です。

次: [コスト](10-cost-management.md)

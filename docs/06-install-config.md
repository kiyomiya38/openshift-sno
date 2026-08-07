# 06. install-config.yaml

`compute.replicas: 0` と `controlPlane.replicas: 1` が SNO を成立させ、master を schedulable にします。`OVNKubernetes` は SNO で必須です。`platform.aws.region` は大阪、`publish: External` は public cluster、control-plane type/rootVolume は EC2/EBS 仕様です。

```bash
bash scripts/04-create-install-config.sh
chmod 600 "$INSTALL_DIR/install-config.yaml" "$INSTALL_DIR/install-config.yaml.backup"
```

インストーラーは作成中に `install-config.yaml` を消費するため、スクリプトは backup を作ります。両方に Pull Secret と SSH 公開鍵が含まれ、Git 管理・共有は禁止です。テンプレートは `envsubst` し、秘密値はファイルから読みます。

```bash
openshift-install explain installconfig
```

対象版で正式な field だけを使うため、必要なら上記 schema と Red Hat 4.21 AWS customization を照合します。次: [インストール](07-installation.md)


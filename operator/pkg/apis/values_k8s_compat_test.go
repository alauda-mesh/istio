package apis_test

import (
	"testing"

	"istio.io/istio/operator/pkg/apis"
	"istio.io/istio/pkg/util/protomarshal"
)

// 复现 istiod 启动崩溃：k8s.io/api v0.35 默认构建不再提供 ProtoMessage() 方法，
// protobuf 运行时懒加载 Values 描述符解析 k8s 类型字段（如 Affinity）时 panic。
// 期望：ApplyYAML 正常完成，不发生 panic。
func TestValuesApplyYAMLWithK8sAffinity(t *testing.T) {
	yaml := `
cni:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: kubernetes.io/os
            operator: In
            values:
            - linux
`
	v := &apis.Values{}
	if err := protomarshal.ApplyYAML(yaml, v); err != nil {
		t.Fatalf("ApplyYAML 失败: %v", err)
	}
	if v.Cni == nil || v.Cni.Affinity == nil {
		t.Fatalf("affinity 未解析出来: %+v", v.Cni)
	}
}

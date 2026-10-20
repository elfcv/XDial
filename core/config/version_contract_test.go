package config

import (
	"encoding/json"
	"strings"
	"testing"
)

// 便携 Profile 文档会在版本之间流转：导出文件、订阅和预置配置包里的文档都会被其他版本
// 导入。导出方写的 xdial.schema_version 不能超过旧版本的读取上限。这些值由各版本共用
// （D22），完整清单和纳入标准见 test/version_constants_test.py。
func TestProfileDocumentSchemaVersionsArePinned(t *testing.T) {
	const policy = "改这些值必须先在 main 上演进并处理旧版本兼容，不能只在 beta 分支改"
	// 导出后再导入：读取方必须接受写入方产出的版本。
	schemaVersion := func(t *testing.T, profile *Profile) int {
		t.Helper()
		encoded, err := ExportProfileDocument(profile)
		if err != nil {
			t.Fatal(err)
		}
		var document ProfileDocument
		if err := json.Unmarshal(encoded, &document); err != nil {
			t.Fatal(err)
		}
		if _, err := ImportProfileDocument(encoded, "copy"); err != nil {
			t.Fatalf("exported schema_version %d was not importable: %v; %s", document.XDial.SchemaVersion, err, policy)
		}
		return document.XDial.SchemaVersion
	}

	full, err := ImportProfileDocument([]byte(profileDocumentFixture), "source")
	if err != nil {
		t.Fatal(err)
	}
	if got := schemaVersion(t, full); got != 1 {
		t.Fatalf("full document schema_version = %d, want 1; %s", got, policy)
	}
	resources := &Profile{ID: "resources", Lines: []Line{{ID: "direct", Name: "Direct", Type: LineTypeDirect, Enabled: true}}, RuleSets: []RuleSet{{ID: "rule", Name: "Domains", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"example.test"}}}}
	if got := schemaVersion(t, resources); got != 2 {
		t.Fatalf("resources-only document schema_version = %d, want 2; %s", got, policy)
	}

	newer := strings.Replace(profileDocumentFixture, `"outbounds":[`, `"xdial":{"schema_version":3},"outbounds":[`, 1)
	if _, err := ImportProfileDocument([]byte(newer), "newer"); err == nil || !strings.Contains(err.Error(), "unsupported XDial schema version") {
		t.Fatalf("schema_version 3 must be rejected as unsupported, got %v; %s", err, policy)
	}
}

// 运行配置指纹随连接报告写进 App Group。之后的构建（或共用身份的另一通道）接管运行中的
// 连接时，拿它和自己现算的指纹做相等比较；前缀是指纹算法的版本，改了它，接管后的连接会被
// 误判为有未应用的改动。这个前缀由各版本共用（D22），完整清单和纳入标准见
// test/version_constants_test.py。
func TestRuntimeConfigurationFingerprintPrefixIsPinned(t *testing.T) {
	const (
		prefix = "runtime-v1:"
		policy = "改这些值必须先在 main 上演进并处理旧版本兼容，不能只在 beta 分支改"
	)
	plan, err := BuildConnectionPlan(runtimeFingerprintTestProfile())
	if err != nil {
		t.Fatal(err)
	}
	fingerprint := plan.ConfigurationFingerprint
	if !strings.HasPrefix(fingerprint, prefix) || len(fingerprint) != len(prefix)+64 {
		t.Fatalf("configuration fingerprint = %q, want %q followed by a SHA-256 digest; %s", fingerprint, prefix, policy)
	}
}

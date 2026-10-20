//go:build !windows

package libbox

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/kafeifei/xdial/core/config"
)

// 文本规则集转换出的 sing-box 源规则集缓存在共享 App Group 的 xdial-rule-sets 里，缓存
// 路径不含版本，共用 App Group 的其他版本会直接读取并校验。读取方的 sing-box 拒绝它不认识
// 的版本：缓存失效后，离线或拉取失败时连接报 rule-set-unavailable。这个版本号由各版本共用
// （D22），完整清单和纳入标准见 test/version_constants_test.py。
func TestSourceRuleSetVersionIsPinned(t *testing.T) {
	const policy = "改这些值必须先在 main 上演进并处理旧版本兼容，不能只在 beta 分支改"
	converted, err := convertTextRuleSet([]byte("example.com\n"))
	if err != nil {
		t.Fatal(err)
	}
	var document struct {
		Version int `json:"version"`
	}
	if err := json.Unmarshal(converted, &document); err != nil {
		t.Fatal(err)
	}
	if document.Version != 3 {
		t.Fatalf("converted source rule set version = %d, want 3; %s", document.Version, policy)
	}

	// 另一个版本按同一个缓存路径读回，必须通过校验。
	localPath := neRuleSetCachePath(
		filepath.Join(t.TempDir(), "xdial-rule-sets"), "profile", "plain",
		"https://rules.example.com/list.txt", "text", "source",
	)
	if err := writeNERuleSetCache(localPath, converted); err != nil {
		t.Fatal(err)
	}
	if _, kind, _, err := readValidatedNERuleSet(localPath, "source", maxNERuleSetBytes); err != nil || kind != config.RuleSetMatchDomain {
		t.Fatalf("cached version 3 rule set was not readable: kind=%v err=%v; %s", kind, err, policy)
	}

	// 读取方不认识的版本会让缓存失效。
	unknown := bytes.Replace(converted, []byte(`"version":3`), []byte(`"version":99`), 1)
	if bytes.Equal(unknown, converted) {
		t.Fatalf("converted rule set has no version field to replace: %s", converted)
	}
	if err := writeNERuleSetCache(localPath, unknown); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := readValidatedNERuleSet(localPath, "source", maxNERuleSetBytes); err == nil {
		t.Fatalf("cached rule set with an unknown version was accepted; %s", policy)
	}
}

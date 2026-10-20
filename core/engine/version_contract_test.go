package engine

import (
	"context"
	"os"
	"testing"
)

// dns-takeover.json 由 root helper 写下，下一个 helper 进程（可能是另一个版本、另一个
// 通道）启动时据此自愈系统 DNS。正式版、beta 与 Debug 共用这个版本号（D22），完整清单
// 和纳入标准见 test/version_constants_test.py。
func TestDNSTakeoverStateVersionIsPinned(t *testing.T) {
	const policy = "改这些值必须先在 main 上演进并处理旧版本兼容，不能只在 beta 分支改"
	runner := newFakeDNSRunner("Wi-Fi")
	runner.current["Wi-Fi"] = "1.1.1.1"
	takeover := newTestTakeover(t, runner)
	if err := takeover.Takeover(); err != nil {
		t.Fatalf("Takeover: %v", err)
	}
	if state := assertHasState(t, takeover); state.Version != 1 {
		t.Fatalf("dns-takeover.json written with version %d, want 1; %s", state.Version, policy)
	}

	liveServices := func() ([]string, []string, error) { return []string{"Wi-Fi"}, []string{"Wi-Fi"}, nil }
	for _, testCase := range []struct {
		name    string
		content string
	}{
		// 最早的状态文件没有 version 字段，读取方按 1 处理。
		{name: "legacy file without version", content: `{"services":[{"service":"Wi-Fi","servers":["1.1.1.1"]}]}`},
		// 内容不可用时改走 DHCP 兜底，兜底状态同样记为 1。
		{name: "unusable file", content: "{ truncated"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if err := os.WriteFile(takeover.statePath(), []byte(testCase.content), 0o600); err != nil {
				t.Fatal(err)
			}
			takeover.mu.Lock()
			state, err := takeover.restoreTargets(context.Background(), liveServices)
			takeover.mu.Unlock()
			if err != nil {
				t.Fatalf("restoreTargets: %v", err)
			}
			if state.Version != 1 {
				t.Fatalf("restore target version = %d, want 1; %s", state.Version, policy)
			}
		})
	}
}

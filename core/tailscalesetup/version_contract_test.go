package tailscalesetup

import (
	"os"
	"path/filepath"
	"testing"
)

// 迁移标记放在正式版与 beta 共用的 App Group 里：另一版本写下的标记必须被认出，否则
// 已迁移的 Tailscale 身份会被再迁一次。这个文件名由各版本共用（D22），完整清单和纳入
// 标准见 test/version_constants_test.py。
func TestMigrationMarkerNameIsPinned(t *testing.T) {
	const (
		marker = ".xdial-tailscale-state-v1"
		policy = "改这些值必须先在 main 上演进并处理旧版本兼容，不能只在 beta 分支改"
	)
	prepare := func(t *testing.T, markerPresent bool) (legacy, active string) {
		t.Helper()
		root := t.TempDir()
		legacy = filepath.Join(root, "legacy")
		active = filepath.Join(root, "active")
		if err := os.MkdirAll(filepath.Join(legacy, "tailscale"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(legacy, "tailscale", "identity"), []byte("legacy"), 0o600); err != nil {
			t.Fatal(err)
		}
		if markerPresent {
			if err := os.MkdirAll(active, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(active, marker), []byte("v1\n"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		if err := PreparePersistentState(legacy, active); err != nil {
			t.Fatal(err)
		}
		return legacy, active
	}

	t.Run("migration writes the pinned marker", func(t *testing.T) {
		_, active := prepare(t, false)
		if _, err := os.Stat(filepath.Join(active, marker)); err != nil {
			t.Fatalf("migration marker %q missing: %v; %s", marker, err, policy)
		}
	})
	t.Run("marker from another version stops migration", func(t *testing.T) {
		legacy, active := prepare(t, true)
		if _, err := os.Stat(filepath.Join(legacy, "tailscale", "identity")); err != nil {
			t.Fatalf("marker %q was not recognized, legacy identity moved again: %v; %s", marker, err, policy)
		}
		if _, err := os.Lstat(filepath.Join(active, "tailscale")); !os.IsNotExist(err) {
			t.Fatalf("marker %q was not recognized, active state touched: %v; %s", marker, err, policy)
		}
	})
}

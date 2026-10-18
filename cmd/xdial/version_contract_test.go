package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/engine"
	"github.com/kafeifei/xdial/core/tailscalesetup"
)

// 正式版、beta 与 Debug 共用这些版本号（D22），完整清单和纳入标准见
// test/version_constants_test.py。
const versionContractPolicy = "改这些值必须先在 main 上演进并处理旧版本兼容，不能只在 beta 分支改"

// 安装方（Swift）对这两个值的要求不同：daemon-info 的 registration_handoff_version 是能力
// 声明，只和最低协议版本 1 比大小，低于 1 就当旧 helper 走旧维护窗口；registration-handoff
// 回复的 protocol_version 必须恰好等于 1，否则安装方按服务忙放弃，新旧 App 与 helper 之间的
// 注册交接就会失败。
func TestRegistrationHandoffWireVersionsArePinned(t *testing.T) {
	clients := NewClientSet()
	eng := engine.New(filepath.Join(t.TempDir(), "engine"), t.TempDir(), &daemonCallback{clients: clients})
	gate := &daemonRegistrationGate{}

	server, peer := net.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		handleClient(server, eng, tailscalesetup.New(t.TempDir()), newResolverRefresher(), &sync.Mutex{}, clients, gate)
	}()
	defer func() {
		peer.Close()
		<-done
	}()
	if err := peer.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}

	encoder := json.NewEncoder(peer)
	scanner := bufio.NewScanner(peer)
	// handleClient 先推送一条 status 事件；net.Pipe 无缓冲，不读掉它就发不出请求。
	if !scanner.Scan() {
		t.Fatalf("missing initial status event: %v", scanner.Err())
	}
	roundTrip := func(command string) map[string]any {
		t.Helper()
		if err := encoder.Encode(Request{ID: command, Cmd: command}); err != nil {
			t.Fatalf("send %s: %v", command, err)
		}
		for scanner.Scan() {
			var response Response
			if err := json.Unmarshal(scanner.Bytes(), &response); err != nil {
				t.Fatalf("decode daemon message: %v", err)
			}
			if response.ID != command {
				continue
			}
			if !response.OK {
				t.Fatalf("%s refused: %q", command, response.Message)
			}
			var data map[string]any
			if err := json.Unmarshal([]byte(response.Data), &data); err != nil {
				t.Fatalf("decode %s data %q: %v", command, response.Data, err)
			}
			return data
		}
		t.Fatalf("no response for %s: %v", command, scanner.Err())
		return nil
	}

	if got := roundTrip("daemon-info")["registration_handoff_version"]; got != float64(1) {
		t.Fatalf("daemon-info registration_handoff_version = %v, want 1; %s", got, versionContractPolicy)
	}
	if got := roundTrip("registration-handoff")["protocol_version"]; got != float64(1) {
		t.Fatalf("registration-handoff protocol_version = %v, want 1; %s", got, versionContractPolicy)
	}
}

// 维护意图由 App 写入、helper 读取，两侧都只认 version 1：别的版本号一律不能结束维护。
func TestRegistrationIntentVersionIsPinned(t *testing.T) {
	path := filepath.Join(t.TempDir(), "maintenance")
	uid := uint32(os.Getuid())
	if err := os.WriteFile(path+".lock", nil, 0600); err != nil {
		t.Fatal(err)
	}
	hash := strings.Repeat("a", 64)
	write := func(version int) {
		t.Helper()
		raw, _ := json.Marshal(registrationIntent{Version: version, Token: "transaction", Phase: "registered", TargetHash: hash})
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, version := range []int{0, 2} {
		write(version)
		if finishRegistrationIntent(path, uid, "transaction", "registered", hash) {
			t.Fatalf("intent version %d was accepted; only version 1 is shared with the App; %s", version, versionContractPolicy)
		}
	}
	write(1)
	if !finishRegistrationIntent(path, uid, "transaction", "registered", hash) {
		t.Fatalf("intent version 1 was rejected; %s", versionContractPolicy)
	}
}

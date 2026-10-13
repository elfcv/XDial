//go:build !windows

package libbox

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
)

func decodeTrafficTotals(t *testing.T, raw string) trafficTotals {
	t.Helper()
	var totals trafficTotals
	if err := json.Unmarshal([]byte(raw), &totals); err != nil {
		t.Fatalf("decode traffic totals %q: %v", raw, err)
	}
	return totals
}

func TestTrafficFlowTrackerCountsBothDirections(t *testing.T) {
	var counter trafficCounter
	tracker := counter.RoutedFlow(context.Background(), adapter.InboundContext{}, nil, nil)
	tracker.CountForward(100)
	tracker.CountReverse(250)
	tracker.CountForward(1)
	if got := counter.snapshot(); got != (trafficTotals{UploadBytes: 101, DownloadBytes: 250}) {
		t.Fatalf("flow totals = %+v", got)
	}
}

// 经 socks inbound 把本地连接转给回显服务，验证真实 Router 路径上的
// TCP 字节被计入 TrafficTotals，且 Stop 后累计值不归零（App 端按差值算速率）。
func TestTrafficTotalsCountRoutedTCPAndSurviveStop(t *testing.T) {
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			conn, err := echo.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()
	echoAddr := echo.Addr().(*net.TCPAddr)

	reserve, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ingressPort := reserve.Addr().(*net.TCPAddr).Port
	_ = reserve.Close()

	platform := &xdPlatformInterface{}
	platform.setDefaultInterface("test0", 1)
	l := &Libbox{platform: platform}
	if got := decodeTrafficTotals(t, l.TrafficTotals()); got != (trafficTotals{}) {
		t.Fatalf("fresh totals = %+v", got)
	}
	configJSON := fmt.Sprintf(`{
		"log":{"disabled":true},
		"inbounds":[{
			"type":"socks","tag":"test-in",
			"listen":"127.0.0.1","listen_port":%d
		}],
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"final":"direct"}
	}`, ingressPort)
	if err := l.StartStandalone(configJSON); err != nil {
		t.Fatalf("StartStandalone: %v", err)
	}

	conn, err := net.DialTimeout(
		"tcp",
		fmt.Sprintf("127.0.0.1:%d", ingressPort),
		5*time.Second,
	)
	if err != nil {
		_ = l.Stop()
		t.Fatalf("dial ingress: %v", err)
	}
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	socks5Connect(t, conn, echoAddr)
	payload := bytes.Repeat([]byte("x"), 4096)
	if _, err := conn.Write(payload); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := io.ReadFull(conn, make([]byte, len(payload))); err != nil {
		t.Fatalf("read echo: %v", err)
	}
	_ = conn.Close()

	got := decodeTrafficTotals(t, l.TrafficTotals())
	if got.UploadBytes < int64(len(payload)) || got.DownloadBytes < int64(len(payload)) {
		t.Fatalf("routed totals = %+v, want >= %d each way", got, len(payload))
	}

	if err := l.Stop(); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if after := decodeTrafficTotals(t, l.TrafficTotals()); after.UploadBytes < got.UploadBytes ||
		after.DownloadBytes < got.DownloadBytes {
		t.Fatalf("totals went backwards after Stop: %+v -> %+v", got, after)
	}
}

// socks5Connect 完成无认证 SOCKS5 CONNECT 握手，目标是 IPv4 地址。
func socks5Connect(t *testing.T, conn net.Conn, target *net.TCPAddr) {
	t.Helper()
	if _, err := conn.Write([]byte{5, 1, 0}); err != nil {
		t.Fatalf("socks greeting: %v", err)
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(conn, reply); err != nil || reply[1] != 0 {
		t.Fatalf("socks method reply %v: %v", reply, err)
	}
	ip := target.IP.To4()
	request := []byte{5, 1, 0, 1, ip[0], ip[1], ip[2], ip[3],
		byte(target.Port >> 8), byte(target.Port)}
	if _, err := conn.Write(request); err != nil {
		t.Fatalf("socks connect: %v", err)
	}
	response := make([]byte, 10)
	if _, err := io.ReadFull(conn, response); err != nil || response[1] != 0 {
		t.Fatalf("socks connect reply %v: %v", response, err)
	}
}

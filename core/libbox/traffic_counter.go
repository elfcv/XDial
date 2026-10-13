//go:build !windows

package libbox

import (
	"context"
	stdjson "encoding/json"
	"net"
	"sync/atomic"

	"github.com/sagernet/sing-box/adapter"
	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/bufio"
	N "github.com/sagernet/sing/common/network"
)

// trafficCounter 统计经过 sing-box Router 的全部用户流量，不区分 Line。
//
// AnyConnect 网桥自带的 VPNBridgeStats 只覆盖一条线路；TUN 层计数又拿不到
// （fd 直接交给 sing-tun）。Router 是所有线路与直连的共同汇合点，所以在这里
// 计数。累计值挂在 Libbox 上而不是 Box 上：候选切换期间新旧两代 Box 并存，
// 每条连接只会在其中一代路由一次，共享计数器既不归零也不重复。
//
// 它只读写计数，不参与任何路由裁决。
type trafficCounter struct {
	upload   atomic.Int64
	download atomic.Int64
}

var _ adapter.ConnectionTracker = (*trafficCounter)(nil)

func (c *trafficCounter) RoutedConnection(
	_ context.Context,
	conn net.Conn,
	_ adapter.InboundContext,
	_ adapter.Rule,
	_ adapter.Outbound,
) net.Conn {
	// 入站侧 conn：读到的是客户端发出的上行，写回的是下行。
	return bufio.NewInt64CounterConn(
		conn,
		[]*atomic.Int64{&c.upload},
		[]*atomic.Int64{&c.download},
	)
}

func (c *trafficCounter) RoutedPacketConnection(
	_ context.Context,
	conn N.PacketConn,
	_ adapter.InboundContext,
	_ adapter.Rule,
	_ adapter.Outbound,
) N.PacketConn {
	return bufio.NewInt64CounterPacketConn(
		conn,
		[]*atomic.Int64{&c.upload},
		nil,
		[]*atomic.Int64{&c.download},
		nil,
	)
}

func (c *trafficCounter) RoutedFlow(
	context.Context,
	adapter.InboundContext,
	adapter.Rule,
	adapter.Outbound,
) tun.FlowTracker {
	return (*trafficFlowTracker)(c)
}

type trafficFlowTracker trafficCounter

var _ tun.FlowTracker = (*trafficFlowTracker)(nil)

func (t *trafficFlowTracker) AttachFlow(tun.FlowHandle) {}

func (t *trafficFlowTracker) CountForward(n int) { t.upload.Add(int64(n)) }

func (t *trafficFlowTracker) CountReverse(n int) { t.download.Add(int64(n)) }

func (t *trafficFlowTracker) FlowEstablished() {}

func (t *trafficFlowTracker) CloseFlow(tun.FlowCloseReason) {}

type trafficTotals struct {
	UploadBytes   int64 `json:"upload_bytes"`
	DownloadBytes int64 `json:"download_bytes"`
}

func (c *trafficCounter) snapshot() trafficTotals {
	return trafficTotals{
		UploadBytes:   c.upload.Load(),
		DownloadBytes: c.download.Load(),
	}
}

// TrafficTotals 返回本进程自创建以来经 Router 转发的累计上下行字节数（JSON）。
// 只单调递增；调用方按两次采样的差值计算速率。不含任何目标、线路或凭据信息。
func (l *Libbox) TrafficTotals() string {
	data, err := stdjson.Marshal(l.traffic.snapshot())
	if err != nil {
		return `{"upload_bytes":0,"download_bytes":0}`
	}
	return string(data)
}

package main

import (
	"fmt"
	"os"
)

var version = "dev"

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "daemon":
		runDaemonCmd(os.Args[2:])
	case "start":
		runStartCmd(os.Args[2:])
	case "stop":
		runStopCmd(os.Args[2:])
	case "status":
		runStatusCmd(os.Args[2:])
	case "sub":
		runSubCmd(os.Args[2:])
	case "version", "--version", "-v":
		fmt.Println(versionLine())
	case "help", "--help", "-h":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", os.Args[1])
		printUsage()
		os.Exit(1)
	}
}

// versionLine names any build flavor. Release builds use -trimpath, which
// drops -ldflags from the Go build information, so the release contract's
// exact "xdial <tag>" check is what refuses a flavored helper.
func versionLine() string {
	if buildFlavor == "" {
		return "xdial " + version
	}
	return fmt.Sprintf("xdial %s (buildFlavor=%s)", version, buildFlavor)
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `Usage: xdial <command> [options]

Commands:
  start    Connect VPN in foreground (Ctrl+C to disconnect)
  stop     Tell running daemon to disconnect
  status   Query daemon status
  daemon   Run as socket daemon (for launchd/systemd)
  sub      Subscription operations
  version  Print version

Run 'xdial <command> --help' for command-specific help.
`)
}

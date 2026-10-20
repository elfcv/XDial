package main

import (
	"os"
	"path/filepath"
)

// buildFlavor is set to "debug" by the local Debug build's Go linker flags.
// Empty, "release", and unknown values deliberately retain the historical
// production identity so ordinary CLI and release builds cannot drift. There
// is no beta flavor: a beta release is a formal build and must report stable.
var buildFlavor string

type runtimeIdentity struct {
	hostBundleIdentifier   string
	helperBundleIdentifier string
	daemonLabel            string
	socketPath             string
	engineBasePath         string
	rootStatePath          string
	userStateDirectoryName string
	sharedAppGroup         string
	registrationIntentPath string
	logPath                string
	// tailscaleDeviceChannel names this installation identity in Tailscale
	// device names; it matches XDialBuildIdentity.tailscaleDeviceChannel.
	tailscaleDeviceChannel string
}

func runtimeIdentityForFlavor(flavor string) runtimeIdentity {
	if flavor == "debug" {
		return runtimeIdentity{
			hostBundleIdentifier:   "com.kafeifei.xdial.debug",
			helperBundleIdentifier: "com.kafeifei.xdial.debug.helper",
			daemonLabel:            "com.kafeifei.xdial.debug.daemon",
			socketPath:             "/tmp/xdial-debug.sock",
			engineBasePath:         "/tmp/xdial-debug-engine",
			rootStatePath:          "/Library/Application Support/XDial Debug",
			userStateDirectoryName: ".xdial-debug",
			sharedAppGroup:         "UVZM439VGU.com.kafeifei.xdial.debug.network",
			registrationIntentPath: "/tmp/xdial-debug-registration-maintenance",
			logPath:                "/tmp/xdial-debug.log",
			tailscaleDeviceChannel: "debug",
		}
	}

	return runtimeIdentity{
		hostBundleIdentifier:   "com.kafeifei.xdial.app",
		helperBundleIdentifier: "com.kafeifei.xdial.app.helper",
		daemonLabel:            "com.kafeifei.xdial.app.daemon",
		socketPath:             "/tmp/xdial.sock",
		engineBasePath:         filepath.Join(os.TempDir(), "xdial-engine"),
		rootStatePath:          "/Library/Application Support/XDial",
		userStateDirectoryName: ".xdial",
		sharedAppGroup:         "UVZM439VGU.com.kafeifei.xdial.network",
		registrationIntentPath: "/tmp/xdial-registration-maintenance",
		logPath:                "/tmp/xdial.log",
		tailscaleDeviceChannel: "stable",
	}
}

func currentRuntimeIdentity() runtimeIdentity {
	return runtimeIdentityForFlavor(buildFlavor)
}

func (identity runtimeIdentity) userStatePath(home string) string {
	return filepath.Join(home, identity.userStateDirectoryName)
}

func (identity runtimeIdentity) orphanSingBoxPattern() string {
	return "sing-box run.*" + filepath.Base(identity.engineBasePath)
}

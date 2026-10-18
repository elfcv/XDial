package config

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

func TestTailscaleChannelNameStableDistinctAndDNSValid(t *testing.T) {
	valid := regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$`)
	for _, name := range []string{"xdial-next-526fb361", "xdial-mac-7f3a", "", "我的电脑", strings.Repeat("mac-", 30)} {
		seen := map[string]bool{}
		for _, channel := range []string{"debug", "stable"} {
			got := TailscaleHostnameForChannel(name, "profile-a", channel)
			if !valid.MatchString(got) || seen[got] {
				t.Fatalf("invalid or duplicate name: %q", got)
			}
			seen[got] = true
			if again := TailscaleHostnameForChannel(got, "profile-a", channel); again != got {
				t.Fatalf("repeated runtime projection renamed %q to %q", got, again)
			}
		}
	}
}

func TestChannelProjectionPreservesIdentityPathsAndSharedDocument(t *testing.T) {
	raw := `{"profile_id":"global-configuration","tailscale":{"hostname":"xdial-next-profile"},"future":17,"lines":[{"id":"ts","type":"tailscale","enabled":true,"identity_profile_id":"source-a","identity_hostname":"xdial-next-device","future_line":true}],"scenarios":[{"id":"s","default_line_id":"ts"}],"active_scenario_id":"s"}`
	original, err := ParseRuntimeProfile([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	wantPath, err := ProfileDataPath(original, "/state")
	if err != nil {
		t.Fatal(err)
	}
	for _, channel := range []string{"debug", "stable"} {
		projected, err := ProfileWithTailscaleChannel(raw, channel)
		if err != nil {
			t.Fatal(err)
		}
		profile, err := ParseRuntimeProfile([]byte(projected))
		if err != nil {
			t.Fatal(err)
		}
		gotPath, err := ProfileDataPath(profile, "/state")
		if err != nil || gotPath != wantPath {
			t.Fatalf("renaming moved persistent identity: %s %v", gotPath, err)
		}
		endpoint, err := buildTailscaleEndpoint(&profile.Lines[0], profile.Tailscale, gotPath, "")
		if err != nil || endpoint["hostname"] != "xdial-"+channel+"-device" {
			t.Fatalf("wrong endpoint: %v %v", endpoint, err)
		}
		var doc map[string]any
		_ = json.Unmarshal([]byte(projected), &doc)
		if doc["future"] != float64(17) || !strings.Contains(projected, `"future_line":true`) {
			t.Fatal("lost future fields")
		}
		if original.Lines[0].IdentityHostname != "xdial-next-device" {
			t.Fatal("mutated shared identity")
		}
	}
}

// Only Debug has its own device names. Beta, the retired Next, and unknown
// values are the formal identity and must keep its exact names.
func TestTailscaleChannelAliasesNameTheFormalIdentity(t *testing.T) {
	for _, name := range []string{"", "xdial-next-526fb361", "xdial-debug-526fb361", "MacBook Pro", "我的电脑"} {
		want := TailscaleHostnameForChannel(name, "profile-a", "stable")
		for _, channel := range []string{"", "release", "beta", "next", "Debug", "unexpected"} {
			if got := TailscaleHostnameForChannel(name, "profile-a", channel); got != want {
				t.Fatalf("channel %q named %q as %q, want formal %q", channel, name, got, want)
			}
		}
	}
	raw := `{"profile_id":"global-configuration","tailscale":{"hostname":"xdial-next-profile"},"lines":[{"id":"ts","type":"tailscale","enabled":true,"identity_hostname":"xdial-next-device"}],"scenarios":[{"id":"s","default_line_id":"ts"}],"active_scenario_id":"s"}`
	want, err := ProfileWithTailscaleChannel(raw, "stable")
	if err != nil {
		t.Fatal(err)
	}
	for _, channel := range []string{"", "beta", "next"} {
		if got, err := ProfileWithTailscaleChannel(raw, channel); err != nil || got != want {
			t.Fatalf("channel %q projected %s %v, want %s", channel, got, err, want)
		}
	}
}

// Golden names measured before the Next identity was removed. Installed
// devices already use them, so the projection must never rename them.
func TestTailscaleChannelNamesMatchInstalledDevices(t *testing.T) {
	long := strings.Repeat("mac-", 30)
	for _, test := range []struct{ name, debug, stable string }{
		{"", "xdial-debug-profile-a", "xdial-stable-profile-a"},
		{"xdial-next-526fb361", "xdial-debug-526fb361", "xdial-stable-526fb361"},
		{"xdial-stable-526fb361", "xdial-debug-526fb361", "xdial-stable-526fb361"},
		{"xdial-debug-526fb361", "xdial-debug-526fb361", "xdial-stable-526fb361"},
		{"xdial-mac-7f3a", "xdial-debug-mac-7f3a", "xdial-stable-mac-7f3a"},
		{"XDial-Next-Device", "xdial-debug-device", "xdial-stable-device"},
		{"MacBook Pro", "xdial-debug-macbook-pro-27119b85", "xdial-stable-macbook-pro-27119b85"},
		{"我的电脑", "xdial-debug-device-e80f19d2", "xdial-stable-device-e80f19d2"},
		{long, "xdial-debug-mac-mac-mac-mac-mac-mac-mac-mac-mac-mac-a9a74a59", "xdial-stable-mac-mac-mac-mac-mac-mac-mac-mac-mac-mac-a9a74a59"},
	} {
		if got := TailscaleHostnameForChannel(test.name, "profile-a", "debug"); got != test.debug {
			t.Errorf("debug name for %q = %q, want %q", test.name, got, test.debug)
		}
		if got := TailscaleHostnameForChannel(test.name, "profile-a", "stable"); got != test.stable {
			t.Errorf("stable name for %q = %q, want %q", test.name, got, test.stable)
		}
	}
	raw := `{"profile_id":"global-configuration","tailscale":{"hostname":"xdial-next-profile"},"lines":[{"id":"ts","type":"tailscale","enabled":true,"identity_profile_id":"source-a","identity_hostname":"xdial-next-device"},{"id":"ts2","type":"tailscale","enabled":true}],"scenarios":[{"id":"s","default_line_id":"ts"}],"active_scenario_id":"s"}`
	for channel, want := range map[string]string{
		"debug":  `{"active_scenario_id":"s","lines":[{"enabled":true,"id":"ts","identity_hostname":"xdial-debug-device","identity_profile_id":"source-a","type":"tailscale"},{"enabled":true,"id":"ts2","identity_hostname":"xdial-debug-profile","type":"tailscale"}],"profile_id":"global-configuration","scenarios":[{"id":"s","default_line_id":"ts"}],"tailscale":{"hostname":"xdial-debug-profile"}}`,
		"stable": `{"active_scenario_id":"s","lines":[{"enabled":true,"id":"ts","identity_hostname":"xdial-stable-device","identity_profile_id":"source-a","type":"tailscale"},{"enabled":true,"id":"ts2","identity_hostname":"xdial-stable-profile","type":"tailscale"}],"profile_id":"global-configuration","scenarios":[{"id":"s","default_line_id":"ts"}],"tailscale":{"hostname":"xdial-stable-profile"}}`,
	} {
		if got, err := ProfileWithTailscaleChannel(raw, channel); err != nil || got != want {
			t.Errorf("%s projection = %s %v, want %s", channel, got, err, want)
		}
	}
}

func TestChannelProjectionRejectsNullWithoutPanic(t *testing.T) {
	for _, raw := range []string{"null", "[]", "", "{"} {
		if _, err := ProfileWithTailscaleChannel(raw, "debug"); err == nil {
			t.Fatalf("accepted %q", raw)
		}
	}
}

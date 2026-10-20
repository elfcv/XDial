package main

import "testing"

func TestVersionLineNamesAnyBuildFlavor(t *testing.T) {
	originalVersion, originalFlavor := version, buildFlavor
	t.Cleanup(func() {
		version, buildFlavor = originalVersion, originalFlavor
	})
	version = "v1.2.3"
	for _, test := range []struct {
		flavor string
		want   string
	}{
		{flavor: "", want: "xdial v1.2.3"},
		{flavor: "debug", want: "xdial v1.2.3 (buildFlavor=debug)"},
		// Falls back to the production identity, but is still not a
		// production build and must not pass the release contract.
		{flavor: "release", want: "xdial v1.2.3 (buildFlavor=release)"},
	} {
		buildFlavor = test.flavor
		if got := versionLine(); got != test.want {
			t.Errorf("versionLine() with flavor %q = %q, want %q", test.flavor, got, test.want)
		}
	}
}

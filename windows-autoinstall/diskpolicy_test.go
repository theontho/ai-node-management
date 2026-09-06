package main

import (
	"strings"
	"testing"
)

const gib = uint64(1024 * 1024 * 1024)

func TestChooseTargetPrefersNVMeOverMMC(t *testing.T) {
	candidates := []disk{
		{index: 0, sizeBytes: 119 * gib, busType: busTypeMMC},
		{index: 1, sizeBytes: 119 * gib, busType: busTypeNVMe},
	}
	target, largeEnough := chooseTarget(candidates, 64_000_000_000)
	if target.index != 1 || !largeEnough {
		t.Fatalf("selected %+v, largeEnough=%t; want NVMe disk 1", target, largeEnough)
	}
}

func TestChooseTargetRequiresCapacityBeforePerformance(t *testing.T) {
	candidates := []disk{
		{index: 0, sizeBytes: 32 * gib, busType: busTypeNVMe},
		{index: 1, sizeBytes: 119 * gib, busType: busTypeMMC},
	}
	target, largeEnough := chooseTarget(candidates, 64_000_000_000)
	if target.index != 1 || !largeEnough {
		t.Fatalf("selected %+v, largeEnough=%t; want sufficiently large MMC disk 1", target, largeEnough)
	}
}

func TestChooseTargetFallsBackToLargestAvailableDisk(t *testing.T) {
	candidates := []disk{
		{index: 0, sizeBytes: 48 * gib, busType: busTypeMMC},
		{index: 1, sizeBytes: 32 * gib, busType: busTypeNVMe},
	}
	target, largeEnough := chooseTarget(candidates, 60_000_000_000)
	if target.index != 0 || largeEnough {
		t.Fatalf("selected %+v, largeEnough=%t; want larger fallback disk 0", target, largeEnough)
	}
}

func TestInternalDiskFiltering(t *testing.T) {
	excluded := map[int]bool{4: true}
	tests := []struct {
		disk disk
		want bool
	}{
		{disk{index: 0, busType: busTypeNVMe}, true},
		{disk{index: 1, busType: busTypeMMC}, true},
		{disk{index: 2, busType: busTypeUSB}, false},
		{disk{index: 3, busType: busTypeSD}, false},
		{disk{index: 4, busType: busTypeNVMe}, false},
		{disk{index: 5, busType: busTypeSATA, removable: true}, false},
		{disk{index: 6, sizeBytes: 64 * gib, busType: busTypeSD}, true},
		{disk{index: 7, sizeBytes: 16 * gib, busType: busTypeSD}, false},
	}
	for _, test := range tests {
		if got := isInternalDisk(test.disk, excluded); got != test.want {
			t.Errorf("isInternalDisk(%+v)=%t, want %t", test.disk, got, test.want)
		}
	}
}

func TestRenderAnswer(t *testing.T) {
	template := "<ComputerName>__RUNTIME_COMPUTER_NAME__</ComputerName>" +
		"<DiskID>__TARGET_DISK_ID__</DiskID><DiskID>__TARGET_DISK_ID__</DiskID>"
	rendered, err := renderAnswer(template, 7, "win-brisk-otter")
	if err != nil {
		t.Fatal(err)
	}
	expected := "<ComputerName>win-brisk-otter</ComputerName>" +
		"<DiskID>7</DiskID><DiskID>7</DiskID>"
	if rendered != expected {
		t.Fatalf("unexpected answer: %s", rendered)
	}
}

func TestGenerateComputerName(t *testing.T) {
	name, err := generateComputerName("win")
	if err != nil {
		t.Fatal(err)
	}
	if len(name) > 15 || !strings.HasPrefix(name, "win-") {
		t.Fatalf("unexpected generated computer name: %q", name)
	}
	parts := strings.Split(name, "-")
	if len(parts) != 3 ||
		!containsWord(computerNameAdjectives, parts[1]) ||
		!containsWord(computerNameNouns, parts[2]) {
		t.Fatalf("computer name does not use the configured dictionaries: %q", name)
	}
}

func TestGenerateComputerNameRejectsUnsafePrefix(t *testing.T) {
	for _, prefix := range []string{"", "9node", "node", "w-n", "win&run"} {
		if _, err := generateComputerName(prefix); err == nil {
			t.Errorf("generateComputerName(%q) unexpectedly succeeded", prefix)
		}
	}
}

func TestComputerNameDictionaryFitsWindowsLimit(t *testing.T) {
	for _, adjective := range computerNameAdjectives {
		for _, noun := range computerNameNouns {
			name := "win-" + adjective + "-" + noun
			if len(name) > 15 {
				t.Errorf("dictionary-generated name exceeds 15 characters: %q", name)
			}
		}
	}
}

func containsWord(words []string, candidate string) bool {
	for _, word := range words {
		if word == candidate {
			return true
		}
	}
	return false
}

func TestSecondaryDiskPlanExcludesTargetAndFormatsEveryOtherDisk(t *testing.T) {
	plan := renderSecondaryDiskPlan([]disk{{index: 2}, {index: 1}, {index: 0}}, 1)
	if strings.Contains(plan, "select disk 1") {
		t.Fatalf("secondary disk plan includes target disk:\n%s", plan)
	}
	for _, expected := range []string{
		"select disk 0",
		`format fs=ntfs quick label="AI_NODE_DATA_0"`,
		"select disk 2",
		`format fs=ntfs quick label="AI_NODE_DATA_2"`,
		"clean",
		"convert gpt",
		"create partition primary",
	} {
		if !strings.Contains(plan, expected) {
			t.Fatalf("secondary disk plan is missing %q:\n%s", expected, plan)
		}
	}
	if strings.Index(plan, "select disk 0") > strings.Index(plan, "select disk 2") {
		t.Fatalf("secondary disk plan is not sorted by disk number:\n%s", plan)
	}
}
